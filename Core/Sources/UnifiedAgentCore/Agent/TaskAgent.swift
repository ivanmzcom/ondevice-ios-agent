import Combine
import Foundation

/// An OpenAI-compatible chat endpoint the user configured (upstream LLMClient semantics: base URL, model id,
/// optional bearer API key). The only other path is the experimental, Debug-only ChatGPT plan backend
/// (`TaskAgent(provider:chatGPT:…)`), which never uses this key.
public struct ModelEndpoint: Equatable, Sendable {
    public var baseURL: String, model: String, apiKey: String
    public init(baseURL: String, model: String, apiKey: String) { (self.baseURL, self.model, self.apiKey) = (baseURL, model, apiKey) }

    public var problem: String? {
        guard let u = URL(string: baseURL), let host = u.host, !host.isEmpty, u.scheme == "https" || u.scheme == "http" else {
            return "no model endpoint (base URL) configured"
        }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return "no model id configured" }
        return nil
    }

    /// GET {base}/models via upstream LLMClient.models.
    @MainActor public func listModels() async throws -> [String] { try await LLMClient.models(baseURL: baseURL, apiKey: apiKey) }
}

/// The upstream provider presets (public endpoints only; users bring their own key).
public struct ProviderPreset: Identifiable, Hashable, Sendable {
    public var id: String, title: String, baseURL: String, keyURL: URL?
    public static var all: [ProviderPreset] {
        ModelProvider.allCases.map { ProviderPreset(id: $0.rawValue, title: $0.title, baseURL: $0.baseURL, keyURL: $0.keyURL) }
    }
}

public enum AgentMode: String, CaseIterable, Sendable {
    /// Observe and decide; select the target and evaluate the WDA gate; send nothing to WDA.
    case dryRun
    /// Run WDA navigation steps (each: fresh observe, gate, one WDA tap or typing request, fresh verify).
    case live
}

/// The operator chose to start at Home (Inicio): observations follow the foreground app, never activate a target.
public struct CrossAppConfig {
    public var driver: WDACrossAppDriver
    public var method: LaunchMethod
    public var settle: SettlePolicy
    public init(driver: WDACrossAppDriver, method: LaunchMethod = .icon, settle: SettlePolicy = SettlePolicy()) {
        (self.driver, self.method, self.settle) = (driver, method, settle)
    }
}

public struct AgentEvent: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case observe, think, act, verify, blocked, error, finish }
    public let id = UUID()
    public var at: Date
    public var kind: Kind
    public var text: String
}

/// Client-side stage timings of one agent step, from a monotonic clock. Only counts and durations: no task,
/// labels, model words or tokens. `modelMs` is the wall time around the model call as seen by this app (network,
/// queueing, server inference and streaming together); the server's own inference time is not reported to us.
public struct StepTiming: Equatable, Sendable {
    public var step: Int
    /// The observation this step decided on; nil when it came from the previous step's verification.
    public var observeMs: Double?
    /// UTF-8 bytes of the system prompt plus the user text sent to the model.
    public var requestBytes: Int
    public var candidates: Int, tappable: Int, omitted: Int, folded: Int
    public var modelMs: Double?
    /// Time to the first streamed text, as measured by the model client (client-side too).
    public var firstTokenMs: Double?
    /// Input tokens only when the server reported usage; never estimated.
    public var serverInputTokens: Int?
    /// Output and reasoning tokens, only as the server reported them.
    public var serverOutputTokens: Int?, serverReasoningTokens: Int?
    /// ChatGPT plan only: the tier asked for ("omitted" when Fast is off) and the one `response.completed` reported.
    public var tierRequested: String?, tierConfirmed: String?
    /// Direct WDA steps: fresh observe + gate before the tap, the tap call, and the rest of the step (verification).
    public var preActMs: Double?, actMs: Double?, verifyMs: Double?
    /// Tap steps: "targeted" (runner revalidation of the chosen target) or "full" (fresh full observation), and how
    /// many full observations the pre-action check took (measured by construction: 0 or 1).
    public var preActPath: String?, preActFullObservations: Int?
    /// The whole navigation step (typing steps are not split).
    public var stepMs: Double?

