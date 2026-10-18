import XCTest
@testable import UnifiedAgentCore

final class AgentDiagTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ s: String) { lock.lock(); all.append(s); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return all }
    }
    private var out = Lines()
    private var savedSink: ((String) -> Void)!
    private var savedEvery: UInt64 = 0

    override func setUp() {
        out = Lines()
        savedSink = AgentDiag.sink
        savedEvery = AgentDiag.waitEveryNanoseconds
        let o = out
        AgentDiag.sink = { o.add($0) }
    }

    override func tearDown() {
        AgentDiag.sink = savedSink
        AgentDiag.waitEveryNanoseconds = savedEvery
    }

    private enum PrivateError: Error { case echoed(String) }

    func testValuesAndErrorsAreRedacted() {
        AgentDiag.waitEveryNanoseconds = 0
        let secret = "Abre \"Ajustes\" y escribe fixture@example.invalid sk-123 <XCUIElementTypeButton label=\"Pagar\">"
        AgentDiag.event("probe", [("t", .token(secret)), ("n", .int(3))])
        AgentDiag.begin("op", []).fail(PrivateError.echoed(secret))
        let all = out.lines.joined(separator: "\n")
        XCTAssertEqual(out.lines.count, 3)
        for bad in [" y ", "\"", "<", "@", "label=", "Pagar\""] { XCTAssertFalse(all.contains(bad), bad) }
        XCTAssertTrue(out.lines.allSatisfy { $0.hasPrefix("[AgentDiag] t=") })
        XCTAssertTrue(out.lines[2].contains("end err"))
        XCTAssertTrue(out.lines[2].hasSuffix("err=PrivateError.0"), out.lines[2])
        XCTAssertLessThanOrEqual(AgentDiag.token(String(repeating: "a", count: 200)).count, 48)
    }

    func testBeginEndPairOnceWithSameID() {
        AgentDiag.waitEveryNanoseconds = 0
        let s = AgentDiag.begin("wda.observe", [("expected", .bool(true))])
        s.end([("elements", .int(7))])
        s.end()
        s.fail(CancellationError())
        XCTAssertEqual(out.lines.count, 2)
        XCTAssertTrue(out.lines[0].contains("op=\(s.id) begin expected=1"))
        XCTAssertTrue(out.lines[1].contains("op=\(s.id) end ok ms="))
        XCTAssertTrue(out.lines[1].hasSuffix("elements=7"))
    }

    /// A slow native call that ignores cancellation (as a blocking FFI call does): stopping the caller does not end its
    /// span early, `wait` lines keep coming, the call runs exactly once and the handle is released only after it.
    func testSlowUncancellableCallStaysPendingAfterStop() async {
        AgentDiag.waitEveryNanoseconds = 30_000_000
        final class Handle: @unchecked Sendable {
            let lock = NSLock(); var calls = 0; var freed = false; var usedAfterFree = false
        }
        let h = Handle()
        let caller = Task {
            await AgentDiag.measure("wda.observe") {
                await Task.detached {  // as UniRunner.call: not a child of the caller, not cancelled with it
                    h.lock.lock(); h.calls += 1; h.lock.unlock()
                    Thread.sleep(forTimeInterval: 0.25)
                    h.lock.lock(); if h.freed { h.usedAfterFree = true }; h.lock.unlock()
                }.value
            }
            h.lock.lock(); h.freed = true; h.lock.unlock()  // close only after the call returned
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        caller.cancel()
        AgentDiag.event("agent.stop_requested")
        XCTAssertFalse(out.lines.contains { $0.contains("end ") }, "ended before the native call returned")
        await caller.value
        let lines = out.lines
        XCTAssertEqual(h.calls, 1)
        XCTAssertFalse(h.usedAfterFree)
        XCTAssertTrue(h.freed)
        let stop = lines.firstIndex { $0.contains("agent.stop_requested") }!
        let end = lines.firstIndex { $0.contains("end ok") }!
        XCTAssertTrue(lines[(stop + 1)..<end].contains { $0.contains(" wait ms=") }, lines.joined(separator: "\n"))
        XCTAssertEqual(lines.filter { $0.contains(" begin") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains(" end ") }.count, 1)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(out.lines.count, lines.count, "wait lines after end")
    }

    func testBuildFieldsCarryPresetAndNumericLeversOnly() {
        AgentDiag.waitEveryNanoseconds = 0
        AgentDiag.event("build", BuildStamp.diagFields(bundleVersion: "7", libVersion: "unified_ffi 0.1.0", storedSourceConfig: nil))
        let l = out.lines[0]
        XCTAssertTrue(l.contains("ui=\(AgentDiag.token(BuildStamp.uiRevision))"))
        XCTAssertTrue(l.contains("source_preset=combined"), l)
        XCTAssertTrue(l.contains("ffi=unified_ffi_0.1.0"))
    }
}
