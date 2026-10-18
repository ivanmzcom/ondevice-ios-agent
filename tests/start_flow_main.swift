// Host test for App/StartFlow.swift (the main-screen start coordinator) with a fake StartSteps: WDA-only order
// (tunnel → session → observe → task), skipped steps, missing prerequisites, cancellation, duplicate starts, a lost
// WDA session; and App/LegacyPrefs.swift (stale settings of earlier builds are purged and never block a start).
// From the unified dir:
// xcrun swiftc -swift-version 5 -parse-as-library LiveActivity/Shared/AgentActivityContent.swift \
//   App/LiveActivityLifecycle.swift App/StartFlow.swift App/LegacyPrefs.swift tests/start_flow_main.swift \
//   -o <scratch>/start-flow-tests && <scratch>/start-flow-tests
import Combine
import Foundation

@MainActor final class FakeSteps: StartSteps {
    var calls: [String] = []
    var tunnelInstalled = true, hasPairing = true, runnerConfigured = true, targetConfigured = true
    var modelProblem: String?
    var tunnelConnected = false, sessionOpen = false
    var lostObservations = 0          // how many observes answer "session lost"
    var gate: CheckedContinuation<Void, Never>?
    var holdSessionOpen = false
    var onEnd: (@MainActor (String?) -> Void)?
    var taskStarts = 0
    var activity: [String] = []       // Live Activity hooks, kept apart from the step order
    func runWillPrepare() { activity.append("begin") }
    func runDidNotStart(_ end: RunEnd) { activity.append("notStarted:\(end)") }

    func startTunnel() async throws { calls.append("tunnel"); tunnelConnected = true }
    func openSession() async throws {
        calls.append("open")
        if holdSessionOpen { await withCheckedContinuation { gate = $0 } }
        sessionOpen = true
    }
    func dropSession() { calls.append("drop"); sessionOpen = false }
    func observe() async throws {
        calls.append("observe")
        if lostObservations > 0 { lostObservations -= 1; throw StartFlowError.sessionLost }
    }
    func startTask(task: String, mode: RunMode, onEnd: @escaping @MainActor (String?) -> Void) -> Bool {
        calls.append("task:\(mode == .live ? "live" : "dry")"); taskStarts += 1; self.onEnd = onEnd; return true
    }
    func stopTask() { calls.append("stopTask") }
}

