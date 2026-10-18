import XCTest
@testable import UnifiedAgentCore

// Fakes for the integration layer (prefixed: WDACoreTests.swift already defines Fake*).

private func iaXML(_ cells: [(String, Double)], extra: String = "") -> String {
    "<XCUIElementTypeApplication type=\"XCUIElementTypeApplication\" name=\"Settings\" label=\"Settings\" enabled=\"true\" visible=\"true\" x=\"0\" y=\"0\" width=\"390\" height=\"844\">"
        + cells.map { "<XCUIElementTypeCell type=\"XCUIElementTypeCell\" name=\"\($0.0)\" label=\"\($0.0)\" enabled=\"true\" visible=\"true\" x=\"0\" y=\"\($0.1)\" width=\"390\" height=\"44\"/>" }.joined()
        + extra + "</XCUIElementTypeApplication>"
}

private func iaObs(_ xml: String, at: Date = Date()) -> WDAObservation {
    WDAObservation(bundleID: "com.apple.Preferences", windowSize: WDASize(width: 390, height: 844),
                   elements: try! WDASource.elements(xml), sourceDigest: WDASource.digest(xml), capturedAt: at)
}

private final class IAProvider: WDAObservationProvider {
    var xmls: [String]; var calls = 0
    init(_ xmls: [String]) { self.xmls = xmls }
    func observe(targetBundleID: String) async throws -> WDAObservation {
        calls += 1
        let x = xmls.count > 1 ? xmls.removeFirst() : xmls[0]
        return iaObs(x)
    }
}

@MainActor private final class IAModel: ChatModel {
    var replies: [String]; var prompts: [String] = []
    let model = "fake-model"
    init(_ r: [String]) { replies = r }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        prompts.append(text)
        return ChatResult(text: replies.isEmpty ? "THINK: x\nDO: fail out of replies" : replies.removeFirst(), firstToken: nil, total: 0)
    }
}

private final class IATapper: WDATapSink {
    var taps: [WDAPoint] = []
    func tap(at point: WDAPoint, window: WDASize) async throws { taps.append(point) }
}

final class IntegrationTests: XCTestCase {
    func testParseDecisions() throws {
        let d = try ElementDecision.parse("THINK: open General\nDO: tap #3\nDO: tap 4")
        XCTAssertEqual(d.action, .tap(3)); XCTAssertEqual(d.thought, "open General"); XCTAssertEqual(d.ignoredActions, 1)
        XCTAssertEqual(try ElementDecision.parse("DO: done iOS 27.1").action, .done("iOS 27.1"))
        XCTAssertEqual(try ElementDecision.parse("DO: fail needs typing").action, .fail("needs typing"))
        XCTAssertEqual(try ElementDecision.parse("DO： wait").action, .wait)
        XCTAssertEqual(try ElementDecision.parse("DO: tap 12 (General)").action, .tap(12))
        XCTAssertThrowsError(try ElementDecision.parse("DO: swipe 1 2 3 4"))
        XCTAssertThrowsError(try ElementDecision.parse("DO: tap General"))
        XCTAssertThrowsError(try ElementDecision.parse("THINK: nothing"))
    }

    func testCandidatesAndPrompt() {
        let xml = iaXML([("General", 400)], extra:
            "<XCUIElementTypeSwitch type=\"XCUIElementTypeSwitch\" name=\"Wi-Fi\" label=\"Wi-Fi\" value=\"1\" enabled=\"true\" visible=\"true\" x=\"300\" y=\"500\" width=\"51\" height=\"31\"/>"
            + "<XCUIElementTypeCell type=\"XCUIElementTypeCell\" name=\"Hidden\" label=\"Hidden\" enabled=\"true\" visible=\"false\" x=\"0\" y=\"600\" width=\"390\" height=\"44\"/>")
        let c = ElementPrompt.candidates(iaObs(xml))
        XCTAssertEqual(c.map { $0.element.label }, ["Settings", "General", "Wi-Fi"])
        XCTAssertEqual(c.map(\.tappable), [false, true, true], "a switch is operated by one tap (no type ban); hidden stays unlisted")
        let p = ElementPrompt.render(task: "open General", observation: iaObs(xml), candidates: c, history: [])
        XCTAssertTrue(p.contains("\n1 t Cell \"General\""), p)
        XCTAssertTrue(p.contains("\n2 t Switch \"Wi-Fi\" value=\"1\""), p)
    }

    @MainActor func testDryRunDecidesButSendsNothing() async {
        let tapper = IATapper()
        let agent = TaskAgent(provider: IAProvider([iaXML([("General", 400)])]),
                              model: IAModel(["THINK: open it\nDO: tap 1"]), tapper: tapper, policy: GatePolicy())
        let out = await agent.run(task: "open General", bundleID: "com.apple.Preferences", mode: .dryRun)
        XCTAssertTrue(out.hasPrefix("dry run (direct WDA tap): would tap #1 \"General\""), out)
        XCTAssertTrue(out.contains("WDA tap gate open: would send POST /session/{id}/wda/tap {\"x\":195.0,\"y\":422.0}"), out)
        XCTAssertEqual(tapper.taps, [])
    }

    @MainActor func testLiveStepActsOnceVerifiesThenModelFinishes() async {
        let tapper = IATapper()
        let before = iaXML([("General", 400)]), after = iaXML([("About", 200)])
        let provider = IAProvider([before, before, after])  // decide, step's fresh observe, verify
        let model = IAModel(["THINK: open General\nDO: tap 1", "THINK: About is shown\nDO: done General is open"])
        let agent = TaskAgent(provider: provider, model: model, tapper: tapper, policy: GatePolicy())
        let out = await agent.run(task: "open General", bundleID: "com.apple.Preferences", mode: .live)
        XCTAssertEqual(out, "done: General is open")
        XCTAssertEqual(tapper.taps, [WDAPoint(x: 195, y: 422)])
        XCTAssertEqual(provider.calls, 3)
        XCTAssertTrue(model.prompts[1].contains("tap 1 \"General\": screen changed (verified)"))
        XCTAssertTrue(model.prompts[1].contains("\"About\""))
    }

    @MainActor func testUnverifiedTapStopsWithoutRetry() async {
        let tapper = IATapper()
        let same = iaXML([("General", 400)])
        let model = IAModel(["DO: tap 1", "DO: tap 1"])
        let agent = TaskAgent(provider: IAProvider([same]), model: model, tapper: tapper, policy: GatePolicy())
        let out = await agent.run(task: "t", bundleID: "com.apple.Preferences", mode: .live)
        XCTAssertTrue(out.hasPrefix("WDA tap sent but not verified"), out)
        XCTAssertEqual(tapper.taps.count, 1)
        XCTAssertEqual(model.prompts.count, 1)
    }

    @MainActor func testForbiddenOrUnknownTapsNeverReachWDA() async {
        let tapper = IATapper()
        let xml = iaXML([], extra: "<XCUIElementTypeSlider type=\"XCUIElementTypeSlider\" name=\"Wi-Fi\" label=\"Wi-Fi\" enabled=\"true\" visible=\"true\" x=\"300\" y=\"500\" width=\"51\" height=\"31\"/>")
        let agent = TaskAgent(provider: IAProvider([xml]), model: IAModel(["DO: tap 1", "DO: tap 9", "DO: fail cannot"]),
                              tapper: tapper, policy: GatePolicy())
        let out = await agent.run(task: "t", bundleID: "com.apple.Preferences", mode: .live)
        XCTAssertEqual(out, "model stopped: cannot")
        XCTAssertEqual(tapper.taps, [])
    }
}