    public var summary: String {
        func ms(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
        var s = "step \(step): observe \(ms(observeMs)) ms · model \(ms(modelMs)) ms client wall (incl. network/wait"
            + (firstTokenMs.map { String(format: "; first text %.0f ms", $0) } ?? "") + "; server time n/a)"
        s += " · request \(requestBytes) B, \(candidates) elements (\(tappable) t, \(folded) folded, \(omitted) not shown)"
        if let n = serverInputTokens { s += " · server-reported input \(n) tokens" }
        if let n = serverOutputTokens { s += ", output \(n)" + (serverReasoningTokens.map { " (reasoning \($0))" } ?? "") }
        if let r = tierRequested { s += " · tier requested \(r), confirmed \(tierConfirmed ?? "no")" }
        if actMs != nil { s += " · pre-act \(ms(preActMs))" + (preActPath.map { " (\($0))" } ?? "") + " · act \(ms(actMs)) · verify \(ms(verifyMs)) ms" }
        else if stepMs != nil { s += " · act+verify \(ms(stepMs)) ms" }
        return s
    }
}

/// Times the single tap call of one step (one instance per step).
final class TimedTapSink: WDATapSink {
    let inner: WDATapSink
    let now: () -> UInt64
    private(set) var started: UInt64?, ended: UInt64?
    init(_ inner: WDATapSink, now: @escaping () -> UInt64) { (self.inner, self.now) = (inner, now) }
    func tap(at point: WDAPoint, window: WDASize) async throws {
        started = now()
        defer { ended = now() }
        try await inner.tap(at: point, window: window)
    }
}

/// Task agent: task entry -> observation (WDA element tree) -> model decision (upstream THINK/DO format, element
/// actions) -> one direct WDA tap (or typing request) -> fresh verification -> next decision. Taps only through
/// WDATapGate (WDATapNavigationStep / CrossAppTapStep); nothing written to WDA is ever retried or replayed.
@MainActor public final class TaskAgent: ObservableObject {
    @Published public private(set) var events: [AgentEvent] = []
    @Published public private(set) var running = false
    @Published public private(set) var outcome: String?
    /// Stage timings of the current run, one per model request.
    @Published public private(set) var timings: [StepTiming] = []
    public static let defaultMaxSteps = 12
    public var maxSteps = TaskAgent.defaultMaxSteps

    let provider: WDAObservationProvider
    let model: ChatModel
    let policy: GatePolicy
    /// Direct WDA taps (`/wda/tap`): the only input path.
    let tapper: WDATapSink
    let clock: () -> Date
    /// Monotonic nanoseconds, for stage timings only (never for freshness, which stays on `clock`).
    let monotonic: () -> UInt64
    /// Cross-app runs: start from Home and follow the real foreground app. nil = the selected app.
    public var crossApp: CrossAppConfig?
    /// Pre-action revalidation of the chosen tap target (compact observer only). nil = every tap re-observes in full.
    /// Typing and cross-app steps always re-observe in full.
    public var targetRevalidator: WDATargetRevalidator?
    /// Direct WDA typing (`/wda/keys`); offered to the model only when set.
    public var wdaText: WDATextSink?
    var typing: WDATextSink? { wdaText }
    private var job: Task<Void, Never>?

    public convenience init(provider: WDAObservationProvider, endpoint: ModelEndpoint, tapper: WDATapSink, policy: GatePolicy) {
        self.init(provider: provider,
                  model: LLMClient(baseURL: endpoint.baseURL, model: endpoint.model, apiKey: endpoint.apiKey),
                  tapper: tapper, policy: policy)
    }

    /// EXPERIMENTAL: ChatGPT plan usage through the Responses API (signed-in account token; no API key, no fallback).
    public convenience init(provider: WDAObservationProvider, chatGPT: ResponsesClient, tapper: WDATapSink, policy: GatePolicy) {
        self.init(provider: provider, model: chatGPT, tapper: tapper, policy: policy)
    }

    init(provider: WDAObservationProvider, model: ChatModel, tapper: WDATapSink, policy: GatePolicy,
         clock: @escaping () -> Date = Date.init,
         monotonic: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.provider = provider; self.model = model; self.tapper = tapper; self.policy = policy
        self.clock = clock; self.monotonic = monotonic
    }