@main struct StartFlowTests {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "ok   \(what)" : "FAIL \(what)")
        if !ok { failures += 1 }
    }

    @MainActor static func main() async {
        // Missing prerequisites: listed, nothing touched.
        do {
            let s = FakeSteps(); s.tunnelInstalled = false; s.hasPairing = false
            s.modelProblem = "Inicia sesión en ChatGPT"
            let f = StartCoordinator(steps: s)
            f.confirm(task: "t", target: "app", mode: .live)
            f.start(task: "t", target: "app", mode: .live)
            if case .blocked(let l) = f.phase { check(l.count == 3, "three setup blockers listed (\(l))") } else { check(false, "blocked") }
            check(s.calls.isEmpty && s.activity.isEmpty, "no side effects and no Live Activity when blocked")
            f.start(task: "  ", target: "app", mode: .dryRun)
            if case .blocked(let l) = f.phase { check(l.contains("Escribe la tarea"), "empty task blocked") } else { check(false, "empty task") }
        }
        // Live needs one confirmation per scope.
        do {
            let s = FakeSteps(), f = StartCoordinator(steps: s)
            check(f.needsConfirmation(task: "abrir wifi", target: "a", mode: .live), "live asks first")
            check(!f.needsConfirmation(task: "abrir wifi", target: "a", mode: .dryRun), "dry run never asks")
            f.start(task: "abrir wifi", target: "a", mode: .live)
            check(f.phase == .blocked(["Confirma el modo real"]) && s.calls.isEmpty, "unconfirmed live does nothing")
            f.confirm(task: "abrir wifi", target: "a", mode: .live)
            check(!f.needsConfirmation(task: "abrir wifi ", target: "a", mode: .live), "same scope does not ask again")
            check(f.needsConfirmation(task: "otra", target: "a", mode: .live), "new task asks again")
            check(f.needsConfirmation(task: "abrir wifi", target: "b", mode: .live), "new app asks again")
        }
        // Full live order from cold.
        do {
            let s = FakeSteps(), f = StartCoordinator(steps: s)
            f.confirm(task: "t", target: "a", mode: .live)
            f.start(task: "t", target: "a", mode: .live)
            await f.settle()
            check(s.calls == ["tunnel", "open", "observe", "task:live"], "live order \(s.calls)")
            check(f.phase == .running && f.done == [.tunnel, .session, .observe, .task], "running, all steps done (\(f.done))")
            check(s.activity == ["begin"], "activity begins at Iniciar, not ended while the task runs")
            f.start(task: "t", target: "a", mode: .live)
            check(s.taskStarts == 1, "start while running is ignored")
            f.stop(); f.stop()
            check(s.calls.filter { $0 == "stopTask" }.count == 1, "stop forwarded once, second tap ignored")
            s.onEnd?("stopped by the user")
            check(f.phase == .stopped, "stopped after the run ends")
        }
        // Repeat use: what is up is reused.
        do {
            let s = FakeSteps(); s.tunnelConnected = true; s.sessionOpen = true
            let f = StartCoordinator(steps: s)
            f.start(task: "t", target: "a", mode: .dryRun)
            await f.settle()
            check(s.calls == ["observe", "task:dry"], "warm dry run: only observe + task (\(s.calls))")
            s.onEnd?("dry run: would tap #1")
            check(f.phase == .finished("dry run: would tap #1"), "finished with outcome")
        }
        // Lost session: dropped, reopened once, observed again; no task replay.
        do {
            let s = FakeSteps(); s.tunnelConnected = true; s.sessionOpen = true; s.lostObservations = 1
            let f = StartCoordinator(steps: s)
            f.start(task: "t", target: "a", mode: .dryRun)
            await f.settle()
            check(s.calls == ["observe", "drop", "open", "observe", "task:dry"], "recover once \(s.calls)")
            let s2 = FakeSteps(); s2.tunnelConnected = true; s2.sessionOpen = true; s2.lostObservations = 2
            let f2 = StartCoordinator(steps: s2)
            f2.start(task: "t", target: "a", mode: .dryRun)
            await f2.settle()
            check(f2.phase == .failed("Sesión WDA perdida de nuevo") && s2.taskStarts == 0 && !s2.sessionOpen, "second loss fails, no task, session cleared")
            check(s2.activity == ["begin", "notStarted:error"], "failure ends the activity")
        }
        // A run that ends with a dead session clears it for the next start.
        do {
            let s = FakeSteps(); s.tunnelConnected = true; s.sessionOpen = true
            let f = StartCoordinator(steps: s)
            f.start(task: "t", target: "a", mode: .dryRun)
            await f.settle()
            s.onEnd?("observation failed: unified-ffi -6: {\"detail\":\"Session does not exist\"}")
            check(!s.sessionOpen && s.calls.last == "drop", "dead session dropped after the run")
        }
        // Stop during the session open: waits for the call, then nothing more.
        do {
            let s = FakeSteps(); s.tunnelConnected = true; s.holdSessionOpen = true
            let f = StartCoordinator(steps: s)
            f.start(task: "t", target: "a", mode: .dryRun)
            for _ in 0..<20 where s.gate == nil { await Task.yield() }
            f.stop()
            check(f.phase == .stopping && f.busy, "stopping while the call is in flight")
            f.start(task: "t", target: "a", mode: .dryRun)
            check(s.calls.filter { $0 == "open" }.count == 1, "no second open while stopping")
            s.gate?.resume()
            await f.settle()
            check(f.phase == .stopped && s.calls == ["open"], "no observe or task after stop (\(s.calls))")
            check(s.activity == ["begin", "notStarted:stopped"], "stop during preparation ends the activity once")
        }
        // WDA-only regression (1): a live run's blockers never mention the removed hardware path, and with every
        // prerequisite in place there is none at all (no Bluetooth or board prerequisite exists).
        do {
            let s = FakeSteps(); s.tunnelInstalled = false; s.hasPairing = false; s.runnerConfigured = false
            s.targetConfigured = false; s.modelProblem = "Elige un modelo del plan de ChatGPT"
            let f = StartCoordinator(steps: s)
            let all = f.setupBlockers(task: "", mode: .live) + f.setupBlockers(task: "", mode: .dryRun)
            let banned = ["esp32", "bluetooth", "placa", "board", "calibra", "puntero", "hid"]
            check(!all.contains { b in banned.contains { b.lowercased().contains($0) } }, "no ESP32/Bluetooth/placa wording in blockers (\(all))")
            check(f.setupBlockers(task: "t", mode: .live).count == 5, "live blockers are only task-independent setup (\(f.setupBlockers(task: "t", mode: .live)))")
            let ok = FakeSteps()
            check(StartCoordinator(steps: ok).setupBlockers(task: "t", mode: .live).isEmpty, "live run with setup done has no further prerequisite")
            let props = Mirror(reflecting: ok).children.compactMap(\.label).map { $0.lowercased() }
            check(!props.contains { p in ["board", "bluetooth", "calibration", "usesboard"].contains { p.contains($0) } }, "StartSteps has no board/Bluetooth/calibration member (\(props))")
            check(StartCoordinator.Step.allCases == [.tunnel, .session, .observe, .task], "steps are tunnel, session, observe, task only")
        }
        // WDA-only regression (2): a cold dry run goes tunnel → session → observe → task.
        do {
            let s = FakeSteps(), f = StartCoordinator(steps: s)
            var seen: [StartCoordinator.Step] = []
            let watch = f.$phase.sink { if case .preparing(let st) = $0, seen.last != st { seen.append(st) } }
            f.start(task: "t", target: "a", mode: .dryRun)
            await f.settle()
            watch.cancel()
            check(s.calls == ["tunnel", "open", "observe", "task:dry"], "dry order \(s.calls)")
            check(f.done == [.tunnel, .session, .observe, .task], "dry done \(f.done)")
            check(seen == [.tunnel, .session, .observe, .task], "dry phases \(seen)")
            check(f.phase == .running, "dry run running")
        }
        // WDA-only regression (3): a confirmed live start reaches running with no board step at all.
        do {
            let s = FakeSteps(), f = StartCoordinator(steps: s)
            f.confirm(task: "abre General", target: "a", mode: .live)
            f.start(task: "abre General", target: "a", mode: .live)
            await f.settle()
            check(f.phase == .running && s.taskStarts == 1, "confirmed live start runs (\(f.phase))")
            check(s.calls == ["tunnel", "open", "observe", "task:live"], "live calls \(s.calls)")
            check(!s.calls.contains { $0.lowercased().contains("board") } && f.done == [.tunnel, .session, .observe, .task], "no board or calibration step (\(f.done))")
        }
        // WDA-only regression (4): stale prefs of earlier builds are purged and do not block a start.
        do {
            let suite = "start-flow-tests.legacy.\(UUID().uuidString)"
            let d = UserDefaults(suiteName: suite)!
            d.set(Data([0]), forKey: "pointerCalibration")
            d.set("8C1F0000-0000-0000-0000-000000000000", forKey: "pairedBoard")
            d.set("esp32-01", forKey: "boardID")
            d.set(true, forKey: "useWDATap"); d.set(true, forKey: "useAbsoluteHID")
            d.set(true, forKey: "startAtHome"); d.set("gpt-x", forKey: "modelID")
            LegacyPrefs.purge(d)
            check(LegacyPrefs.keys.allSatisfy { d.object(forKey: $0) == nil }, "legacy keys removed")
            check(["pointerCalibration", "pairedBoard"].allSatisfy { LegacyPrefs.keys.contains($0) }, "the stored legacy keys are covered")
            check(d.bool(forKey: "startAtHome") && d.string(forKey: "modelID") == "gpt-x", "current settings kept")
            LegacyPrefs.purge(d)
            check(d.bool(forKey: "startAtHome"), "purging twice is harmless")
            let s = FakeSteps(), f = StartCoordinator(steps: s)
            f.confirm(task: "t", target: "a", mode: .live)
            f.start(task: "t", target: "a", mode: .live)
            await f.settle()
            check(f.phase == .running, "start not blocked after the purge (\(f.phase))")
            d.removePersistentDomain(forName: suite)
        }
        // Session-loss matcher.
        check(WDASessionLoss.matches(code: -6, json: "{\"detail\":\"WDA error (status=404) Session does not exist\"}"), "matches -6 404")
        check(!WDASessionLoss.matches(code: -9, json: "Session does not exist"), "other codes do not match")
        check(!WDASessionLoss.matches(code: -6, json: "{\"detail\":\"bad gateway\"}"), "other -6 errors do not match")
        // Session recovery (SESSION_RECOVERY_REPORT.md).
        let refused = "{\"code\":-6,\"stage\":\"wda_activate_app\",\"detail\":\"idevice socket io failed (kind=ConnectionRefused)\",\"session_lost\":{\"reason\":\"connection_refused\",\"stage\":\"wda_activate_app\",\"probe\":{\"wda_port\":\"refused\",\"lockdown_port\":\"accepted\",\"verdict\":\"runner_not_listening\"}}}"
        check(WDASessionLoss.reason(json: refused) == "connection_refused", "refused activation is a loss")
        check(WDASessionLoss.matches(code: -6, json: refused), "refused activation matches")
        let refusedRead = "{\"code\":-7,\"stage\":\"wda_compact_connect\",\"session_lost\":{\"reason\":\"connection_refused\"}}"
        check(WDASessionLoss.matches(code: -7, json: refusedRead), "refused read (-7) matches")
        let label = WDASessionLoss.label(code: -6, json: refused)
        check(label == "ffi -6 · wda_activate_app · lost: connection_refused · probe: runner_not_listening", "full stage in the UI label: \(label)")
        check(WDASessionLoss.label(code: -7, json: "{\"stage\":\"Bad Stage!\",\"detail\":\"private.app\"}") == "ffi -7", "non-token stage and detail never shown")
        check(WDASessionLoss.reason(json: "{\"stage\":\"session_unusable\"}") == "session_unusable", "refused on a lost session is a loss")
        let invalid = "{\"code\":-7,\"stage\":\"wda_compact_invalid_session\",\"session_lost\":{\"reason\":\"invalid_session\"}}"
        check(WDASessionLoss.matches(code: -7, json: invalid), "404 invalid session id is a loss")
        let route = "{\"code\":-7,\"stage\":\"wda_compact_unavailable\",\"detail\":\"COMPACT_UNAVAILABLE (HTTP 404 unknown command)\"}"
        check(!WDASessionLoss.matches(code: -7, json: route) && WDASessionLoss.reason(json: route) == nil, "404 missing route is not a session loss")
        check(WDASessionLoss.matches(text: "unified-ffi -6: \(refused)"), "agent outcome with a loss record matches")
        // A loss during the run: the session is dropped, nothing is reopened and the task is not restarted.
        do {
            let s = FakeSteps(), f = StartCoordinator(steps: s)
            f.start(task: "t", target: "a", mode: .dryRun)
            await f.settle()
            let before = s.calls
            s.onEnd?("unified-ffi -6: \(refused)")
            check(s.calls == before + ["drop"] && s.taskStarts == 1, "loss mid-run: dropped once, no reopen, no replay (\(s.calls))")
            check(f.phase == .finished("unified-ffi -6: \(refused)") && !f.busy, "run ended (\(f.phase))")
        }
        // Native pointer gate: freed once, only after the running call left; a lost session refuses unsent.
        do {
            final class Flag: @unchecked Sendable { var v = false }
            let g = NativeCallGate(7), done = Flag()
            let p = try! g.enter()
            let closer = Task { () -> Int? in let q = await g.close(); done.v = true; return q }
            try? await Task.sleep(nanoseconds: 100_000_000)
            check(g.isClosed && !done.v, "close takes the pointer at once and waits for the running call")
            var refusedNew = false
            do { _ = try g.enter() } catch NativeCallGate<Int>.Refusal.closed { refusedNew = true } catch {}
            check(refusedNew, "no new call after close")
            g.leave(lostReason: nil)
            let freed = await closer.value
            check(freed == 7 && p == 7 && done.v, "pointer handed back after the call left")
            let again = await g.close()
            check(again == nil, "second close frees nothing (no double free)")
        }
        do {
            let g = NativeCallGate("h")
            _ = try! g.enter()
            g.leave(lostReason: "connection_refused")
            var why: String?
            do { _ = try g.enter() } catch NativeCallGate<String>.Refusal.lost(let r) { why = r } catch {}
            check(why == "connection_refused" && g.lostReason == "connection_refused", "a lost session refuses before the native call")
            let freed = await g.close()
            check(freed == "h", "a lost session is still freed once")
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
