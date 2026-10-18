import XCTest
@testable import UnifiedAgentCore

// Synthetic only: no device, no WDA. Geometry is an iPhone-like 390 x 844 pt window. Observation decoding, target
// selection, coordinate fractions, post-action verification, the orientation set, and the WDA-only TaskAgent.

let bundle = "com.apple.Preferences"
let window = WDASize(width: 390, height: 844)
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func el(_ type: String, id: String? = nil, label: String? = nil, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
        enabled: Bool = true, visible: Bool = true) -> UIElementSnapshot {
    UIElementSnapshot(type: type, identifier: id, label: label, frame: WDARect(x: x, y: y, width: w, height: h),
                      enabled: enabled, visible: visible)
}

func observation(_ elements: [UIElementSnapshot], digest: String = "a", at: Date = t0, bundleID: String = bundle,
                 state: Int = 4, orientation: String = "PORTRAIT") -> WDAObservation {
    WDAObservation(bundleID: bundleID, appStateBefore: state, appStateAfter: state, windowSize: window,
                   orientation: orientation, elements: elements, sourceDigest: digest, capturedAt: at)
}

/// The "General" row of Settings and its label.
let generalRow = [el("XCUIElementTypeCell", id: "General", label: "General", 0, 400, 390, 44),
                  el("XCUIElementTypeStaticText", id: "General", label: "General", 60, 410, 80, 24)]
let generalScreen = [el("XCUIElementTypeNavigationBar", id: "General", 0, 47, 390, 44),
                     el("XCUIElementTypeStaticText", id: "General", label: "General", 160, 60, 70, 20),
                     el("XCUIElementTypeCell", id: "About", label: "About", 0, 200, 390, 44)]

final class FakeProvider: WDAObservationProvider {
    var queue: [Result<WDAObservation, Error>]
    var calls = 0
    init(_ queue: [Result<WDAObservation, Error>]) { self.queue = queue }
    func observe(targetBundleID: String) async throws -> WDAObservation {
        calls += 1
        return try queue.removeFirst().get()
    }
}

/// Records every WDA tap; with `error` set, each tap throws it after being recorded.
final class FakeTapper: WDATapSink {
    var taps: [WDAPoint] = []
    var error: Error?
    func tap(at point: WDAPoint, window: WDASize) async throws {
        taps.append(point)
        if let error { throw error }
    }
}

final class FakeText: WDATextSink {
    var typed: [String] = []
    func typeText(_ text: String) async throws { typed.append(text) }
}

@MainActor final class ScriptedModel: ChatModel {
    var replies: [String]; var systems: [String] = []
    let model = "fake-model"
    init(_ r: [String]) { replies = r }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        systems.append(system)
        return ChatResult(text: replies.isEmpty ? "THINK: x\nDO: fail out of replies" : replies.removeFirst(), firstToken: nil, total: 0)
    }
}

extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}

final class SelectionTests: XCTestCase {
    func testPicksTheCellThatHoldsItsOwnLabel() throws {
        let t = try TargetSelection.select(TargetSelector(label: "General"), in: observation(generalRow)).get()
        XCTAssertEqual(t.element.type, "XCUIElementTypeCell")
        XCTAssertEqual(t.center.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.center.y, 422.0 / 844, accuracy: 1e-9)
    }

    func testAmbiguousNotFoundAndEmpty() {
        let two = [el("XCUIElementTypeCell", label: "Wi-Fi", 0, 100, 390, 44), el("XCUIElementTypeCell", label: "Wi-Fi", 0, 600, 390, 44)]
        XCTAssertEqual(TargetSelection.select(TargetSelector(label: "Wi-Fi"), in: observation(two)).failure, .ambiguous(2))
        XCTAssertEqual(TargetSelection.select(TargetSelector(label: "Nope"), in: observation(generalRow)).failure, .notFound)
        XCTAssertEqual(TargetSelection.select(TargetSelector(), in: observation(generalRow)).failure, .emptySelector)
    }

