import XCTest
@testable import UnifiedAgentCore

// Direct WDA tap backend (the only input path): gate, scope, single-use step, and TaskAgent integration.

private let wtBundle = "com.apple.Preferences"

private func wtXML(_ cells: [(String, Double)]) -> String {
    "<XCUIElementTypeApplication type=\"XCUIElementTypeApplication\" name=\"Settings\" label=\"Settings\" enabled=\"true\" visible=\"true\" x=\"0\" y=\"0\" width=\"390\" height=\"844\">"
        + cells.map { ($0.0.replacingOccurrences(of: "&", with: "&amp;"), $0.1) }.map { "<XCUIElementTypeCell type=\"XCUIElementTypeCell\" name=\"\($0.0)\" label=\"\($0.0)\" enabled=\"true\" visible=\"true\" x=\"0\" y=\"\($0.1)\" width=\"390\" height=\"44\"/>" }.joined()
        + "</XCUIElementTypeApplication>"
}

private func wtObs(_ xml: String, bundle: String = wtBundle, at: Date = Date(), orientation: String = "PORTRAIT",
                   window: WDASize = WDASize(width: 390, height: 844), foreground: Bool = true) -> WDAObservation {
    WDAObservation(bundleID: bundle, appStateAfter: foreground ? 4 : 3, windowSize: window, orientation: orientation,
                   elements: try! WDASource.elements(xml), sourceDigest: WDASource.digest(xml), capturedAt: at)
}

private let first = wtXML([("General", 100), ("Accessibility", 200)])
private let second = wtXML([("About", 100)])
/// "DO: tap N" for the candidate labelled `label` on `first`.
private func tapGeneral() -> String {
    let i = ElementPrompt.candidates(wtObs(first)).firstIndex { $0.element.label == "General" }!
    return "THINK: open\nDO: tap \(i)"
}

private final class WTProvider: WDAObservationProvider {
    var queue: [() -> WDAObservation]; var calls = 0
    init(_ q: [() -> WDAObservation]) { queue = q }
    func observe(targetBundleID: String) async throws -> WDAObservation {
        calls += 1
        return queue.count > 1 ? queue.removeFirst()() : queue[0]()
    }
}

private final class WTTapper: WDATapSink {
    var taps: [(WDAPoint, WDASize)] = []; var error: Error?
    func tap(at point: WDAPoint, window: WDASize) async throws {
        taps.append((point, window))
        if let error { throw error }
    }
}

@MainActor private final class WTModel: ChatModel {
    var replies: [String]; let model = "fake-model"
    init(_ r: [String]) { replies = r }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        ChatResult(text: replies.isEmpty ? "THINK: x\nDO: fail out of replies" : replies.removeFirst(), firstToken: nil, total: 0)
    }
}

@MainActor final class WDATapTests: XCTestCase {
    private func agent(_ p: WTProvider, _ t: WTTapper, _ replies: [String]) -> TaskAgent {
        TaskAgent(provider: p, model: WTModel(replies), tapper: t, policy: GatePolicy())
    }

    private func target(_ label: String, in o: WDAObservation) -> SelectedTarget {
        guard case .success(let t) = TargetSelection.select(TargetSelector(label: label), in: o) else { fatalError() }
        return t
    }

    // MARK: gate

    func testGateOpensOnAFreshObservationAndTapsCentreInPoints() {
        let o = wtObs(first)
        guard case .success(let plan) = WDATapGate.evaluate(target: target("General", in: o), observation: o,
                                                            expectedBundleID: wtBundle, now: Date()) else { return XCTFail() }
        XCTAssertEqual(plan.point, WDAPoint(x: 195, y: 122))
        XCTAssertEqual(plan.window, WDASize(width: 390, height: 844))
        XCTAssertTrue(plan.summary.hasPrefix("POST /session/{id}/wda/tap {\"x\":195.0,\"y\":122.0}"))
    }

