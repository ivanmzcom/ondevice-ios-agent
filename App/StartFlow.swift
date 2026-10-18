import Combine
import Foundation

// The single owner of the main path: one explicit "Iniciar" brings up what is missing, in order
// (tunnel → persistent WDA session → observation → task), and "Detener" stops it. It never installs, imports or
// signs in by itself: those need the operator (OS consent, file import, model sign-in) and come back as blockers.
// It never taps or types; only the task agent does, through WDA, after every check passed. Foundation + Combine
// only, so tests/start_flow_main.swift runs it on the Mac.

enum RunMode: Equatable { case dryRun, live }

/// A WDA session the app holds is gone (WDA answered 404 "Session does not exist", or the runner was replaced).
enum StartFlowError: Error, Equatable {
    case sessionLost
    case step(String)
}

enum WDASessionLoss {
    static let code: Int32 = -6  // ODR_ERR_WDA_SESSION

    static func matches(code: Int32, json: String) -> Bool { reason(json: json) != nil || (code == Self.code && matches(text: json)) }

    /// WDA's wording for an unknown session id, or a native loss record (also inside a TaskAgent outcome text).
    static func matches(text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("session does not exist") || t.contains("invalid session id")
            || t.contains("\"session_lost\"") || t.contains("session_unusable")
    }

    /// The `session_lost.reason` token of a native error (unified-ffi session.rs `loss_reason`: `connection_refused`
    /// on any read/activate/mutation, `invalid_session` for WDA's 404), `session_unusable` for a call refused on an
    /// already lost session; nil otherwise (a missing route, a deadline, an identity refusal).
    static func reason(json: String) -> String? {
        let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        if let r = (o?["session_lost"] as? [String: Any])?["reason"] as? String, token(r) { return r }
        return o?["stage"] as? String == "session_unusable" ? "session_unusable" : nil
    }

    /// Main-screen text of a native failure: code, Rust's fixed stage and, for a lost session, its reason and the
    /// connect-only probe verdict. Tokens only; the detail (it may echo WDA answers) is never shown.
    static func label(code: Int32, json: String) -> String {
        let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        var parts = ["ffi \(code)"]
        if let s = o?["stage"] as? String, token(s) { parts.append(s) }
        if let l = o?["session_lost"] as? [String: Any] {
            if let r = l["reason"] as? String, token(r) { parts.append("lost: \(r)") }
            if let v = (l["probe"] as? [String: Any])?["verdict"] as? String, token(v) { parts.append("probe: \(v)") }
        }
        return parts.joined(separator: " · ")
    }

    private static func token(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }
}

/// Who may use a native session pointer (WDASession.swift). `enter` hands it out while the session is open and not
/// lost; `close` takes it away at once and returns it only after every call that entered has left, so it is freed
/// exactly once and never under a running call. A call that leaves with a loss reason marks the session lost:
/// later calls are refused before anything reaches the native library.
final class NativeCallGate<P>: @unchecked Sendable {
    enum Refusal: Error, Equatable { case closed, lost(String) }
    private let lock = NSLock()
    private var p: P?
    private var lost: String?
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ p: P) { self.p = p }

    var lostReason: String? { lock.withLock { lost } }
    var isClosed: Bool { lock.withLock { p == nil } }

    func enter() throws -> P {
        lock.lock(); defer { lock.unlock() }
        guard let p else { throw Refusal.closed }
        if let lost { throw Refusal.lost(lost) }
        running += 1
        return p
    }

    func leave(lostReason reason: String?) {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            if lost == nil, let reason { lost = reason }
            running -= 1
            guard running == 0 else { return [] }
            defer { waiters = [] }
            return waiters
        }
        ready.forEach { $0.resume() }
    }

    /// The pointer to free, once every running call left; nil when already closed (a second close frees nothing).
    func close() async -> P? {
        let taken: P? = lock.withLock { defer { p = nil }; return p }
        guard let taken else { return nil }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if running == 0 { lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
        }
        return taken
    }
}

/// What the coordinator drives. The app's adapter is MainScreen.swift `AppStartSteps`; tests use a fake.
@MainActor protocol StartSteps: AnyObject {
    // checked before anything is touched
    var tunnelInstalled: Bool { get }
    var hasPairing: Bool { get }
    var runnerConfigured: Bool { get }
    var targetConfigured: Bool { get }
    var modelProblem: String? { get }
    // brought up in order when missing
    var tunnelConnected: Bool { get }
    func startTunnel() async throws
    var sessionOpen: Bool { get }
    func openSession() async throws
    func dropSession()
    /// A fresh observation of the target app on the open session; throws `.sessionLost` for a dead session.
    func observe() async throws
    /// Starts the task agent; `onEnd` gets its outcome text. False if it could not start.
    func startTask(task: String, mode: RunMode, onEnd: @escaping @MainActor (String?) -> Void) -> Bool
    func stopTask()
    /// Iniciar was accepted: the Live Activity starts now, while this app is still in front (the observe step
    /// brings the target app forward, and ActivityKit only accepts requests from the foreground).
    func runWillPrepare()
    /// The preparation ended without starting the task; the activity shows why and ends.
    func runDidNotStart(_ end: RunEnd)
}

