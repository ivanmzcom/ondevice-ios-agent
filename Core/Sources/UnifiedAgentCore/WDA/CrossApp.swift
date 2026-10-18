import Foundation

// Cross-app navigation over the direct WDA backend (explicit start context: Inicio). WDA's session has no tested
// app, so `/source` and `/wda/tap` act on the real foreground app; this layer binds every observation and tap to the
// bundle `GET /session/{id}/wda/activeAppInfo` reports, never activates the old target to make an observation pass,
// and lets the bound app change only by one launch from SpringBoard (an icon tap) or one explicit open-app action
// for the requested app. Any other foreground change stops the run. Taps keep `WDATapGate`'s technical checks, and
// a written mutation is never replayed or retried by another route. Which apps a run works in follows the user's task
// (an app the task opens is observed and operated like any other); there is no app block list.

public enum SpringBoard { public static let bundleID = "com.apple.springboard" }

/// Where a run starts, chosen by the operator. `.app` is the existing behaviour (the selected app is activated for
/// every observation); `.home` starts from the Home Screen and follows the real foreground app.
public enum StartContext: Equatable, Sendable {
    case home
    case app(String)
}

/// How a requested app is opened from `.home`: its visible SpringBoard icon (default) or one direct activation.
public enum LaunchMethod: String, CaseIterable, Sendable { case icon, activate }

/// Read-only foreground queries; nothing here activates, relaunches or terminates an app.
public protocol WDAForegroundSource: AnyObject {
    /// Bundle id of the foreground app (`activeAppInfo`).
    func activeApp() async throws -> String
    /// A fresh observation of whatever is in front; with `expected`, refused unless that app is in front before and
    /// after the read (unified-ffi `uni_session_observe_foreground`).
    func observeForeground(expected: String?) async throws -> WDAObservation
}

/// Navigation mutations other than taps. `WDATapError` semantics: one write, never retried.
public protocol WDANavigationSink: AnyObject {
    func pressHome() async throws
    func activate(bundleID: String) async throws
}

public typealias WDACrossAppDriver = WDAForegroundSource & WDANavigationSink

/// App names an operator types, and the bundle the launch must end in.
public enum KnownApps {
    public static let table: [(names: [String], bundleID: String)] = [
        (["whatsapp"], "net.whatsapp.WhatsApp"),
        (["ajustes", "settings", "configuracion"], "com.apple.Preferences"),
        (["safari"], "com.apple.mobilesafari"),
        (["notas", "notes"], "com.apple.mobilenotes"),
        (["mapas", "maps"], "com.apple.Maps"),
        (["fotos", "photos"], "com.apple.mobileslideshow"),
        (["calendario", "calendar"], "com.apple.mobilecal"),
        (["reloj", "clock"], "com.apple.mobiletimer"),
        (["calculadora", "calculator"], "com.apple.calculator"),
    ]
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
    public static func bundleID(forName name: String) -> String? {
        let n = fold(name)
        return table.first { $0.names.contains(n) }?.bundleID
    }
    /// The icon label names the requested app (case and accents ignored).
    static func label(_ label: String?, names name: String) -> Bool {
        guard let label else { return false }
        let l = fold(label), n = fold(name)
        if l == n { return true }
        guard let b = bundleID(forName: name) else { return false }
        return table.first { $0.bundleID == b }?.names.contains(l) ?? false
    }
}

/// "Abrir WhatsApp" / "Open Safari": a launch-only task. The run opens the app, confirms it is in front and stops.
public struct LaunchIntent: Equatable, Sendable {
    public var appName: String
    public var bundleID: String?

    /// Only a task that is nothing but "open <app>"; "open <app> and …" is `TaskIntent.openThen`, not this.
    public static func parse(_ task: String) -> LaunchIntent? {
        if case .launchOnly(let i) = TaskIntent.classify(task) { return i }
        return nil
    }
}

/// What a task says about opening an app, from its own words only (never from screen text).
public enum TaskIntent: Equatable, Sendable {
    /// "Abrir WhatsApp": open it, confirm it is in front, stop without reading it.
    case launchOnly(LaunchIntent)
    /// "Abre WhatsApp y …" / "Open Notes, then …": open it (same launch and identity check), then keep working
    /// in it for the rest of the task.
    case openThen(LaunchIntent)
    case other

    static let verbs: Set<String> = ["abrir", "abre", "open", "launch", "lanza"]
    /// Words that end the app name and start the rest of the task.
    static let joiners: Set<String> = ["y", "e", "and", "then", "luego", "despues", "para", "to", "&", ","]