    func testGateRefusesStaleWrongAppBackgroundOtherObservationUnknownOrientation() {
        let o = wtObs(first)
        let t = target("General", in: o)
        func reasons(_ obs: WDAObservation, _ t: SelectedTarget, expected: String = wtBundle) -> [WDATapBlock] {
            if case .failure(let b) = WDATapGate.evaluate(target: t, observation: obs, expectedBundleID: expected, now: Date()) { return b.reasons }
            return []
        }
        XCTAssertTrue(reasons(wtObs(first, at: Date().addingTimeInterval(-10)), t).contains(.observationStale))
        XCTAssertTrue(reasons(o, t, expected: "com.apple.mobilesafari").contains(.observationAppMismatch(expected: "com.apple.mobilesafari", got: wtBundle)))
        XCTAssertTrue(reasons(wtObs(first, foreground: false), t).contains(.appNotForeground))
        XCTAssertTrue(reasons(wtObs(second), t).contains(.targetFromOtherObservation))
        XCTAssertTrue(reasons(wtObs(first, window: WDASize(width: 844, height: 390)), t).contains(.targetFromOtherObservation))
        XCTAssertTrue(reasons(wtObs(first, orientation: "UNKNOWN"), target("General", in: wtObs(first, orientation: "UNKNOWN")))
            .contains(.unknownOrientation("UNKNOWN")))
    }

    func testGateRefusesOutOfBoundsNeverClamps() {
        let o = wtObs(first)
        var t = target("General", in: o)
        t.element.frame = WDARect(x: 380, y: 100, width: 40, height: 44)  // centre x = 400 > 390
        guard case .failure(let b) = WDATapGate.evaluate(target: t, observation: o, expectedBundleID: wtBundle, now: Date()) else { return XCTFail() }
        XCTAssertEqual(b.reasons, [.outOfBounds])
    }

    func testGateHasNoSemanticBansOnlyTechnicalChecks() {
        // previously refused by word lists; the user's task and the model's provider policies decide now
        for label in ["Send", "Enviar mensaje", "Buy Now", "Comprar", "Delete Account", "Borrar todo", "Erase All Content",
                      "Passwords", "Contraseñas", "Face ID & Passcode", "Privacy & Security", "Sign Out", "Cerrar sesión", "Call"] {
            let o = wtObs(wtXML([(label, 100)]))
            guard case .success = WDATapGate.evaluate(target: target(label, in: o), observation: o, expectedBundleID: wtBundle,
                                                      now: Date()) else { XCTFail(label); continue }
        }
        // technical checks still hold: a stale observation and a foreign app are refused
        let o = wtObs(wtXML([("Send", 100)]))
        guard case .failure(let b) = WDATapGate.evaluate(target: target("Send", in: o), observation: o, expectedBundleID: "net.whatsapp.WhatsApp",
                                                         now: Date().addingTimeInterval(60)) else { return XCTFail() }
        XCTAssertTrue(b.reasons.contains(.observationStale)); XCTAssertTrue(b.reasons.contains { if case .observationAppMismatch = $0 { return true }; return false })
    }

    // MARK: TaskAgent integration

    func testLiveTapIsVerifiedOnFreshObservation() async {
        let p = WTProvider([{ wtObs(first) }, { wtObs(first) }, { wtObs(second) }])
        let t = WTTapper()
        let a = agent(p, t, [tapGeneral(), "THINK: ok\nDO: done opened"])
        let out = await a.run(task: "open General", bundleID: wtBundle, mode: .live)
        XCTAssertEqual(out, "done: opened")
        XCTAssertEqual(t.taps.count, 1)
        XCTAssertEqual(t.taps.first?.0, WDAPoint(x: 195, y: 122))
        XCTAssertEqual(t.taps.first?.1, WDASize(width: 390, height: 844))
        XCTAssertEqual(p.calls, 3, "initial, fresh pre-tap, verify")
        XCTAssertTrue(a.events.contains { $0.kind == .verify })
    }

    func testDryRunMakesZeroWrites() async {
        let p = WTProvider([{ wtObs(first) }])
        let t = WTTapper()
        let out = await agent(p, t, [tapGeneral()]).run(task: "x", bundleID: wtBundle, mode: .dryRun)
        XCTAssertTrue(out.contains("dry run (direct WDA tap)") && out.contains("gate open"), out)
        XCTAssertTrue(out.hasSuffix("Nothing was sent to WDA."), out)
        XCTAssertEqual(t.taps.count, 0); XCTAssertEqual(p.calls, 1)
    }

