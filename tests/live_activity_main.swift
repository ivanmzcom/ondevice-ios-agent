// Host test for App/LiveActivityLifecycle.swift through a fake boundary (no ActivityKit, no device).
// xcrun swiftc -parse-as-library ../LiveActivity/Shared/AgentActivityContent.swift ../App/LiveActivityLifecycle.swift \
//   live_activity_main.swift -o <scratch>/live-activity-tests && <scratch>/live-activity-tests
import Foundation

@MainActor final class FakeBoundary: LiveActivityBoundary {
    var activitiesEnabled = true
    var failRequest = false
    var calls: [String] = []
    var states: [AgentActivityContent] = []
    var lastDismissal: LiveActivityDismissal?
    func request(runID: String, state: AgentActivityContent) throws {
        if failRequest { struct E: Error {}; throw E() }
        calls.append("request"); states.append(state)
    }
    func update(_ state: AgentActivityContent) { calls.append("update"); states.append(state) }
    func end(_ state: AgentActivityContent, dismissal: LiveActivityDismissal) async {
        calls.append("end"); states.append(state); lastDismissal = dismissal
    }
    func endOrphans() async { calls.append("orphans") }
}

@main struct LiveActivityTests {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "ok   \(what)" : "FAIL \(what)")
        if !ok { failures += 1 }
    }

    @MainActor static func make(_ b: FakeBoundary, clock: @escaping () -> TimeInterval = { 0 })
        -> (RunActivityController, () -> Void) {
        var pending: [@MainActor () -> Void] = []
        let c = RunActivityController(boundary: b, now: clock, schedule: { _, body in pending.append(body) })
        return (c, { let p = pending; pending = []; p.forEach { $0() } })
    }

    @MainActor static func main() async {
        // Nothing before an explicit start.
        do {
            let b = FakeBoundary()
            let (c, _) = make(b)
            c.handle(.thinking)
            await c.finish(.done)
            check(b.calls.isEmpty, "no activity, update or end without a start")
        }
        // Start → updates → done.
        do {
            let b = FakeBoundary()
            var t = 0.0
            let (c, _) = make(b, clock: { t })
            check(c.start(runID: "r1", limit: 12), "start shows an activity")
            check(b.states.last?.label == "Looking…" && b.states.last?.step == 0 && b.states.last?.limit == 12, "initial state Looking… 0/12")
            check(!c.start(runID: "r2", limit: 12) && b.calls == ["request"], "second start while active is refused")
            t = 1; c.handle(.thinking)
            t = 2; c.handle(.acted)
            check(b.states.last?.step == 1 && b.states.last?.mood == .acting && b.states.last?.label == "Tapping…", "act counts a step")
            t = 3; await c.finish(.done)
            let s = b.states.last!
            check(s.finished && s.mood == .success && s.label == "Done!" && s.waitingSince == nil, "done ends finished/success")
            check(b.lastDismissal == .after(15 * 60), "outcome stays 15 min")
            check(!c.isActive, "inactive after end")
            c.handle(.acted)
            check(b.calls.filter { $0 == "update" }.count == 2, "no update after end")
            await c.finish(.error)
            check(b.calls.filter { $0 == "end" }.count == 1, "end once only")
        }
        // Rate limit: burst then coalesce to the newest state; a pending flush after end sends nothing.
        do {
            let b = FakeBoundary()
            let (c, flush) = make(b)
            c.start(runID: "r", limit: 5)
            c.handle(.thinking)                // token 1 → sent
            c.handle(.acted)                   // no token → scheduled
            c.handle(.verified); c.handle(.acted)  // coalesced
            check(b.calls == ["request", "update"], "over-limit updates wait")
            flush()
            check(b.calls.last == "update" && b.states.last?.step == 2, "flush sends the newest state only")
            c.handle(.thinking)
            await c.finish(.stopped)
            flush()
            check(b.calls.last == "end", "stale flush after end sends nothing")
            check(b.states.last?.label == "Stopped" && b.states.last?.mood == .idle, "user stop shows Stopped")
        }
        // Disabled in Settings / request failure: no activity, run unaffected.
        do {
            let b = FakeBoundary(); b.activitiesEnabled = false
            let (c, _) = make(b)
            check(!c.start(runID: "r", limit: 3) && b.calls.isEmpty, "disabled in Settings → none")
            let b2 = FakeBoundary(); b2.failRequest = true
            let (c2, _) = make(b2)
            check(!c2.start(runID: "r", limit: 3) && !c2.isActive, "request failure → none")
            c2.handle(.acted); await c2.finish(.done)
            check(b2.calls.isEmpty, "nothing sent after a failed request")
        }
        // Step counter never passes the limit.
        do {
            let b = FakeBoundary(); var t = 0.0
            let (c, _) = make(b, clock: { t })
            c.start(runID: "r", limit: 1)
            for _ in 0..<3 { t += 5; c.handle(.acted) }
            check(b.states.last?.step == 1, "step capped at limit")
        }
        // Terminal classification.
        let cases: [(String?, RunStopCause?, RunEnd)] = [
            ("done: opened Wi-Fi", nil, .done), ("dry run: would tap #2", nil, .dryRun),
            ("stopped by the user", nil, .stopped), ("model request failed (m): cancelled", .user, .stopped),
            ("model request failed (m): cancelled", .backgroundExpired, .backgroundExpired),
            ("done: x", .user, .done), ("model stopped: cannot", nil, .didNotFinish), ("step limit (12) reached", nil, .didNotFinish),
            ("click gate closed, nothing sent: x", nil, .didNotFinish), ("aim not confirmed, no click: x", nil, .didNotFinish),
            ("observation failed: unified-ffi -6: Session does not exist", nil, .error), (nil, nil, .error),
        ]
        for (o, s, want) in cases {
            check(RunEnd.classify(outcome: o, stop: s) == want, "classify \(o ?? "nil") / \(String(describing: s)) → \(want)")
        }
        // Privacy: every payload is fixed text; task/outcome/model words never reach the boundary.
        do {
            let b = FakeBoundary(); var t = 0.0
            let (c, _) = make(b, clock: { t })
            let secret = "DUMMY"
            c.start(runID: UUID().uuidString, limit: 12)
            for sig in [RunSignal.observing, .thinking, .acted, .verified, .blocked, .retrying] { t += 2; c.handle(sig) }
            await c.finish(RunEnd.classify(outcome: "done: \(secret)", stop: nil))
            let json = String(decoding: try! JSONEncoder().encode(b.states), as: UTF8.self)
            check(!json.contains("SECRET") && !json.contains("Bearer"), "no task, outcome or token text in any activity payload")
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