    public static func classify(_ task: String) -> TaskIntent {
        var spaced = ""
        for ch in task { if ",;:".contains(ch) { spaced += " , " } else { spaced.append(ch) } }
        let words = spaced.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2, verbs.contains(KnownApps.fold(words[0])) else { return .other }
        var rest = Array(words.dropFirst())
        if let f = rest.first.map(KnownApps.fold), ["la", "el", "app", "the"].contains(f), rest.count > 1 { rest.removeFirst() }
        if let f = rest.first.map(KnownApps.fold), f == "app", rest.count > 1 { rest.removeFirst() }
        let whole = rest.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
        if KnownApps.bundleID(forName: whole) != nil { return .launchOnly(LaunchIntent(appName: whole, bundleID: KnownApps.bundleID(forName: whole))) }
        let cut = rest.firstIndex { joiners.contains(KnownApps.fold($0)) || $0 == "," }
        let nameWords = cut.map { Array(rest[..<$0]) } ?? rest
        let name = nameWords.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
        guard !name.isEmpty, name.count <= 40 else { return .other }
        let intent = LaunchIntent(appName: name, bundleID: KnownApps.bundleID(forName: name))
        guard let cut else { return .launchOnly(intent) }
        let tail = rest[cut...].filter { !joiners.contains(KnownApps.fold($0)) && $0 != "," }
        return tail.isEmpty ? .launchOnly(intent) : .openThen(intent)
    }
}

/// Bounded read-only polling of `activeApp` while a launch or Home settles (never a mutation retry).
public struct SettlePolicy: Sendable {
    public var attempts: Int, delayNanos: UInt64
    public init(attempts: Int = 8, delayNanos: UInt64 = 500_000_000) { (self.attempts, self.delayNanos) = (attempts, delayNanos) }
}

func settle(_ source: WDAForegroundSource, _ policy: SettlePolicy, until done: (String) -> Bool) async throws -> String {
    var bundle = try await source.activeApp()
    var n = 1
    while !done(bundle) && n < max(1, policy.attempts) {
        if policy.delayNanos > 0 { try? await Task.sleep(nanoseconds: policy.delayNanos) }
        bundle = try await source.activeApp()
        n += 1
    }
    return bundle
}

public enum CrossAppStepOutcome: Equatable, Sendable {
    case observationFailed(String)
    case selectionFailed(SelectionError)
    case blocked([WDATapBlock])
    case tapNotSent(String)
    case tapRejected(String)
    case tapUncertain(String)
    /// Same app, fresh observation changed as expected.
    case verified
    case notVerified(String)
    /// An icon tap on SpringBoard launched this app: the caller rebinds to it.
    case launched(String)
    /// The foreground app changed in a way this step did not allow. Stop.
    case foregroundChanged(String)
    case alreadyConsumed
}

/// A SpringBoard observation the launcher just read and may hand to the icon tap step instead of a second full
/// `/source` read (DUPLICATE_OBSERVATION_REPORT.md). Only for the deterministic launch path: no model call, wait or
/// other input between the read and the tap. `obtainedAt` is monotonic (nanoseconds) when the read returned.
public struct ReusableSnapshot: Sendable {
    public var observation: WDAObservation
    public var obtainedAt: UInt64
    public init(observation: WDAObservation, obtainedAt: UInt64) { (self.observation, self.obtainedAt) = (observation, obtainedAt) }
}

/// Monotonic budget for `ReusableSnapshot`; the gate's `maxObservationAge` on `capturedAt` still applies on top.
public enum SnapshotReuse {
    public static let budgetNanos: UInt64 = 1_500_000_000
    public static let monotonic: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
}

public struct CrossAppStepReport: Equatable, Sendable {
    public var outcome: CrossAppStepOutcome
    public var before: WDAObservation?
    public var plan: WDATapPlan?
    public var taps = 0
    public var after: WDAObservation?
}

/// One WDA tap bound to the foreground app `bound`: fresh foreground observation (refused if another app is in
/// front) -> select -> gate -> one tap -> read the foreground app. The bound app may change only from SpringBoard
/// through an icon tap (a launch); then no observation of the new app is taken here.
@MainActor public final class CrossAppTapStep {
    public let bound: String
    let driver: WDAForegroundSource
    let tapper: WDATapSink
    let policy: GatePolicy
    let settlePolicy: SettlePolicy
    let clock: () -> Date
    let monotonic: () -> UInt64
    private(set) var consumed = false
    /// The tap may launch another app whatever the element type (a Spotlight result the model chose).
    var launchAllowed = false

