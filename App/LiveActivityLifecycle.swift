import Foundation

// Lifecycle of a run's Live Activity, behind an injectable boundary (ActivityKit in the app, a fake in
// tests/live_activity_main.swift). Ported from upstream ios/IPhoneAgent/App/LiveActivityController.swift:
// started only by an explicit task start, updated through a token bucket (burst 2, then 1 per second, the
// newest state wins), ended with the outcome shown for 15 minutes. Foundation only.

enum LiveActivityDismissal: Equatable {
    case immediate
    case after(TimeInterval)
}

/// What the controller needs from ActivityKit.
@MainActor protocol LiveActivityBoundary: AnyObject {
    var activitiesEnabled: Bool { get }
    func request(runID: String, state: AgentActivityContent) throws
    func update(_ state: AgentActivityContent)
    func end(_ state: AgentActivityContent, dismissal: LiveActivityDismissal) async
    /// Ends activities left by an earlier process (killed mid-run), so none outlives its run.
    func endOrphans() async
}

/// Progress of a run, from the task agent's event kinds only (their texts may be private and never get here).
enum RunSignal: Equatable {
    case observing, thinking, acted, verified, blocked, retrying
}

/// Why a run stopped, when it was asked to.
enum RunStopCause: Equatable {
    case user, backgroundExpired
    /// The experimental background silence stopped (interruption, route, media reset or its time cap).
    case audioLost
}

/// How a run ended, for the final Live Activity state.
enum RunEnd: Equatable {
    case done, dryRun, stopped, backgroundExpired, didNotFinish, error

    /// From the task agent's outcome (TaskAgent.run's `finish` texts) and any requested stop. A completed task
    /// wins over a stop that raced it; otherwise a requested stop wins over the error the cancellation caused.
    static func classify(outcome: String?, stop: RunStopCause?) -> RunEnd {
        let o = outcome ?? ""
        if o.hasPrefix("done:") { return .done }
        if o.hasPrefix("dry run:") { return .dryRun }
        switch stop {
        case .user: return .stopped
        case .backgroundExpired: return .backgroundExpired
        case .audioLost: return .didNotFinish
        case nil: break
        }
        if o == "stopped by the user" { return .stopped }
        if o.hasPrefix("model stopped:") || o.hasPrefix("step limit") || o.hasPrefix("click gate closed")
            || o.hasPrefix("aim not confirmed") { return .didNotFinish }
        return .error
    }
}

/// What the character says (upstream IslandStatus strings; no targets, since element labels may be private).
struct IslandStatus: Equatable {
    var short: String
    var full: String
    var waits: Bool
    var minimal: String

    static let looking = Self(short: "Looking…", full: "Looking at the screen…", waits: true, minimal: "Look")
    static let thinking = Self(short: "Thinking…", full: "Thinking about my next move…", waits: true, minimal: "Think")
    static let retrying = Self(short: "Retrying…", full: "Asking the model again…", waits: true, minimal: "Retry")
    static let tapping = Self(short: "Tapping…", full: "Tapping…", waits: false, minimal: "Tap")

    static func ended(_ end: RunEnd) -> (Self, Mood) {
        switch end {
        case .done: return (Self(short: "Done!", full: "Done!", waits: false, minimal: "Done"), .success)
        case .dryRun: return (Self(short: "Dry run done", full: "Dry run done, nothing sent", waits: false, minimal: "Done"), .success)
        case .stopped: return (Self(short: "Stopped", full: "Stopped", waits: false, minimal: "Stop"), .idle)
        case .backgroundExpired:
            return (Self(short: "Stopped", full: "Stopped: out of background time", waits: false, minimal: "Stop"), .failure)
        case .didNotFinish: return (Self(short: "Didn't finish", full: "Didn't finish", waits: false, minimal: "Error"), .failure)
        case .error: return (Self(short: "Didn't finish", full: "Didn't finish: an error stopped it", waits: false, minimal: "Error"), .failure)
        }
    }
}