    func testRefusesTogglesFieldsDisabledHiddenAndOffscreen() {
        let toggle = [el("XCUIElementTypeSwitch", id: "Airplane Mode", 300, 100, 51, 31)]
        XCTAssertNil(TargetSelection.select(TargetSelector(identifier: "Airplane Mode"), in: observation(toggle)).failure,
                     "a switch is operated by one tap: no app-level ban")
        let field = [el("XCUIElementTypeSecureTextField", label: "Password", 20, 300, 350, 40)]
        XCTAssertNil(TargetSelection.select(TargetSelector(label: "Password"), in: observation(field)).failure, "tap focuses a field")
        let slider = [el("XCUIElementTypeSlider", label: "Brightness", 20, 300, 350, 40)]
        XCTAssertEqual(TargetSelection.select(TargetSelector(label: "Brightness"), in: observation(slider)).failure,
                       .forbiddenType("XCUIElementTypeSlider"), "needs a drag gesture, which is not supported")
        XCTAssertEqual(TargetSelection.select(TargetSelector(label: "X"),
                                              in: observation([el("XCUIElementTypeButton", label: "X", 10, 10, 40, 40, enabled: false)])).failure, .disabled)
        XCTAssertEqual(TargetSelection.select(TargetSelector(label: "X"),
                                              in: observation([el("XCUIElementTypeButton", label: "X", 10, 100, 40, 40, visible: false)])).failure, .notVisible)
        XCTAssertEqual(TargetSelection.select(TargetSelector(label: "X"),
                                              in: observation([el("XCUIElementTypeButton", label: "X", 0, 1000, 40, 40)])).failure, .offscreen)
    }