    public func start(task: String, bundleID: String, mode: AgentMode, onFinish: (() -> Void)? = nil) {
        guard !running else { return }
        job = Task { [weak self] in
            _ = await self?.run(task: task, bundleID: bundleID, mode: mode)
            onFinish?()
        }
    }

    public func stop() {
        AgentDiag.event("agent.stop_requested", [("running", .bool(running))])
        job?.cancel()
    }
    private var runSpan: AgentDiag.Span?

    private func emit(_ kind: AgentEvent.Kind, _ text: String) {
        events.append(AgentEvent(at: clock(), kind: kind, text: text))
        DebugLog.write("agent \(kind.rawValue): \(text)")
    }

    private func finish(_ kind: AgentEvent.Kind, _ text: String) -> String {
        emit(kind, text)
        outcome = text
        running = false
        runSpan?.end([("kind", .token(kind.rawValue)), ("cancelled", .bool(Task.isCancelled)), ("model_requests", .int(timings.count))])
        runSpan = nil
        return text
    }

    /// One model request over the Spotlight result list: which listed element is the app itself. Anything but a
    /// single `tap N` is no choice (nothing is tapped); the caller still checks the pick names the app.
    func chooseSpotlightResult(app: String, observation: WDAObservation, list: ElementPrompt.CandidateList) async throws -> SpotlightChoice {
        let task = "Spotlight search results for the app " + ElementPrompt.quote(app, max: 40) + ". Choose the one result "
            + "that opens that installed app itself (not a web search, suggestion, setting, App Store, file or contact). "
            + "Answer DO: tap N for it, or DO: fail <reason> if it is missing or more than one result could be it."
        let text = ElementPrompt.render(task: task, observation: observation, list: list, history: [])
        let span = AgentDiag.begin("model.chat", [("purpose", .token("spotlight_choice")), ("elements", .int(list.items.count))])
        let reply: ChatResult
        do { reply = try await model.chat(system: ElementPrompt.system(typing: false), text: text, image: nil, maxTokens: 300, temperature: 0) }
        catch { span.fail(error, [("cancelled", .bool(Task.isCancelled))]); throw error }
        span.end([("reply_bytes", .int(reply.text.utf8.count))])
        let d = try ElementDecision.parse(reply.text)
        emit(.think, d.thought)
        switch d.action {
        case .tap(let i): return .tap(i)
        case .fail(let why): return .none(why)
        default: return .none("the model did not pick a result")
        }
    }