@MainActor final class StartCoordinator: ObservableObject {
    enum Step: String, CaseIterable { case tunnel, session, observe, task }

    enum Phase: Equatable {
        case idle
        case preparing(Step)
        case running
        case blocked([String])      // needs the operator; nothing was started for the task
        case failed(String)
        case stopping               // stop asked during preparation; waits for the call in flight
        case stopped
        case finished(String?)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var done: [Step] = []
    /// The live scope the operator confirmed; the same task + app + mode does not ask again.
    @Published private(set) var confirmedScope: String?

    private let steps: StartSteps
    private var job: Task<Void, Never>?
    private var cancelled = false

    init(steps: StartSteps) { self.steps = steps }

    var busy: Bool {
        switch phase {
        case .preparing, .running, .stopping: return true
        default: return false
        }
    }

    static func scope(task: String, target: String, mode: RunMode) -> String {
        "\(mode == .live ? "live" : "dry")|\(target)|\(task.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Live WDA taps need the operator's confirmation once per task + app.
    func needsConfirmation(task: String, target: String, mode: RunMode) -> Bool {
        mode == .live && confirmedScope != Self.scope(task: task, target: target, mode: mode)
    }

    func confirm(task: String, target: String, mode: RunMode) { confirmedScope = Self.scope(task: task, target: target, mode: mode) }

    /// Blockers that need the operator, checked before touching anything.
    func setupBlockers(task: String, mode: RunMode) -> [String] {
        var out: [String] = []
        if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("Escribe la tarea") }
        if !steps.tunnelInstalled { out.append("Añade la configuración VPN (permiso de iOS)") }
        if !steps.hasPairing { out.append("Importa el registro de emparejamiento") }
        if !steps.runnerConfigured { out.append("Falta el bundle id del runner WDA (Ajustes avanzados)") }
        if !steps.targetConfigured { out.append("Falta la app objetivo") }
        if let p = steps.modelProblem { out.append(p) }
        return out
    }

    /// The one explicit start. Ignored while a start or run is in progress (no duplicate commands).
    func start(task: String, target: String, mode: RunMode) {
        guard !busy else { return }
        if mode == .live && needsConfirmation(task: task, target: target, mode: mode) {
            phase = .blocked(["Confirma el modo real"])
            return
        }
        let blockers = setupBlockers(task: task, mode: mode)
        guard blockers.isEmpty else { phase = .blocked(blockers); return }
        cancelled = false
        done = []
        phase = .preparing(.tunnel)
        steps.runWillPrepare()
        job = Task { [weak self] in
            guard let self else { return }
            await self.prepareAndRun(task: task, mode: mode)
            if self.phase == .stopping { self.phase = .stopped }
            switch self.phase {
            case .stopped: self.steps.runDidNotStart(.stopped)
            case .blocked: self.steps.runDidNotStart(.didNotFinish)
            case .failed: self.steps.runDidNotStart(.error)
            default: break  // running or already finished: the run's own end closes the activity
            }
        }
    }

    /// Stops a start in progress (nothing further is started) or the running task.
    func stop() {
        switch phase {
        case .preparing:
            cancelled = true
            phase = .stopping
        case .running:
            guard !cancelled else { return }  // one stop per run
            cancelled = true
            steps.stopTask()  // the run's onEnd moves the phase on
        default: break
        }
    }

    /// Waits for the current preparation (tests).
    func settle() async { await job?.value }

    private func step(_ s: Step) -> Bool {
        guard !cancelled else { return false }
        guard phase != .stopping else { return false }
        phase = .preparing(s)
        return true
    }

    private func finishStep(_ s: Step) { done.append(s) }

    private func prepareAndRun(task: String, mode: RunMode) async {
        do {
            guard step(.tunnel) else { return }
            if !steps.tunnelConnected { try await steps.startTunnel() }
            guard !cancelled else { return }
            finishStep(.tunnel)

            guard step(.session) else { return }
            if !steps.sessionOpen { try await steps.openSession() }
            guard !cancelled else { return }
            finishStep(.session)

            guard step(.observe) else { return }
            do {
                try await steps.observe()
            } catch StartFlowError.sessionLost {
                // The held session is gone: forget it, open a new one once and look again. Only WDA reads here;
                // no tap or typing request is repeated.
                steps.dropSession()
                guard step(.session) else { return }
                try await steps.openSession()
                guard step(.observe) else { return }
                try await steps.observe()
            }
            guard !cancelled else { return }
            finishStep(.observe)

            guard step(.task) else { return }
            let started = steps.startTask(task: task, mode: mode) { [weak self] outcome in
                guard let self else { return }
                if outcome.map(WDASessionLoss.matches(text:)) == true { self.steps.dropSession() }
                self.phase = self.cancelled ? .stopped : .finished(outcome)
            }
            if started { finishStep(.task) }
            phase = started ? .running : .failed("La tarea no pudo empezar")
        } catch StartFlowError.sessionLost {
            steps.dropSession()
            if !cancelled { phase = .failed("Sesión WDA perdida de nuevo") }
        } catch StartFlowError.step(let why) {
            if !cancelled { phase = .failed(why) }
        } catch {
            if !cancelled { phase = .failed(error.localizedDescription) }
        }
    }
}
