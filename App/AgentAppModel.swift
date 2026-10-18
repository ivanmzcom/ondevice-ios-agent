import Combine
import Foundation
import Security
import UIKit
import UnifiedAgentCore

/// The model API key, in this app's own Keychain item (never logged, never in UserDefaults).
enum APIKeyStore {
    private static var base: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: Bundle.main.bundleIdentifier ?? "unified-agent",
         kSecAttrAccount: "model-api-key"]
    }
    static func get() -> String {
        var q = base
        q[kSecReturnData] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
    static func set(_ v: String) {
        SecItemDelete(base as CFDictionary)
        guard !v.isEmpty else { return }
        var q = base
        q[kSecValueData] = Data(v.utf8)
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// Everything the task agent needs, and what is still missing before it may run.
@MainActor final class AgentAppModel: ObservableObject {
    // WDA session
    @Published private(set) var session: WDASession?
    /// The close of a dropped session (DELETE + runner task abort); a new open waits for it.
    private var closing: Task<Void, Never>?
    @Published private(set) var sessionBusy = false
    @Published var sessionStatus = "closed"
    @Published private(set) var lastObservation: WDAObservation?
    /// Last read-only JSON/XML `/source` comparison (formats, statuses, durations, sizes; never hierarchy text).
    @Published private(set) var sourceCompare = ""
    /// Last sanitized observe/open failure (Core WDA/FailureDetail.swift), kept across session drop/close and launches.
    @Published private(set) var lastFailure: FailureDetail? = FailureDetailStore().load()
    /// Why `lastFailure` is empty again (operator clear or a later successful observation).
    @Published private(set) var lastFailureNote = ""

    /// Cross-app start (Core WDA/CrossApp.swift): start at Inicio (Home) and follow the real foreground app instead
    /// of activating the selected app. Persisted; the main screen shows the choice.
    @Published var startAtHome = UserDefaults.standard.bool(forKey: "startAtHome") {
        didSet { UserDefaults.standard.set(startAtHome, forKey: "startAtHome") }
    }
    /// How Inicio opens a requested app: its visible icon (default) or one direct activation.
    @Published var launchMethod = LaunchMethod(rawValue: UserDefaults.standard.string(forKey: "launchMethod") ?? "") ?? .icon {
        didSet { UserDefaults.standard.set(launchMethod.rawValue, forKey: "launchMethod") }
    }

    // model (upstream LLMClient semantics: OpenAI-compatible endpoint + user's own key)
    @Published var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: "modelBaseURL") } }
    @Published var modelID: String { didSet { UserDefaults.standard.set(modelID, forKey: "modelID") } }
    @Published var apiKey: String { didSet { APIKeyStore.set(apiKey) } }
    @Published var modelCheck = ""

    // gate policy: 2 s observation age by default; adjustable for the device's WDA timing
    @Published var maxObservationAge: Double = GatePolicy().maxObservationAge

    @Published private(set) var agent: TaskAgent?

    // Live Activity of the current run (LiveActivityLifecycle.swift); only an explicit task start creates one.
    private let liveActivity: RunActivityController
    private var activityEvents: AnyCancellable?
    private var stopCause: RunStopCause?

    /// EXPERIMENTAL, opt-in, persisted: silent audio (mixes with other audio, no microphone) while a task runs, so
    /// iOS may keep this app running in the background. Not guaranteed (BackgroundAudio.swift in Core).
    @Published var backgroundAudio = UserDefaults.standard.bool(forKey: "experimentalBackgroundAudio") {
        didSet { UserDefaults.standard.set(backgroundAudio, forKey: "experimentalBackgroundAudio") }
    }
    @Published private(set) var audioState: BackgroundAudioKeeper.State = .off
    private let audio = BackgroundAudioKeeper(output: SilentAudioOutput())

    #if DEBUG
    // EXPERIMENTAL ChatGPT plan backend (ChatGPTPlan.swift). Its own Keychain items, model id and transport; when
    // selected, tasks never use `apiKey` or `baseURL`, and a plan failure is never retried on the API-key endpoint.
    let chatGPT = ChatGPTAccount(store: KeychainChatGPTStore(), browser: { SystemChatGPTBrowser() })
    @Published var useChatGPTPlan = UserDefaults.standard.bool(forKey: "useChatGPTPlan") {
        didSet { UserDefaults.standard.set(useChatGPTPlan, forKey: "useChatGPTPlan") }
    }
    @Published var chatGPTModelID = UserDefaults.standard.string(forKey: "chatGPTModelID") ?? "" {
        didSet { UserDefaults.standard.set(chatGPTModelID, forKey: "chatGPTModelID") }
    }
    @Published var chatGPTModels: [String] = []
    @Published var chatGPTStatus = ""
    @Published var chatGPTUsage = ""
    private var chatGPTChanges: AnyCancellable?
    #endif

    /// The ChatGPT plan backend is selected (Debug builds only; Release always uses the API-key endpoint).
    var usesChatGPTPlan: Bool {
        #if DEBUG
        return useChatGPTPlan
        #else
        return false
        #endif
    }

    init(liveActivity: LiveActivityBoundary = ActivityKitBoundary()) {
        // Settings stored by earlier builds of this app (LegacyPrefs.swift): dropped, never read, never a startup condition.
        Self.purgeLegacyPrefs(.standard)
        self.liveActivity = RunActivityController(boundary: liveActivity)
        baseURL = UserDefaults.standard.string(forKey: "modelBaseURL") ?? ""
        // The model the user selected for iPhone control; sent as `model` to the endpoint configured above.
        modelID = UserDefaults.standard.string(forKey: "modelID") ?? "gpt-6-luna"
        apiKey = APIKeyStore.get()
        #if DEBUG
        chatGPTChanges = chatGPT.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        #endif
        // An activity left by a killed run ends at launch; the Stop button of a live one stops the run.
        Task { await liveActivity.endOrphans() }
        AgentDiag.event("build", BuildStamp.diagFields(bundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                                                       libVersion: UniRunner.version,
                                                       storedSourceConfig: UserDefaults.standard.string(forKey: WDASourcePreset.defaultsKey)))
        audio.onChange = { [weak self] s in self?.audioState = s }
        AgentControl.handle = { [weak self] command in
            if command == .stop { self?.stopRun() }
        }
    }

    /// Removes the obsolete keys in `LegacyPrefs` (LegacyPrefs.swift) from `d`; anything else is left alone.
    static func purgeLegacyPrefs(_ d: UserDefaults) { LegacyPrefs.purge(d) }

    var endpoint: ModelEndpoint { ModelEndpoint(baseURL: baseURL, model: modelID, apiKey: apiKey) }
    var policy: GatePolicy { var p = GatePolicy(); p.maxObservationAge = maxObservationAge; return p }

    // MARK: WDA session

    func openSession(runner: String, heartbeat: Bool) {
        Task { try? await openSessionNow(runner: runner, heartbeat: heartbeat) }
    }

    /// Launches the runner once and opens the persistent session (the main flow's only session owner).
    func openSessionNow(runner: String, heartbeat: Bool) async throws {
        guard session == nil else { return }
        guard !sessionBusy else { throw StartFlowError.step("La sesión WDA está ocupada") }
        guard let pairing = try? PairingStore.load() else {
            sessionStatus = "no imported pairing record"
            throw StartFlowError.step("No se pudo leer el registro de emparejamiento")
        }
        sessionBusy = true
        defer { sessionBusy = false }
        // The previous runner's teardown finishes before a new runner is launched, so it never overlaps the new one.
        if let c = closing { sessionStatus = "closing the previous WDA session…"; await c.value; closing = nil }
        sessionStatus = "launching WDA runner (15–90 s)…"
        lastObservation = nil
        switch await WDASession.open(pairing: pairing, deviceIP: PacketTunnelKeys.defaultPeer, runner: runner, heartbeat: heartbeat) {
        case .success(let (s, _)):
            session = s
            sessionStatus = "open"
        case .failure(let f):
            recordFailure(f, operation: "open")
            sessionStatus = "FAILED (\(f.code)): \(f.json)"
            throw StartFlowError.step("No se abrió la sesión WDA: \(WDASessionLoss.label(code: f.code, json: f.json))")
        }
    }

    /// Forgets a session WDA no longer knows; the next start opens a new one. Nothing is replayed.
    func dropSession(lost: Bool = true) {
        guard let s = session else { return }
        session = nil
        lastObservation = nil
        // The failure that led here stays; it only notes that its session is gone.
        if var f = lastFailure, !f.sessionDropped { f.sessionDropped = true; FailureDetailStore().save(f); lastFailure = f }
        AgentDiag.event("session.drop", [("lost", .bool(lost)), ("agent_running", .bool(agent?.running == true))])
        sessionStatus = lost ? "WDA session lost (\(s.lostReason ?? "session_lost")); Iniciar opens a new one" : "closed"
        let previous = closing
        closing = Task { await previous?.value; await s.close() }
    }

    func closeSession() { dropSession(lost: false) }

    private func recordFailure(_ error: Error, operation: String) {
        guard let f = error as? UniRunner.Failure else { return }
        let d = FailureDetail.from(code: f.code, json: f.json, operation: operation, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        FailureDetailStore().save(d)
        lastFailure = d
        lastFailureNote = ""
    }

    private func clearFailure(by: String) {
        guard lastFailure != nil else { return }
        FailureDetailStore().clear()
        lastFailure = nil
        lastFailureNote = "cleared by \(by) at \(ISO8601DateFormatter().string(from: Date()))"
    }

    func clearLastFailure() { clearFailure(by: "operator") }

    /// Fresh observation for the main flow; a dead session becomes `.sessionLost`.
    func observeNow(target: String) async throws {
        guard let s = session else { throw StartFlowError.sessionLost }
        guard !sessionBusy else { throw StartFlowError.step("La sesión WDA está ocupada") }
        sessionBusy = true
        defer { sessionBusy = false }
        do {
            // Inicio: look at whatever is in front without activating the selected app.
            let o = startAtHome ? try await s.observeForeground(expected: nil) : try await s.observe(targetBundleID: target)
            lastObservation = o
            clearFailure(by: "successful observe")
            sessionStatus = "observed \(o.bundleID): \(o.elements.count) elements"
        } catch let f as UniRunner.Failure where WDASessionLoss.matches(code: f.code, json: f.json) {
            recordFailure(f, operation: "observe")
            throw StartFlowError.sessionLost
        } catch {
            recordFailure(error, operation: "observe")
            sessionStatus = "observe failed: \(error.localizedDescription)"
            let why = (error as? UniRunner.Failure).map { ": \(WDASessionLoss.label(code: $0.code, json: $0.json))" } ?? ""
            throw StartFlowError.step("Falló la observación de la app" + why)
        }
    }

    func observe(target: String) {
        guard let s = session, !sessionBusy else { return }
        sessionBusy = true
        Task {
            defer { sessionBusy = false }
            do {
                let o = try await s.observe(targetBundleID: target)
                lastObservation = o
                clearFailure(by: "successful observe")
                sessionStatus = "observed \(o.bundleID): \(o.elements.count) elements, window \(Int(o.windowSize.width))x\(Int(o.windowSize.height)) \(o.orientation), foreground \(o.appStateBefore)→\(o.appStateAfter)"
            } catch let f as UniRunner.Failure where WDASessionLoss.matches(code: f.code, json: f.json) {
                recordFailure(f, operation: "observe")
                sessionBusy = false
                dropSession()
            } catch {
                recordFailure(error, operation: "observe")
                sessionStatus = "observe failed: \(error.localizedDescription)"
            }
        }
    }

    /// Advanced diagnostic (WDA_500_DIAGNOSIS.md §7 R0/R1): read-only JSON then XML `/source` in the open session.
    /// No tap, Home, activation or model call; refused during a task, a one-shot or another session call.
    func compareSourceFormats() {
        guard let s = session, !sessionBusy, agent?.running != true else { return }
        sessionBusy = true
        sourceCompare = "Comparando /source JSON y XML (hasta 2 min)…"
        Task {
            defer { sessionBusy = false }
            switch await s.compareSource() {
            case .success(let json):
                guard let c = try? WDASourceComparison(json: json) else { sourceCompare = "Respuesta no reconocida"; return }
                AgentDiag.event("wda.compare_source.result", c.diagFields)
                sourceCompare = (c.lines + [c.verdict, "Config: \(s.sourceConfig)"]).joined(separator: "\n")
                if c.sessionLost { sessionBusy = false; dropSession() }
            case .failure(let f):
                sourceCompare = "Falló: \(f.diagClass)"
                if WDASessionLoss.matches(code: f.code, json: f.json) { sessionBusy = false; dropSession() }
            }
        }
    }

    // MARK: task

    /// Why the selected model backend cannot run a task, or nil. ChatGPT plan and API key stay separate.
    var modelProblem: String? {
        #if DEBUG
        if useChatGPTPlan {
            if !chatGPT.ready { return "Inicia sesión en ChatGPT y permite el uso del plan" }
            if chatGPTModelID.isEmpty { return "Elige un modelo del plan de ChatGPT" }
            return nil
        }
        #endif
        return endpoint.problem
    }

    @discardableResult
    func run(task: String, target: String, mode: AgentMode, onEnd: (@MainActor (String?) -> Void)? = nil) -> Bool {
        guard let s = session, agent?.running != true, !sessionBusy else { return false }
        // Silence that was asked for but stopped during preparation (interruption, route): the task does not start.
        if backgroundAudio, case .lost = audio.state { return false }
        if backgroundAudio { startAudio() }
        // The session observes, taps (/wda/tap) and types (/wda/keys): the only input path.
        var a = TaskAgent(provider: s, endpoint: endpoint, tapper: s, policy: policy)
        var finished: () -> Void = {}
        #if DEBUG
        if useChatGPTPlan {
            let account = chatGPT
            let client = ResponsesClient(model: chatGPTModelID, token: { try await account.accessToken() })
            a = TaskAgent(provider: s, chatGPT: client, tapper: s, policy: policy)
            chatGPTUsage = ""
            finished = { [weak self] in
                self?.chatGPTUsage = client.lastUsage.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            }
        }
        #endif
        if startAtHome { a.crossApp = CrossAppConfig(driver: s, method: launchMethod) }
        a.wdaText = s
        // Targeted pre-tap revalidation needs the Hermes runner's compact observer (bound observations carry the pid).
        if WDAObserver.stored(UserDefaults.standard.string(forKey: WDAObserver.defaultsKey)) == .compact { a.targetRevalidator = s }
        agent = a
        stopCause = nil
        // The target app is in front during the run, so this app is in the background: iOS grants limited time.
        // The Live Activity only shows the run; it does not extend that time.
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "agent-run") { [weak self, weak a] in
            self?.stopCause = .backgroundExpired
            AgentDiag.event("background.expired", [("audio_active", .bool(self?.audio.isActive == true))])
            self?.audio.end("background_expired")
            a?.stop()
            UIApplication.shared.endBackgroundTask(bg)
        }
        // Normally already shown since Iniciar (beginActivity); started here only if it is not (then this app
        // must still be in front, or ActivityKit refuses and the run goes on without one).
        let activity = liveActivity
        activity.start(runID: UUID().uuidString, limit: a.maxSteps)
        a.start(task: task, bundleID: target, mode: mode) { [weak self] in
            Task { @MainActor in
                finished()
                self?.activityEvents = nil
                // Ended before the background time is given up, so the final state reaches the system.
                await activity.finish(RunEnd.classify(outcome: a.outcome, stop: self?.stopCause))
                self?.audio.end("run_end")
                UIApplication.shared.endBackgroundTask(bg)
                // A session the run proved dead is shown closed; nothing is reopened or replayed until Iniciar.
                if s.lostReason != nil, self?.session === s { self?.dropSession() }
                onEnd?(a.outcome)
            }
        }
        // Event kinds only: their texts (task, model words, element labels) stay out of the activity.
        var seen = 0
        activityEvents = a.$events.sink { events in
            defer { seen = events.count }
            for (i, e) in events.enumerated().dropFirst(seen) {
                if let s = Self.signal(e.kind, first: i == 0) { activity.handle(s) }
            }
        }
        return true
    }

    /// The Live Activity of an accepted Iniciar, shown from the tap on (the task agent's default step limit).
    /// With the experimental toggle on, the silence starts here too: this app is still in front, before the observe
    /// step brings the target app forward (an audio session cannot be activated from the background).
    func beginActivity() {
        liveActivity.start(runID: UUID().uuidString, limit: TaskAgent.defaultMaxSteps)
        if backgroundAudio { startAudio() }
    }

    /// Ends the activity (and any silence) of a start that never reached the task.
    func endActivity(_ end: RunEnd) async {
        audio.end("start_not_reached")
        await liveActivity.finish(end)
    }

    /// Idempotent. If the silence stops on its own (interruption, route, media reset, time cap), the running task is
    /// stopped once, like a user Stop: nothing is replayed and the task is not restarted.
    private func startAudio() {
        audio.begin { [weak self] _ in
            guard let self, let a = self.agent, a.running else { return }
            self.stopCause = .audioLost
            AgentDiag.event("run.stop_audio_lost")
            a.stop()
        }
    }

    /// Stop from the Task section or the Live Activity's Stop button.
    func stopRun() {
        guard let a = agent, a.running else { return }
        stopCause = .user
        AgentDiag.event("run.stop_user")
        audio.end("user_stop")
        a.stop()
    }

    nonisolated static func signal(_ kind: AgentEvent.Kind, first: Bool) -> RunSignal? {
        switch kind {
        case .observe: return first ? .observing : .thinking  // later observations are followed by the model request
        case .think: return .thinking
        case .act: return .acted
        case .verify: return .verified
        case .blocked: return .blocked
        case .error: return .retrying  // an unparsable reply is asked again; a terminal error is ended by finish()
        case .finish: return nil
        }
    }

    func checkModel() {
        modelCheck = "asking \(baseURL) for its models…"
        let e = endpoint
        Task {
            do {
                let ids = try await e.listModels()
                modelCheck = ids.contains(e.model) ? "endpoint lists \(e.model)" : "endpoint answered but does not list \(e.model) (\(ids.count) models)"
            } catch { modelCheck = "check failed: \(error.localizedDescription)" }
        }
    }

    #if DEBUG
    func loadChatGPTModels() {
        chatGPTStatus = "loading the plan's model catalog…"
        Task {
            do {
                chatGPTModels = try await ResponsesClient.models(token: try await chatGPT.accessToken())
                if chatGPTModelID.isEmpty, let first = chatGPTModels.first { chatGPTModelID = first }
                chatGPTStatus = "\(chatGPTModels.count) models"
            } catch { chatGPTStatus = "catalog failed: \(error.localizedDescription)" }
        }
    }
    #endif
}