    public init(bound: String, driver: WDAForegroundSource, tapper: WDATapSink, policy: GatePolicy = GatePolicy(),
                settle: SettlePolicy = SettlePolicy(), clock: @escaping () -> Date = Date.init,
                monotonic: @escaping () -> UInt64 = SnapshotReuse.monotonic) {
        self.bound = bound; self.driver = driver; self.tapper = tapper; self.policy = policy
        self.settlePolicy = settle; self.clock = clock; self.monotonic = monotonic
    }

    /// `reusing` (launcher only): a SpringBoard snapshot read just before, with no input since. It replaces the fresh
    /// read only if it is of the bound SpringBoard, in the foreground, within `SnapshotReuse.budgetNanos`, and a
    /// lightweight `activeApp` still reports SpringBoard; otherwise the step takes the usual fresh read. A matching
    /// foreground does not prove the screen is unchanged: that is why reuse is limited to this immediate path and
    /// the gate still checks the snapshot's age, window and orientation.
    public func run(tap selector: TargetSelector, expect: Expectation, reusing: ReusableSnapshot? = nil) async -> CrossAppStepReport {
        await run(expect: expect, reusing: reusing) { TargetSelection.select(selector, in: $0) }
    }

    /// The element the model chose, re-resolved on the fresh foreground observation (`TargetSelection.resolve`).
    public func run(tap ref: TargetRef, expect: Expectation) async -> CrossAppStepReport {
        await run(expect: expect, reusing: nil) { TargetSelection.resolve(ref, in: $0) }
    }

    private func run(expect: Expectation, reusing: ReusableSnapshot?,
                     resolve: (WDAObservation) -> Result<SelectedTarget, SelectionError>) async -> CrossAppStepReport {
        var report = CrossAppStepReport(outcome: .alreadyConsumed)
        guard !consumed else { return report }
        var before: WDAObservation! = nil
        if let reusing {
            let o = reusing.observation
            let age = monotonic() &- reusing.obtainedAt
            var decision = "reused"
            if bound != SpringBoard.bundleID || o.bundleID != bound || !o.foreground { decision = "context_mismatch" }
            else if reusing.obtainedAt > monotonic() || age > SnapshotReuse.budgetNanos { decision = "stale" }
            else {
                do { if try await driver.activeApp() != bound { decision = "foreground_changed" } } catch { decision = "foreground_unknown" }
            }
            AgentDiag.event("observe.reuse", [("decision", .token(decision)), ("age_ms", .ms(Double(age) / 1e6)),
                                              ("full_source_reads_saved", .int(decision == "reused" ? 1 : 0))])
            if decision == "reused" { before = o }
        }
        if before == nil {
            do { before = try await driver.observeForeground(expected: bound) } catch {
                report.outcome = .observationFailed(error.localizedDescription); return report
            }
        }
        report.before = before
        let target: SelectedTarget
        switch resolve(before) {
        case .failure(let e): report.outcome = .selectionFailed(e); return report
        case .success(let t): target = t
        }
        let plan: WDATapPlan
        switch WDATapGate.evaluate(target: target, observation: before, expectedBundleID: bound, now: clock(), policy: policy) {
        case .failure(let b): report.outcome = .blocked(b.reasons); return report
        case .success(let p): plan = p
        }
        report.plan = plan
        consumed = true
        report.taps = 1
        do { try await tapper.tap(at: plan.point, window: plan.window) } catch WDATapError.notSent(let m) {
            report.outcome = .tapNotSent(m); return report
        } catch WDATapError.rejected(let m) {
            report.outcome = .tapRejected(m); return report
        } catch {
            report.outcome = .tapUncertain(error.localizedDescription); return report
        }
        let acted = clock()
        let launch = launchAllowed || (bound == SpringBoard.bundleID && target.element.type == "XCUIElementTypeIcon")
        // SpringBoard <-> Spotlight overlay host: the same Home context, rebound, never a foreground mismatch.
        let overlay = { (b: String) in SpotlightOverlay.hostBundleIDs.contains(self.bound) && SpotlightOverlay.hostBundleIDs.contains(b) }
        let now: String
        do {
            now = try await settle(driver, launch ? settlePolicy : SettlePolicy(attempts: 1, delayNanos: 0)) { $0 != self.bound }
        } catch {
            report.outcome = .notVerified("foreground app unknown after the tap: \(error.localizedDescription)"); return report
        }
        if now != bound {
            report.outcome = launch || overlay(now) ? .launched(now) : .foregroundChanged(now)
            return report
        }
        if launch { report.outcome = .notVerified("SpringBoard is still in front after the icon tap"); return report }
        let after: WDAObservation
        do { after = try await driver.observeForeground(expected: bound) } catch {
            // Spotlight may take over from SpringBoard just after the first read: one more read-only look.
            if SpotlightOverlay.hostBundleIDs.contains(bound), let b = try? await driver.activeApp(), b != bound, overlay(b) {
                report.outcome = .launched(b); return report
            }
            report.outcome = .notVerified("no observation after the tap: \(error.localizedDescription)"); return report
        }
        report.after = after
        switch StepVerification.verify(after, expect: expect, before: before, bundleID: bound, actedAt: acted) {
        case .verified: report.outcome = .verified
        case .notVerified(let why): report.outcome = .notVerified(why)
        }
        return report
    }
}