    @discardableResult
    func run(task: String, bundleID: String, mode: AgentMode) async -> String {
        running = true; outcome = nil; events = []; timings = []
        AgentDiag.newRun()
        runSpan = AgentDiag.begin("agent.run", [("mode", .token(mode.rawValue)), ("cross_app", .bool(crossApp != nil)),
                                                ("typing", .bool(typing != nil)), ("max_steps", .int(maxSteps))])
        emit(.observe, "task: \(task) · app \(bundleID) · \(mode == .dryRun ? "dry run (nothing sent to WDA)" : "live")")
        var bound = bundleID
        var history: [String] = []
        var opened: String?
        if let crossApp {
            let intent = TaskIntent.classify(task)
            switch intent {
            case .launchOnly(let launch), .openThen(let launch):
                var launcher = CrossAppLauncher(driver: crossApp.driver, tapper: tapper, method: crossApp.method, policy: policy,
                                                settle: crossApp.settle, clock: clock)
                // Icon not on the visible Home page: Spotlight, only with WDA typing (to enter the name once).
                if let typing { launcher.spotlight = (typing, { [weak self] name, obs, list in
                    guard let self else { throw CancellationError() }
                    return try await self.chooseSpotlightResult(app: name, observation: obs, list: list)
                }) }
                let then: Bool = { if case .openThen = intent { return true }; return false }()
                switch await launcher.run(launch, start: .home, dryRun: mode == .dryRun, log: { emit($0, $1) }) {
                case .launched(let b):
                    // Launch-only: confirmed in front, stop without reading it. "Open X and …": keep going in X.
                    guard then else { return finish(.finish, "done: \(launch.appName) abierta en primer plano (\(b)); no se leyó su contenido") }
                    opened = b
                    history.append("opened \(ElementPrompt.quote(launch.appName, max: 40)): \(b) is now in front")
                case .dryRun(let m):
                    return finish(.finish, "dry run (Inicio, WDA): " + m + (then ? " (then the rest of the task in that app)" : ""))
                case .stopped(let m): return finish(.blocked, m)
                case .failed(let m): return finish(.error, m)
                }
            case .other: break
            }
            if let opened { bound = opened } else if mode == .live {
                if let why = await CrossAppLauncher(driver: crossApp.driver, tapper: tapper, settle: crossApp.settle)
                    .goHome(dryRun: false, log: { emit($0, $1) }) { return finish(.error, why) }
            }
            if opened == nil { bound = SpringBoard.bundleID }
        }
        // A cross-app dry run never pressed Home: its first look takes whatever is in front and binds to it.
        var unbound = crossApp != nil && mode == .dryRun
        func look() async throws -> WDAObservation {
            if let crossApp {
                let o = try await crossApp.driver.observeForeground(expected: unbound ? nil : bound)
                unbound = false
                bound = o.bundleID
                return o
            }
            return try await provider.observe(targetBundleID: bound)
        }
        func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to &- from) / 1e6 }
        var observeMs: Double?
        func timedLook() async throws -> WDAObservation {
            let t0 = monotonic()
            defer { observeMs = ms(t0, monotonic()) }
            return try await look()
        }
        /// Fills in the act/verify part of this step's timing (after the step runner returned).
        func recordStep(_ t0: UInt64, _ tapper: TimedTapSink?, preAct: WDAPreActPath? = nil) {
            guard let k = timings.indices.last else { return }
            let end = monotonic()
            timings[k].stepMs = ms(t0, end)
            if let preAct { timings[k].preActPath = preAct.token; timings[k].preActFullObservations = preAct == .targeted ? 0 : 1 }
            if let a = tapper?.started, let b = tapper?.ended {
                timings[k].preActMs = ms(t0, a); timings[k].actMs = ms(a, b); timings[k].verifyMs = ms(b, end)
            }
            DebugLog.write("agent timing: " + timings[k].summary)
        }
        var obs: WDAObservation
        do { obs = try await timedLook() } catch {
            return finish(.error, "observation failed: \(error.localizedDescription)")
        }
        var parseFailures = 0
        let system = ElementPrompt.system(typing: typing != nil)
        for step in 1...maxSteps {
            if Task.isCancelled { return finish(.finish, "stopped by the user") }
            // Fresh, self-contained list for this observation; "tap N" resolves through it only.
            let list = ElementPrompt.list(obs)
            let cands = list.items
            emit(.observe, "step \(step): \(obs.elements.count) elements, \(cands.filter(\.tappable).count) tappable, source \(obs.sourceDigest)")
            let text = ElementPrompt.render(task: task, observation: obs, list: list, history: history)
            var timing = StepTiming(step: step, observeMs: observeMs, requestBytes: system.utf8.count + text.utf8.count,
                                    candidates: cands.count, tappable: cands.filter(\.tappable).count, omitted: list.omitted,
                                    folded: list.folded)
            observeMs = nil
            let reply: ChatResult
            let m0 = monotonic()
            let modelSpan = AgentDiag.begin("model.chat", [("step", .int(step)), ("request_bytes", .int(timing.requestBytes)),
                                                           ("elements", .int(cands.count))])
            do {
                reply = try await model.chat(system: system, text: text, image: nil, maxTokens: 600, temperature: 0)
                var f: AgentDiag.Fields = [("reply_bytes", .int(reply.text.utf8.count)), ("cancelled", .bool(Task.isCancelled))]
                if let t = reply.firstToken { f.append(("first_text_ms", .ms(t * 1000))) }
                for (k, u) in [("input_tokens", "input_tokens"), ("output_tokens", "output_tokens"),
                               ("reasoning_tokens", "reasoning_tokens"), ("cached_input_tokens", "cached_input_tokens")] {
                    if let n = reply.usage[u] { f.append((k, .int(n))) }
                }
                if let r = model as? ResponsesClient {
                    f.append(("tier_requested", .token(r.lastRequestedServiceTier ?? "omitted")))
                    f.append(("tier_confirmed", .token(r.lastServiceTier ?? "none")))
                }
                modelSpan.end(f)
            } catch {
                modelSpan.fail(error, [("cancelled", .bool(Task.isCancelled))])
                timing.modelMs = ms(m0, monotonic()); timings.append(timing)
                return finish(.error, "model request failed (\(model.model)): \(error.localizedDescription)")
            }
            timing.modelMs = ms(m0, monotonic())
            timing.firstTokenMs = reply.firstToken.map { $0 * 1000 }
            timing.serverInputTokens = reply.usage["prompt_tokens"] ?? reply.usage["input_tokens"]
            timing.serverOutputTokens = reply.usage["completion_tokens"] ?? reply.usage["output_tokens"]
            timing.serverReasoningTokens = reply.usage["reasoning_tokens"]
            if let r = model as? ResponsesClient {
                timing.tierRequested = r.lastRequestedServiceTier ?? "omitted"; timing.tierConfirmed = r.lastServiceTier
            }
            timings.append(timing)
            DebugLog.write("agent timing: " + timing.summary)
            if Task.isCancelled { return finish(.finish, "stopped by the user") }
            let d: ElementDecision
            do { d = try ElementDecision.parse(reply.text) } catch {
                parseFailures += 1
                emit(.error, "unparsable reply: \(error.localizedDescription)")
                if parseFailures >= 2 { return finish(.error, "the model did not answer in the THINK/DO format twice") }
                history.append("your last reply had no valid DO line")
                continue
            }
            emit(.think, d.thought + (d.ignoredActions > 0 ? " (\(d.ignoredActions) extra DO lines ignored)" : ""))
            switch d.action {
            case .done(let answer): return finish(.finish, "done: \(answer)")
            case .fail(let reason): return finish(.finish, "model stopped: \(reason)")
            case .wait:
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                do { obs = try await timedLook() } catch {
                    return finish(.error, "observation failed: \(error.localizedDescription)")
                }
                history.append("wait")
                continue
            case .type(let typed):
                let said = "type " + ElementPrompt.quote(typed, max: 40)  // history line: escaped
                guard let typing else {
                    history.append(said + " refused: typing is not available with this input backend")
                    emit(.blocked, "typing is not available (no WDA typing sink); nothing sent")
                    continue
                }
                if mode == .dryRun {
                    let detail = WDATextGate.evaluate(text: typed, observation: obs, expectedBundleID: bound, now: clock(), policy: policy)
                        .map { "WDA typing gate closed: " + $0.reasons.map { "\($0)" }.joined(separator: ", ") }
                        ?? "WDA typing gate open: would send POST /session/{id}/wda/keys (\(typed.count) characters)"
                    return finish(.finish, "dry run (direct WDA typing): " + detail + ". Nothing was sent to WDA.")
                }
                let b = bound
                let observeBound: () async throws -> WDAObservation = { [crossApp, provider] in
                    if let crossApp { return try await crossApp.driver.observeForeground(expected: b) }
                    return try await provider.observe(targetBundleID: b)
                }
                let step = WDATypeStep(bundleID: b, observe: observeBound, sink: typing, policy: policy, clock: clock)
                let s0 = monotonic()
                let r = await step.run(text: typed)
                recordStep(s0, nil)
                // the text itself is not logged (it may be private); only its length
                if r.taps > 0 { emit(.act, "WDA keys (\(b)): POST /session/{id}/wda/keys, \(typed.count) characters") }
                switch r.outcome {
                case .verified:
                    guard let after = r.after else { return finish(.error, "verified without an observation") }
                    obs = after
                    history.append(said + ": typed (screen changed)")
                    emit(.verify, "typing verified on a fresh observation of \(b) (source \(after.sourceDigest))")
                case .blocked(let reasons) where reasons.allSatisfy({ if case .noKeyboard = $0 { return true }; if case .untypableText = $0 { return true }; return false }):
                    if let before = r.before { obs = before }
                    let why = reasons.map { "\($0)" }.joined(separator: ", ")
                    history.append(said + " refused, nothing typed: \(why)")
                    emit(.blocked, "typing refused before sending (\(why)); nothing sent")
                case .blocked(let reasons):
                    return finish(.blocked, "WDA typing gate closed, nothing sent: " + reasons.map { "\($0)" }.joined(separator: ", "))
                case .tapNotSent(let why): return finish(.error, "typing not sent (\(why)); not retried")
                case .tapRejected(let why): return finish(.error, "WDA refused the typing request (\(why)); not retried")
                case .tapUncertain(let why):
                    return finish(.error, "typing result uncertain (\(why)); some or all of the text may have been typed. Not retyped; stopping")
                case .notVerified(let why): return finish(.error, "typing sent but not verified: \(why); stopping (no retry)")
                case .observationFailed(let why): return finish(.error, "observation failed: \(why)")
                case .selectionFailed, .alreadyConsumed: return finish(.error, "internal: unexpected typing step outcome")
                }
                continue
            case .tap(let i):
                guard cands.indices.contains(i), cands[i].tappable,
                      let ref = cands[i].sourceIndex.flatMap({ TargetRef(elementIndex: $0, in: obs) }) else {
                    history.append("tap \(i) refused: not a tappable listed element")
                    emit(.blocked, "tap #\(i): not a tappable listed element; nothing sent")
                    continue
                }
                let el = cands[i].element
                let name = el.label ?? el.identifier ?? "#\(i)"
                let said = "tap \(i) " + ElementPrompt.quote(name, max: 40)  // history line: escaped screen text
                // The exact element behind "N" (not a label re-lookup): see TargetRef.
                let target: SelectedTarget
                switch TargetSelection.resolve(ref, in: obs) {
                case .failure(let e):
                    history.append(said + " refused: \(e)")
                    emit(.blocked, "tap #\(i) \"\(name)\" refused before any WDA request: \(e)")
                    continue
                case .success(let t): target = t
                }
                if mode == .dryRun {
                    let detail: String
                    switch WDATapGate.evaluate(target: target, observation: obs, expectedBundleID: bound, now: clock(),
                                               policy: policy) {
                    case .success(let p): detail = "WDA tap gate open: would send " + p.summary
                    case .failure(let b): detail = "WDA tap gate closed: " + b.reasons.map { "\($0)" }.joined(separator: ", ")
                    }
                    return finish(.finish, String(format: "dry run (direct WDA tap): would tap #%d \"%@\". ", i, name)
                                  + detail + ". Nothing was sent to WDA.")
                }
                if let crossApp {
                    let timed = TimedTapSink(tapper, now: monotonic)
                    let step = CrossAppTapStep(bound: bound, driver: crossApp.driver, tapper: timed, policy: policy,
                                               settle: crossApp.settle, clock: clock)
                    let s0 = monotonic()
                    let r = await step.run(tap: ref, expect: .sourceChanged)
                    recordStep(s0, timed)
                    if let p = r.plan, r.taps > 0 { emit(.act, "WDA tap (\(bound)): " + p.summary) }
                    switch r.outcome {
                    case .verified:
                        guard let after = r.after else { return finish(.error, "verified without an observation") }
                        obs = after
                        history.append(said + ": screen changed (verified)")
                        emit(.verify, "verified on a fresh observation of \(bound) (source \(after.sourceDigest))")
                    case .launched(let b):
                        bound = b
                        do { obs = try await crossApp.driver.observeForeground(expected: b) } catch {
                            return finish(.error, "opened \(b) but could not observe it: \(error.localizedDescription)")
                        }
                        history.append(said + ": \(b) is now in front")
                        emit(.verify, "foreground is now \(b) (activeAppInfo); bound to it")
                    case .selectionFailed(let e):
                        if let b = r.before { obs = b }
                        history.append(said + " refused on the fresh screen: \(e)")
                        emit(.blocked, "target changed on the fresh observation (\(e)); nothing sent")
                    case .blocked(let reasons):
                        return finish(.blocked, "WDA tap gate closed, nothing sent: " + reasons.map { "\($0)" }.joined(separator: ", "))
                    case .foregroundChanged(let b):
                        return finish(.error, "the foreground app changed from \(bound) to \(b) after the tap; stopping (no retry)")
                    case .tapNotSent(let why): return finish(.error, "WDA tap not sent (\(why)); not retried")
                    case .tapRejected(let why): return finish(.error, "WDA refused the tap (\(why)); not retried")
                    case .tapUncertain(let why):
                        return finish(.error, "WDA tap result uncertain (\(why)); it may have landed. Not replayed or retried; stopping")
                    case .notVerified(let why): return finish(.error, "WDA tap sent but not verified: \(why); stopping (no retry)")
                    case .observationFailed(let why): return finish(.error, "observation failed: \(why)")
                    case .alreadyConsumed: return finish(.error, "internal: step reused")
                    }
                    continue
                }
                let timed = TimedTapSink(tapper, now: monotonic)
                let s0 = monotonic()
                var report: WDATapStepReport
                // Targeted only when the runner capability is configured and this tap can be checked by it; otherwise
                // the full pre-action observation, decided before anything is sent (never a fallback after a refusal).
                switch targetRevalidator.map({ ($0, WDATargetCheck.request(ref: ref, observation: obs, bound: bundleID)) }) {
                case .some((let revalidator, .success(let request))):
                    report = await WDATargetedTapStep(bundleID: bundleID, revalidator: revalidator, provider: provider,
                                                      tapper: timed, policy: policy, clock: clock)
                        .run(tap: ref, decidedOn: obs, request: request, expect: .sourceChanged)
                case let other:
                    report = await WDATapNavigationStep(bundleID: bundleID, provider: provider, tapper: timed,
                                                        policy: policy, clock: clock).run(tap: ref, expect: .sourceChanged)
                    if case .some((_, .failure(let why))) = other { report.preAct = .full(why.reason) }
                }
                recordStep(s0, timed, preAct: report.preAct)
                var diag: AgentDiag.Fields = [("path", .token(report.preAct.token)), ("taps", .int(report.taps))]
                if let v = report.revalidation {
                    diag += [("matches", .int(v.matchCount)), ("keyboards", .int(v.keyboards))]
                    if let n = v.nodesWalked { diag.append(("nodes_walked", .int(n))) }
                    if let e = v.elapsedMs { diag.append(("request_ms", .int(e))) }
                    for k in ["identity_before", "snapshot", "match", "identity_after", "total"] {
                        if let d = v.runnerMs[k] { diag.append(("runner_" + k + "_ms", .ms(d))) }
                    }
                }
                AgentDiag.event("agent.preact", diag)
                if let p = report.plan, report.taps > 0 { emit(.act, "WDA tap: " + p.summary) }
                switch report.outcome {
                case .verified:
                    guard let after = report.after else { return finish(.error, "verified without an observation") }
                    obs = after
                    history.append(said + ": screen changed (verified)")
                    emit(.verify, "verified on a fresh observation (source \(after.sourceDigest))")
                case .selectionFailed(let e):
                    if let b = report.before { obs = b } else {
                        // Targeted refusal: nothing was sent; the next decision gets a full fresh observation.
                        do { obs = try await timedLook() } catch {
                            return finish(.error, "observation failed: \(error.localizedDescription)")
                        }
                    }
                    history.append(said + " refused on the fresh screen: \(e)")
                    emit(.blocked, "target changed on the fresh \(report.preAct == .targeted ? "target revalidation" : "observation") (\(e)); nothing sent")
                case .blocked(let reasons):
                    return finish(.blocked, "WDA tap gate closed, nothing sent: " + reasons.map { "\($0)" }.joined(separator: ", "))
                case .tapNotSent(let why):
                    return finish(.error, "WDA tap not sent (\(why)); not retried")
                case .tapRejected(let why):
                    return finish(.error, "WDA refused the tap (\(why)); not retried")
                case .tapUncertain(let why):
                    return finish(.error, "WDA tap result uncertain (\(why)); it may have landed. Not replayed or retried, session kept; stopping")
                case .notVerified(let why):
                    return finish(.error, "WDA tap sent but not verified: \(why); stopping (no retry)")
                case .observationFailed(let why):
                    return finish(.error, "observation failed: \(why)")
                case .alreadyConsumed:
                    return finish(.error, "internal: step reused")
                }
                continue
            }
        }
        return finish(.finish, "step limit (\(maxSteps)) reached")
    }
}