    func testUncertainTimeoutSendsOnceStopsNoReplayNoRetry() async {
        let p = WTProvider([{ wtObs(first) }])
        let t = WTTapper(); t.error = WDATapError.uncertain("no answer before the deadline")
                let out = await agent(p, t, [tapGeneral(), tapGeneral()])
            .run(task: "x", bundleID: wtBundle, mode: .live)
        XCTAssertTrue(out.contains("uncertain") && out.contains("Not replayed or retried"), out)
        XCTAssertEqual(t.taps.count, 1)
        XCTAssertEqual(p.calls, 2, "no observation after an uncertain tap, no recovery")
    }

    func testUntypedTapErrorIsTreatedAsUncertain() async {
        struct Weird: Error {}
        let p = WTProvider([{ wtObs(first) }]); let t = WTTapper(); t.error = Weird()
        let out = await agent(p, t, [tapGeneral()]).run(task: "x", bundleID: wtBundle, mode: .live)
        XCTAssertTrue(out.contains("uncertain"), out); XCTAssertEqual(t.taps.count, 1)
    }

    func testRejectedIsNotRetried() async {
        let p = WTProvider([{ wtObs(first) }]); let t = WTTapper(); t.error = WDATapError.rejected("status=404 Session does not exist")
        let out = await agent(p, t, [tapGeneral(), tapGeneral()])
            .run(task: "x", bundleID: wtBundle, mode: .live)
        XCTAssertTrue(out.contains("refused") && out.contains("Session does not exist"), out)
        XCTAssertEqual(t.taps.count, 1)
    }

    func testStaleFreshObservationBlocksWithoutTap() async {
        let p = WTProvider([{ wtObs(first) }, { wtObs(first, at: Date().addingTimeInterval(-30)) }])
        let t = WTTapper()
        let out = await agent(p, t, [tapGeneral()]).run(task: "x", bundleID: wtBundle, mode: .live)
        XCTAssertTrue(out.contains("observationStale"), out); XCTAssertEqual(t.taps.count, 0)
    }

    func testWrongAppOnFreshObservationBlocksWithoutTap() async {
        let p = WTProvider([{ wtObs(first) }, { wtObs(first, bundle: "com.apple.mobilesafari") }])
        let t = WTTapper()
        let out = await agent(p, t, [tapGeneral()]).run(task: "x", bundleID: wtBundle, mode: .live)
        XCTAssertTrue(out.contains("observationAppMismatch"), out); XCTAssertEqual(t.taps.count, 0)
    }

    func testOrientationOrWindowChangeAfterTapIsNotVerified() async {
        for after in [wtObs(second, orientation: "LANDSCAPE"), wtObs(second, window: WDASize(width: 844, height: 390))] {
            let p = WTProvider([{ wtObs(first) }, { wtObs(first) }, { after }]); let t = WTTapper()
            let out = await agent(p, t, [tapGeneral(), tapGeneral()])
                .run(task: "x", bundleID: wtBundle, mode: .live)
            XCTAssertTrue(out.contains("not verified") && out.contains("orientation changed"), out)
            XCTAssertEqual(t.taps.count, 1)
        }
    }

    func testUnknownOrientationBlocksWithoutTap() async {
        let p = WTProvider([{ wtObs(first, orientation: "") }]); let t = WTTapper()
        let out = await agent(p, t, [tapGeneral()]).run(task: "x", bundleID: wtBundle, mode: .live)
        XCTAssertTrue(out.contains("unknownOrientation"), out); XCTAssertEqual(t.taps.count, 0)
    }

    func testStepIsSingleUse() async {
        let p = WTProvider([{ wtObs(first) }, { wtObs(second) }]); let t = WTTapper()
        let step = WDATapNavigationStep(bundleID: wtBundle, provider: p, tapper: t)
        let r1 = await step.run(tap: TargetSelector(label: "General"), expect: .sourceChanged)
        XCTAssertEqual(r1.outcome, .verified); XCTAssertEqual(r1.taps, 1)
        let r2 = await step.run(tap: TargetSelector(label: "General"), expect: .sourceChanged)
        XCTAssertEqual(r2.outcome, .alreadyConsumed); XCTAssertEqual(t.taps.count, 1)
    }
}