/// Launch-only task from `.home`: Home (live), find the requested app's visible icon on SpringBoard, one tap (or one
/// explicit activation), confirm the foreground bundle and stop. The launched app's screen is never read.
@MainActor public struct CrossAppLauncher {
    public let driver: WDACrossAppDriver
    public let tapper: WDATapSink
    public var method: LaunchMethod = .icon
    public var policy = GatePolicy()
    public var settle = SettlePolicy()
    public var clock: () -> Date = Date.init
    public var monotonic: () -> UInt64 = SnapshotReuse.monotonic
    /// Missing icon: search the app in Spotlight (typing sink + the model's result choice). nil = stop as before.
    public var spotlight: (text: WDATextSink, chooser: SpotlightChooser)?

    public init(driver: WDACrossAppDriver, tapper: WDATapSink, method: LaunchMethod = .icon, policy: GatePolicy = GatePolicy(),
                settle: SettlePolicy = SettlePolicy(), clock: @escaping () -> Date = Date.init,
                monotonic: @escaping () -> UInt64 = SnapshotReuse.monotonic) {
        self.driver = driver; self.tapper = tapper; self.method = method; self.policy = policy; self.settle = settle; self.clock = clock
        self.monotonic = monotonic
    }

    public enum Result: Equatable, Sendable {
        case launched(String)
        case dryRun(String)
        case stopped(String)
        case failed(String)
    }

    /// Presses Home once (live only) and waits, read-only, for SpringBoard.
    func goHome(dryRun: Bool, log: (AgentEvent.Kind, String) -> Void) async -> String? {
        if dryRun { return nil }
        do { try await driver.pressHome() } catch WDATapError.notSent(let m) { return "Inicio no enviado (\(m)); no se reintenta" }
        catch WDATapError.rejected(let m) { return "WDA rechazó Inicio (\(m)); no se reintenta" }
        catch { return "resultado de Inicio incierto (\(error.localizedDescription)); no se repite" }
        log(.act, "WDA: POST /session/{id}/wda/pressButton {\"name\":\"home\"}")
        do {
            let now = try await CrossAppKit.settle(driver, settle) { $0 == SpringBoard.bundleID }
            return now == SpringBoard.bundleID ? nil : "tras Inicio la app en primer plano es \(now), no SpringBoard"
        } catch { return "app en primer plano desconocida tras Inicio: \(error.localizedDescription)" }
    }