@MainActor final class RunActivityController {
    typealias State = AgentActivityContent
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private let boundary: LiveActivityBoundary
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private(set) var isActive = false
    private(set) var last: State?    // the newest state (sent or waiting for a token)
    private var sent: State?
    private var tokens = 2.0, refilled = 0.0
    private var flushPending = false
    private var generation = 0       // invalidates a scheduled flush after end/start

    static let perSecond = 1.0, burst = 2.0
    static let outcomeDismissal: TimeInterval = 15 * 60

    init(boundary: LiveActivityBoundary,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule = { delay, body in
             Task { @MainActor in
                 try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                 body()
             }
         }) {
        self.boundary = boundary
        self.now = now
        self.schedule = schedule
    }

    /// Only called from an explicit task start. Returns whether an activity is showing (off in Settings → none).
    /// Runs are serialized by the app, so one that is still showing is not replaced.
    @discardableResult
    func start(runID: String, limit: Int) -> Bool {
        guard !isActive, boundary.activitiesEnabled else { return false }
        var state = State(mood: .thinking, step: 0, limit: limit, line: IslandStatus.looking.full)
        apply(.looking, to: &state)
        do { try boundary.request(runID: runID, state: state) } catch { return false }
        isActive = true
        last = state
        sent = state
        tokens = 1
        refilled = now()
        generation += 1
        return true
    }

    func handle(_ signal: RunSignal) {
        guard var state = last, isActive, !state.finished else { return }
        switch signal {
        case .observing, .verified, .blocked:
            state.mood = .thinking
            apply(.looking, to: &state)
        case .thinking:
            state.mood = .thinking
            apply(.thinking, to: &state)
        case .retrying:
            state.mood = .thinking
            apply(.retrying, to: &state)
        case .acted:
            state.mood = .acting
            state.step = min(state.step + 1, state.limit)
            apply(.tapping, to: &state)
        }
        state.line = state.labelFull
        push(state)
    }

    /// Shows the outcome for 15 minutes, then the system removes it; nil ends it at once.
    /// Awaited before the app gives up its background time, so the end reaches the system.
    func finish(_ end: RunEnd?) async {
        generation += 1
        flushPending = false
        guard isActive, var state = last else { return }
        isActive = false
        last = nil
        sent = nil
        if let end {
            let (status, mood) = IslandStatus.ended(end)
            state.mood = mood
            apply(status, to: &state)
            state.line = end == .done || end == .dryRun ? "Finished. Open the app for details." : "Ended. Open the app for details."
        }
        state.finished = true
        state.waitingSince = nil
        await boundary.end(state, dismissal: end == nil ? .immediate : .after(Self.outcomeDismissal))
    }

    private func apply(_ status: IslandStatus, to state: inout State) {
        if status.waits {
            if state.label != status.short || state.waitingSince == nil { state.waitingSince = Date() }
        } else { state.waitingSince = nil }
        state.label = status.short
        state.labelFull = status.full
        state.minimalLabel = status.minimal
    }

    // MARK: rate limit

    /// Sends now if a token is left, else once one refills (the newest state wins).
    private func push(_ state: State) {
        guard state != last || state != sent else { return }
        last = state
        guard !flushPending else { return }  // a send is already scheduled; it picks up `last`
        refill()
        if tokens >= 1 { return send() }
        flushPending = true
        let gen = generation
        schedule((1 - tokens) * Self.perSecond) { [weak self] in
            guard let self, self.generation == gen, self.flushPending else { return }
            self.flushPending = false
            self.refill()
            self.send()
        }
    }

    private func refill() {
        let t = now()
        tokens = min(Self.burst, tokens + (t - refilled) / Self.perSecond)
        refilled = t
    }

    private func send() {
        guard isActive, let state = last, state != sent else { return }
        tokens -= 1
        sent = state
        boundary.update(state)
    }
}
