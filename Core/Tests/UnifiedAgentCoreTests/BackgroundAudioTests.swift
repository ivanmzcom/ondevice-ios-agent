import XCTest
@testable import UnifiedAgentCore

// Synthetic lifecycle of the experimental background silence: a fake output, no AVAudioSession, no device.

@MainActor private final class FakeOutput: BackgroundAudioOutput {
    var calls: [String] = []
    var failStart = false
    var signal: ((BackgroundAudioSignal) -> Void)?
    var playing = false
    func start(onSignal: @escaping @MainActor (BackgroundAudioSignal) -> Void) throws {
        calls.append("start")
        if failStart { struct Refused: Error {}; throw Refused() }
        signal = onSignal; playing = true
    }
    func stop() { calls.append("stop"); playing = false }
}

@MainActor final class BackgroundAudioTests: XCTestCase {
    private var lines: [String] = []
    private var savedSink: ((String) -> Void)!
    private var savedEvery: UInt64 = 0
    private var scheduled: [(UInt64, @MainActor () -> Void)] = []

    override func setUp() {
        lines = []; scheduled = []
        savedSink = AgentDiag.sink; savedEvery = AgentDiag.waitEveryNanoseconds
        AgentDiag.waitEveryNanoseconds = 0
        AgentDiag.sink = { [weak self] l in MainActor.assumeIsolated { self?.lines.append(l) } }
    }
    override func tearDown() { AgentDiag.sink = savedSink; AgentDiag.waitEveryNanoseconds = savedEvery }

    private func keeper(_ o: FakeOutput) -> BackgroundAudioKeeper {
        var t: UInt64 = 0
        return BackgroundAudioKeeper(output: o, monotonic: { t += 1_000_000; return t }, schedule: { [weak self] d, b in self?.scheduled.append((d, b)) })
    }

    func testBeginEndIsIdempotentAndLogsOnePair() {
        let o = FakeOutput(), k = keeper(o)
        var lost: [String] = []
        XCTAssertTrue(k.begin { lost.append($0) })
        XCTAssertTrue(k.begin { lost.append($0) }, "second begin is a no-op")
        XCTAssertEqual(k.state, .active)
        k.end("run_end"); k.end("run_end"); k.end("user_stop")
        XCTAssertEqual(k.state, .off)
        XCTAssertEqual(o.calls, ["start", "stop"])
        XCTAssertTrue(lost.isEmpty)
        XCTAssertEqual(lines.filter { $0.contains("op=audio.start event ok=1") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("op=audio.stop event cause=run_end") }.count, 1)
        XCTAssertFalse(lines.contains { $0.contains("user_stop") })
    }

    func testStartFailureLeavesNothingPlayingAndDoesNotCallLost() {
        let o = FakeOutput(); o.failStart = true
        let k = keeper(o)
        var lost = 0
        XCTAssertFalse(k.begin { _ in lost += 1 })
        XCTAssertEqual(k.state, .off)
        XCTAssertEqual(o.calls, ["start", "stop"], "partial start cleaned up")
        XCTAssertEqual(lost, 0)
        XCTAssertTrue(lines.last!.contains("audio.start event ok=0 err=Refused"), lines.last!)
        k.end("start_failure")
        XCTAssertEqual(o.calls, ["start", "stop"])
    }

    func testInterruptionStopsOnceAsksTaskStopAndNeverResumes() {
        let o = FakeOutput(), k = keeper(o)
        var lost: [String] = []
        k.begin { lost.append($0) }
        o.signal?(.interruptionBegan(reason: 0))
        o.signal?(.interruptionBegan(reason: 0))
        o.signal?(.interruptionEnded)
        XCTAssertEqual(lost, ["interrupted"])
        XCTAssertEqual(k.state, .lost("interrupted"))
        XCTAssertEqual(o.calls, ["start", "stop"], "no restart after the interruption ended")
        XCTAssertTrue(lines.contains { $0.contains("audio.interruption event began=0 resumed=0 active=0") })
        k.end("run_end")
        XCTAssertEqual(k.state, .off)
        XCTAssertEqual(o.calls, ["start", "stop"])
    }

    func testRouteChangeStopsOnlyWhenPlaybackStopped() {
        let o = FakeOutput(), k = keeper(o)
        var lost: [String] = []
        k.begin { lost.append($0) }
        o.signal?(.routeChanged(reason: 1, stillPlaying: true))
        XCTAssertEqual(k.state, .active)
        o.signal?(.routeChanged(reason: 2, stillPlaying: false))
        XCTAssertEqual(lost, ["route_stopped_playback"])
        o.signal?(.mediaServicesReset)
        XCTAssertEqual(lost.count, 1)
    }

    func testSignalsFromAnEndedRunAndTheTimeCap() {
        let o = FakeOutput(), k = keeper(o)
        var lost: [String] = []
        k.begin { lost.append($0) }
        let old = o.signal
        k.end("run_end")
        old?(.mediaServicesReset)
        scheduled.forEach { $0.1() }
        XCTAssertTrue(lost.isEmpty, "a stale signal or cap does not touch a later state")
        XCTAssertEqual(k.state, .off)
        scheduled = []
        k.begin { lost.append($0) }
        XCTAssertEqual(scheduled.first?.0, k.maxNanoseconds)
        scheduled.forEach { $0.1() }
        XCTAssertEqual(lost, ["time_cap"])
        XCTAssertEqual(o.calls, ["start", "stop", "start", "stop"])
    }

    func testDiagLinesCarryNoFreeText() {
        let o = FakeOutput(), k = keeper(o)
        k.begin { _ in }
        o.signal?(.routeChanged(reason: 3, stillPlaying: false))
        for l in lines where l.contains("op=audio.") {
            XCTAssertNil(l.range(of: #"[^A-Za-z0-9._=\- \[\]#]"#, options: .regularExpression), l)
        }
    }

    func testSilenceIsAValidZeroWAV() {
        let d = BackgroundAudioKeeper.silenceWAV(sampleRate: 8000, seconds: 1)
        XCTAssertEqual(d.count, 44 + 16000)
        XCTAssertEqual(String(decoding: d.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
        XCTAssertTrue(d.dropFirst(44).allSatisfy { $0 == 0 })
    }

    /// The first line used to read the clock before the lazy launch base: `now &- t0` wrapped to ~1.8e16 ms.
    func testFirstLineTimeDoesNotUnderflow() {
        let saved = AgentDiag.monotonic
        defer { AgentDiag.monotonic = saved }
        AgentDiag.monotonic = { 0 }  // a clock reading earlier than the launch base
        AgentDiag.event("probe")
        XCTAssertTrue(lines.last!.hasPrefix("[AgentDiag] t=0 "), lines.last!)
    }
}