    public func run(_ intent: LaunchIntent, start: StartContext, dryRun: Bool,
                    log: (AgentEvent.Kind, String) -> Void = { _, _ in }) async -> Result {
        guard start == .home else {
            return .stopped("abrir otra app solo se permite empezando en Inicio; nada enviado")
        }
        if method == .activate {
            guard let b = intent.bundleID else { return .stopped("no conozco el bundle de \"\(intent.appName)\" para activarla; nada enviado") }
            if dryRun { return .dryRun("abriría \(intent.appName) con POST /session/{id}/wda/apps/activate {\"bundleId\":\"\(b)\"}; nada enviado") }
            do { try await driver.activate(bundleID: b) } catch WDATapError.notSent(let m) { return .failed("activación no enviada (\(m)); no se reintenta") }
            catch WDATapError.rejected(let m) { return .failed("WDA rechazó la activación (\(m)); no se reintenta") }
            catch { return .failed("activación incierta (\(error.localizedDescription)); no se repite") }
            log(.act, "WDA: POST /session/{id}/wda/apps/activate \(b)")
            return await confirm(b, intent)
        }
        if let why = await goHome(dryRun: dryRun, log: log) { return .failed(why) }
        let home: WDAObservation
        do { home = try await driver.observeForeground(expected: dryRun ? nil : SpringBoard.bundleID) } catch {
            return .failed("no se pudo observar la pantalla de inicio: \(error.localizedDescription)")
        }
        let homeAt = monotonic()
        if home.bundleID != SpringBoard.bundleID {
            return .dryRun("primero pulsaría Inicio (POST /session/{id}/wda/pressButton home); ahora está \(home.bundleID). Nada enviado")
        }
        let icons = home.elements.filter { $0.type == "XCUIElementTypeIcon" && $0.visible && KnownApps.label($0.label, names: intent.appName) }
        guard let icon = icons.first else {
            if let spotlight {
                log(.observe, "no veo el icono de \(intent.appName) en la página visible; se busca en Spotlight")
                return await SpotlightFallback(driver: driver, tapper: tapper, text: spotlight.text, chooser: spotlight.chooser,
                                               policy: policy, settle: settle, clock: clock)
                    .run(intent, home: home, dryRun: dryRun, log: log)
            }
            return .stopped("no veo el icono de \(intent.appName) en la pantalla de inicio visible; no se desplaza ni se inventan coordenadas. Ponlo en la primera página o el Dock")
        }
        guard icons.count == 1 else { return .stopped("\(icons.count) iconos coinciden con \(intent.appName); no se adivina") }
        let selector = TargetSelector(identifier: icon.identifier, label: icon.label)
        if dryRun {
            switch TargetSelection.select(selector, in: home) {
            case .failure(let e): return .stopped("icono de \(intent.appName) no utilizable: \(e)")
            case .success(let t):
                switch WDATapGate.evaluate(target: t, observation: home, expectedBundleID: SpringBoard.bundleID, now: clock(), policy: policy) {
                case .success(let p): return .dryRun("tocaría el icono \"\(icon.label ?? "")\": \(p.summary). Nada enviado")
                case .failure(let b): return .stopped("puerta WDA cerrada: " + b.reasons.map { "\($0)" }.joined(separator: ", "))
                }
            }
        }
        let step = CrossAppTapStep(bound: SpringBoard.bundleID, driver: driver, tapper: tapper, policy: policy, settle: settle,
                                   clock: clock, monotonic: monotonic)
        // Nothing happened since `home` was read (no model, wait or input): the step may reuse it (guarded there).
        let r = await step.run(tap: selector, expect: .sourceChanged,
                               reusing: ReusableSnapshot(observation: home, obtainedAt: homeAt))
        if let p = r.plan, r.taps > 0 { log(.act, "WDA tap icono \"\(icon.label ?? "")\": " + p.summary) }
        switch r.outcome {
        case .launched(let b):
            if let want = intent.bundleID, want != b { return .failed("se abrió \(b), no \(want); se detiene sin tocar nada más") }
            log(.verify, "primer plano: \(b) (activeAppInfo)")
            return .launched(b)
        case .selectionFailed(let e): return .stopped("icono de \(intent.appName) no utilizable: \(e)")
        case .blocked(let b): return .stopped("puerta WDA cerrada, nada enviado: " + b.map { "\($0)" }.joined(separator: ", "))
        case .observationFailed(let m): return .failed("observación fallida: \(m)")
        case .tapNotSent(let m): return .failed("toque no enviado (\(m)); no se reintenta")
        case .tapRejected(let m): return .failed("WDA rechazó el toque (\(m)); no se reintenta")
        case .tapUncertain(let m): return .failed("resultado del toque incierto (\(m)); no se repite")
        case .notVerified(let m): return .failed("toque enviado sin confirmar: \(m); no se repite")
        case .foregroundChanged(let b): return .failed("la app en primer plano cambió a \(b); se detiene")
        case .verified, .alreadyConsumed: return .failed("internal: unexpected step outcome")
        }
    }

    func confirm(_ bundle: String, _ intent: LaunchIntent) async -> Result {
        do {
            let now = try await CrossAppKit.settle(driver, settle) { $0 == bundle }
            return now == bundle ? .launched(bundle) : .failed("tras activar, en primer plano está \(now), no \(bundle)")
        } catch { return .failed("app en primer plano desconocida tras activar: \(error.localizedDescription)") }
    }
}

enum CrossAppKit {
    static func settle(_ s: WDAForegroundSource, _ p: SettlePolicy, until done: (String) -> Bool) async throws -> String {
        try await UnifiedAgentCore.settle(s, p, until: done)
    }
}