    /// `excluded_attributes=accessible,index,traits,placeholderValue` removes only attributes the parser never reads,
    /// and the `source_read` diagnostics key does not disturb decoding.
    func testSourceWithExcludedAttributesMapsToTheSameElements() throws {
        let full = """
        <?xml version="1.0" encoding="UTF-8"?><AppiumAUT><XCUIElementTypeApplication type="XCUIElementTypeApplication" \
        name="Chat" label="Chat" enabled="true" visible="true" accessible="false" x="0" y="0" width="390" height="844" \
        index="0" traits="">\
        <XCUIElementTypeTextField type="XCUIElementTypeTextField" value="" name="msg" label="Message" enabled="true" \
        visible="true" accessible="true" x="10" y="780" width="280" height="40" index="0" placeholderValue="Message" \
        traits="Button"/>\
        <XCUIElementTypeButton type="XCUIElementTypeButton" name="send" label="Send" enabled="false" visible="false" \
        accessible="true" x="300" y="780" width="60" height="44" index="1" traits="Button"/>\
        </XCUIElementTypeApplication></AppiumAUT>
        """
        let reduced = full.replacingOccurrences(of: #" (accessible|index|traits|placeholderValue)="[^"]*""#,
                                                with: "", options: .regularExpression)
        XCTAssertFalse(reduced.contains("accessible="))
        XCTAssertEqual(try WDASource.elements(reduced), try WDASource.elements(full))
        XCTAssertEqual(try WDASource.elements(reduced).count, 3)
        XCTAssertEqual(try WDASource.elements(reduced)[2].visible, false)
        let json: [String: Any] = ["schema": "x", "stage": "observe", "target_bundle_id": bundle, "app_state_before": 4,
                                   "app_state_after": 4, "window_size": ["width": 390, "height": 844],
                                   "orientation": "PORTRAIT", "source_xml": reduced, "source_unix_ms": 1_800_000_000_500,
                                   "source_read": ["route": "direct", "excluded_attributes": ["accessible"],
                                                   "deadline_ms": 20000, "elapsed_ms": 812, "after_source_failure": false],
                                   "screenshot_png_b64": "", "screenshot_unix_ms": 1_800_000_000_600]
        let o = try WDAObservation.fromUnifiedObserveJSON(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(o.elements, try WDASource.elements(full))
        XCTAssertEqual(o.sourceDigest, WDASource.digest(reduced))
    }

    func testSourcePresetDefaultsToCombinedAndKeepsExplicitConfigs() throws {
        XCTAssertEqual(WDASourcePreset.defaultsKey, "wdaSourceConfig")
        XCTAssertEqual(WDASourcePreset.effectiveConfig(stored: nil), WDASourcePreset.combined.configJSON)
        XCTAssertEqual(WDASourcePreset.effectiveConfig(stored: "  "), WDASourcePreset.combined.configJSON)
        XCTAssertEqual(WDASourcePreset.matching(stored: nil), .combined)
        let combined = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(WDASourcePreset.combined.configJSON.utf8)) as? NSDictionary)
        XCTAssertEqual(combined, ["animation_cool_off_s": 0, "source_deadline_s": 30,
                                  "excluded_attributes": ["accessible", "index", "traits", "placeholderValue"]] as NSDictionary)
        // Base is the explicit empty config, never the missing key.
        XCTAssertEqual(WDASourcePreset.baseline.configJSON, "{}")
        XCTAssertEqual(WDASourcePreset.effectiveConfig(stored: "{}"), "{}")
        XCTAssertEqual(WDASourcePreset.matching(stored: "{}"), .baseline)
        // Persisted configs are sent unchanged; equivalent spellings map to their preset, others stay custom.
        let custom = #"{"source_deadline_s":20}"#
        XCTAssertEqual(WDASourcePreset.effectiveConfig(stored: custom), custom)
        XCTAssertNil(WDASourcePreset.matching(stored: custom))
        XCTAssertNil(WDASourcePreset.matching(stored: "not json"))
        XCTAssertEqual(WDASourcePreset.matching(stored: #"{ "source_deadline_s" : 30.0 }"#), .deadlineOnly)
        for p in WDASourcePreset.allCases {
            XCTAssertEqual(WDASourcePreset.effectiveConfig(stored: p.configJSON), p.configJSON)
            XCTAssertEqual(WDASourcePreset.matching(stored: p.configJSON), p)
        }
    }

    func testDecodesUnifiedObserveJSON() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><AppiumAUT><XCUIElementTypeApplication type="XCUIElementTypeApplication" \
        name="Settings" label="Settings" enabled="true" visible="true" x="0" y="0" width="390" height="844">\
        <XCUIElementTypeCell type="XCUIElementTypeCell" name="General" label="General" enabled="true" visible="true" \
        x="0" y="400" width="390" height="44"/></XCUIElementTypeApplication></AppiumAUT>
        """
        let json: [String: Any] = ["schema": "x", "stage": "observe", "target_bundle_id": bundle, "app_state_before": 4,
                                   "app_state_after": 4, "window_size": ["width": 390, "height": 844],
                                   "orientation": "PORTRAIT", "source_xml": xml, "source_unix_ms": 1_800_000_000_500,
                                   "screenshot_png_b64": "", "screenshot_unix_ms": 1_800_000_000_600]
        let o = try WDAObservation.fromUnifiedObserveJSON(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(o.bundleID, bundle)
        XCTAssertEqual(o.windowSize, window)
        XCTAssertTrue(o.foreground)
        XCTAssertEqual(o.elements.count, 2)
        XCTAssertEqual(o.elements[1], el("XCUIElementTypeCell", id: "General", label: "General", 0, 400, 390, 44))
        XCTAssertEqual(o.capturedAt.timeIntervalSince1970, 1_800_000_000.5, accuracy: 1e-6)
        XCTAssertEqual(o.sourceDigest, WDASource.digest(xml))
        XCTAssertThrowsError(try WDAObservation.fromUnifiedObserveJSON(Data(#"{"target_bundle_id":"x"}"#.utf8)))
    }

    func testPointsBecomeWindowFractions() {
        XCTAssertEqual(CoordinateTransform.fraction(WDAPoint(x: 195, y: 422), in: window), WDAPoint(x: 0.5, y: 0.5))
        XCTAssertNil(CoordinateTransform.fraction(WDAPoint(x: 1, y: 1), in: WDASize(width: 0, height: 0)))
    }
}

final class VerificationTests: XCTestCase {
    func testVerificationNeedsAFreshForegroundObservationOfTheApp() {
        let before = observation(generalRow)
        let acted = t0.addingTimeInterval(1)
        func v(_ after: WDAObservation, _ e: Expectation = .sourceChanged) -> StepVerification.Result {
            StepVerification.verify(after, expect: e, before: before, bundleID: bundle, actedAt: acted)
        }
        XCTAssertEqual(v(observation(generalScreen, digest: "b", at: t0.addingTimeInterval(0.5))),
                       .notVerified("observation is older than the click"))
        XCTAssertEqual(v(observation(generalScreen, digest: "b", at: t0.addingTimeInterval(2), bundleID: "com.apple.springboard")),
                       .notVerified("observation is of com.apple.springboard"))
        XCTAssertEqual(v(observation(generalScreen, digest: "b", at: t0.addingTimeInterval(2), state: 2)),
                       .notVerified("\(bundle) is not in the foreground"))
        XCTAssertEqual(v(observation(generalRow, at: t0.addingTimeInterval(2))), .notVerified("screen did not change"))
        XCTAssertEqual(v(observation(generalScreen, digest: "b", at: t0.addingTimeInterval(2)),
                         .elementPresent(TargetSelector(identifier: "Nope"))), .notVerified("expected element not found"))
        XCTAssertEqual(v(observation(generalScreen, digest: "b", at: t0.addingTimeInterval(2)),
                         .elementPresent(TargetSelector(identifier: "About"))), .verified)
        XCTAssertEqual(v(observation(generalScreen, digest: "b", at: t0.addingTimeInterval(2))), .verified)
    }

    func testGatePolicyKeepsOnlyTheObservationAge() {
        XCTAssertEqual(GatePolicy().maxObservationAge, 2.0)
        XCTAssertEqual(Mirror(reflecting: GatePolicy()).children.compactMap(\.label), ["maxObservationAge"])
    }

    func testOrientationSetIsUnchangedAndOthersAreRefused() {
        XCTAssertEqual(WDAOrientation.known, ["PORTRAIT", "LANDSCAPE", "UIA_DEVICE_ORIENTATION_LANDSCAPERIGHT",
                                              "UIA_DEVICE_ORIENTATION_PORTRAIT_UPSIDEDOWN"])
        for bad in ["", "FACEUP", "portrait"] {
            let o = observation(generalRow, orientation: bad)
            let t = try! TargetSelection.select(TargetSelector(label: "General"), in: o).get()
            XCTAssertEqual(WDATapGate.evaluate(target: t, observation: o, expectedBundleID: bundle, now: t0).failure?.reasons,
                           [.unknownOrientation(bad)], bad)
        }
    }
}

/// The task agent has exactly one input path: direct WDA taps (and WDA typing when a text sink is set).
@MainActor final class WDAOnlyAgentTests: XCTestCase {
    private func tapGeneral(_ o: WDAObservation) -> String {
        "THINK: open\nDO: tap \(ElementPrompt.list(o).items.firstIndex { $0.element.label == "General" }!)"
    }

    func testDefaultConstructionIsWDAOnly() {
        let tapper = FakeTapper()
        let endpoint = ModelEndpoint(baseURL: "https://example.test/v1", model: "m", apiKey: "k")
        let a = TaskAgent(provider: FakeProvider([]), endpoint: endpoint, tapper: tapper, policy: GatePolicy())
        XCTAssertTrue(a.tapper === tapper)
        XCTAssertNil(a.typing, "typing is offered only once a WDA text sink is set")
        XCTAssertNil(a.crossApp)
        let stored = Set(Mirror(reflecting: a).children.compactMap(\.label))
        for gone in ["sink", "cursor", "calibration", "absolute", "wdaTap"] {
            XCTAssertFalse(stored.contains(gone), "no \(gone) on the WDA-only agent: \(stored)")
        }
    }

    func testDryRunTapsThroughTheWDAGateAndSendsNothing() async {
        let tapper = FakeTapper(), text = FakeText()
        let o = observation(generalRow, at: Date())
        let provider = FakeProvider([.success(o)])
        let a = TaskAgent(provider: provider, model: ScriptedModel([tapGeneral(o)]), tapper: tapper, policy: GatePolicy())
        a.wdaText = text
        let out = await a.run(task: "open General", bundleID: bundle, mode: .dryRun)
        XCTAssertTrue(out.hasPrefix("dry run (direct WDA tap): would tap #"), out)
        XCTAssertTrue(out.contains("WDA tap gate open: would send POST /session/{id}/wda/tap {\"x\":195.0,\"y\":422.0}"), out)
        XCTAssertTrue(out.hasSuffix("Nothing was sent to WDA."), out)
        XCTAssertEqual(tapper.taps, []); XCTAssertEqual(text.typed, []); XCTAssertEqual(provider.calls, 1)
        XCTAssertFalse(a.events.contains { $0.kind == .act })
        XCTAssertTrue(a.events.first?.text.contains("dry run (nothing sent to WDA)") ?? false)
    }

    func testDryRunGateStillClosesOnAStaleObservation() async {
        let tapper = FakeTapper()
        let o = observation(generalRow, at: Date().addingTimeInterval(-30))
        let a = TaskAgent(provider: FakeProvider([.success(o)]), model: ScriptedModel([tapGeneral(o)]), tapper: tapper,
                          policy: GatePolicy())
        let out = await a.run(task: "open General", bundleID: bundle, mode: .dryRun)
        XCTAssertTrue(out.contains("WDA tap gate closed: observationStale"), out)
        XCTAssertEqual(tapper.taps, [])
    }

    func testLiveTapGoesThroughWDAByDefault() async {
        let tapper = FakeTapper()
        let before = observation(generalRow, at: Date())
        let provider = FakeProvider([.success(before), .success(before),
                                     .success(observation(generalScreen, digest: "b", at: Date().addingTimeInterval(5)))])
        let a = TaskAgent(provider: provider, model: ScriptedModel([tapGeneral(before), "THINK: ok\nDO: done open"]),
                          tapper: tapper, policy: GatePolicy())
        let out = await a.run(task: "open General", bundleID: bundle, mode: .live)
        XCTAssertEqual(out, "done: open")
        XCTAssertEqual(tapper.taps, [WDAPoint(x: 195, y: 422)])
    }

    func testTypingIsOfferedWhenAWDATextSinkIsSet() async {
        let o = observation(generalRow, at: Date())
        let with = ScriptedModel(["THINK: x\nDO: fail stop"])
        let a = TaskAgent(provider: FakeProvider([.success(o)]), model: with, tapper: FakeTapper(), policy: GatePolicy())
        a.wdaText = FakeText()
        XCTAssertNotNil(a.typing)
        _ = await a.run(task: "t", bundleID: bundle, mode: .dryRun)
        XCTAssertEqual(with.systems.first, ElementPrompt.system(typing: true))
        XCTAssertTrue(with.systems.first?.contains("type \"TEXT\"") ?? false)

        let without = ScriptedModel(["THINK: x\nDO: fail stop"])
        let b = TaskAgent(provider: FakeProvider([.success(o)]), model: without, tapper: FakeTapper(), policy: GatePolicy())
        _ = await b.run(task: "t", bundleID: bundle, mode: .dryRun)
        XCTAssertEqual(without.systems.first, ElementPrompt.system)
        XCTAssertFalse(without.systems.first?.contains("type \"TEXT\"") ?? true)
    }
}
