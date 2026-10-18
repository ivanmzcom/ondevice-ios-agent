import XCTest
@testable import UnifiedAgentCore

// LATENCY_IMPROVEMENTS_REPORT.md: exact target identity across fresh revalidation, no replay after an uncertain tap,
// the bound compact observation (hermes-observation/2), screenshot-free observations, and model timing fields.
// Synthetic data only.

private final class SeqProvider: WDAObservationProvider {
    var queue: [WDAObservation]
    private(set) var observes = 0
    init(_ q: [WDAObservation]) { queue = q }
    func observe(targetBundleID: String) async throws -> WDAObservation {
        observes += 1
        return queue.count > 1 ? queue.removeFirst() : queue[0]
    }
}

private final class RecTapper: WDATapSink {
    var error: Error?
    private(set) var points: [WDAPoint] = []
    func tap(at point: WDAPoint, window: WDASize) async throws {
        points.append(point)
        if let error { throw error }
    }
}

@MainActor private final class ScriptModel: ChatModel {
    let model = "synthetic-model"
    var replies: [String]
    private(set) var calls = 0
    init(_ r: [String]) { replies = r }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        calls += 1
        return ChatResult(text: replies.removeFirst(), firstToken: 0.1, total: 0.2)
    }
}

final class ExactTargetTests: XCTestCase {
    let bundle = "ph.telegra.Telegraph"
    let win = WDASize(width: 390, height: 844)
    let now = Date(timeIntervalSince1970: 1_000)
    let a = WDARect(x: 0, y: 200, width: 390, height: 60), b = WDARect(x: 0, y: 270, width: 390, height: 60)

    func el(_ type: String, _ label: String?, _ f: WDARect) -> UIElementSnapshot {
        UIElementSnapshot(type: "XCUIElementType" + type, label: label, frame: f)
    }
    func obs(_ rows: [UIElementSnapshot], extra: [UIElementSnapshot] = [], digest: String = "d1", at: Date? = nil) -> WDAObservation {
        WDAObservation(bundleID: bundle, windowSize: win,
                       elements: [el("Application", "Telegram", WDARect(x: 0, y: 0, width: 390, height: 844)),
                                  el("SearchField", "Search", WDARect(x: 10, y: 60, width: 370, height: 36))] + rows + extra,
                       sourceDigest: digest, capturedAt: at ?? now)
    }
    var dupes: [UIElementSnapshot] { [el("Other", "Test Contact", a), el("Other", "Test Contact", b)] }
    /// Element index of the second duplicate row (b) in `obs(dupes)`.
    let bIndex = 3

    func testSecondDuplicateResolvesToItselfOnTheSameObservation() throws {
        let o = obs(dupes)
        XCTAssertEqual(TargetSelection.select(TargetSelector(label: "Test Contact"), in: o), .failure(.ambiguous(2)),
                       "label-only lookup stays ambiguous")
        let ref = try XCTUnwrap(TargetRef(elementIndex: bIndex, in: o))
        XCTAssertFalse(ref.selectorUnique)
        let t = try TargetSelection.resolve(ref, in: o).get()
        XCTAssertEqual(t.element.frame, b)
        let item = try XCTUnwrap(ElementPrompt.list(o).items.first { $0.element.frame == b })
        XCTAssertEqual(item.sourceIndex, bIndex, "the listed number maps to the exact element")
    }

    func testChangedObservationRebindsOnlyWhileTheDuplicateGroupIsUnchanged() throws {
        let ref = try XCTUnwrap(TargetRef(elementIndex: bIndex, in: obs(dupes)))
        // another part of the screen changed (new digest, extra text): same group, same element
        let clock = el("StaticText", "12:01", WDARect(x: 10, y: 10, width: 40, height: 20))
        XCTAssertEqual(try TargetSelection.resolve(ref, in: obs(dupes, extra: [clock], digest: "d2")).get().element.frame, b)
        // the rows moved (scrolled): refused, never the row now at the old position
        let moved = [el("Other", "Test Contact", WDARect(x: 0, y: 130, width: 390, height: 60)), el("Other", "Test Contact", a)]
        XCTAssertEqual(TargetSelection.resolve(ref, in: obs(moved, digest: "d3")), .failure(.targetChanged("same-label elements changed since the choice; not rebound by label")))
        // the first row vanished: the label is unique now, but it is still refused (no label rebind)
        XCTAssertEqual(TargetSelection.resolve(ref, in: obs([el("Other", "Test Contact", a)], digest: "d4")).isSuccess, false)
        XCTAssertEqual(TargetSelection.resolve(ref, in: obs([el("Other", "Test Contact", b)], digest: "d5")).isSuccess, false)
        // a third sibling appeared
        XCTAssertEqual(TargetSelection.resolve(ref, in: obs(dupes + [el("Other", "Test Contact", WDARect(x: 0, y: 340, width: 390, height: 60))], digest: "d6")).isSuccess, false)
        // same digest but a different element at that position is not "the same place"
        XCTAssertEqual(TargetSelection.resolve(ref, in: obs([el("Other", "Test Contact", a), el("Other", "Other Row", b)])).isSuccess, false)
    }

    func testUniqueSelectorKeepsTheExistingSelection() throws {
        let row = el("Other", "Test Contact", a), text = el("StaticText", "Test Contact", WDARect(x: 70, y: 210, width: 200, height: 20))
        let o = obs([row, text])
        let ref = try XCTUnwrap(TargetRef(elementIndex: 2, in: o))
        XCTAssertTrue(ref.selectorUnique)
        XCTAssertEqual(TargetSelection.resolve(ref, in: o), TargetSelection.select(ref.selector, in: o))
        XCTAssertEqual(TargetSelection.resolve(ref, in: obs([row], digest: "d2")), TargetSelection.select(ref.selector, in: obs([row], digest: "d2")))
    }

    @MainActor func testStepTapsTheChosenDuplicateAndVerifies() async throws {
        let o = obs(dupes)
        let ref = try XCTUnwrap(TargetRef(elementIndex: bIndex, in: o))
        let provider = SeqProvider([o, obs(dupes, extra: [el("NavigationBar", "Chat", WDARect(x: 0, y: 47, width: 390, height: 44))],
                                          digest: "after", at: now.addingTimeInterval(1))])
        let tapper = RecTapper()
        let r = await WDATapNavigationStep(bundleID: bundle, provider: provider, tapper: tapper, clock: { self.now })
            .run(tap: ref, expect: .sourceChanged)
        XCTAssertEqual(r.outcome, .verified)
        XCTAssertEqual(tapper.points, [WDAPoint(x: 195, y: 300)], "centre of b, the row the model chose")
        XCTAssertEqual(provider.observes, 2, "fresh observation before and verification after the tap are kept")
    }

    @MainActor func testUncertainTapIsNeverReplayed() async throws {
        let o = obs(dupes)
        let ref = try XCTUnwrap(TargetRef(elementIndex: bIndex, in: o))
        let provider = SeqProvider([o])
        let tapper = RecTapper(); tapper.error = WDATapError.uncertain("deadline after write")
        let step = WDATapNavigationStep(bundleID: bundle, provider: provider, tapper: tapper, clock: { self.now })
        let r = await step.run(tap: ref, expect: .sourceChanged)
        guard case .tapUncertain = r.outcome else { return XCTFail("\(r.outcome)") }
        XCTAssertEqual([r.taps, tapper.points.count, provider.observes], [1, 1, 1], "no second tap, no verification read")
        let again = await step.run(tap: ref, expect: .sourceChanged)
        XCTAssertEqual(again.outcome, .alreadyConsumed)
        XCTAssertEqual(tapper.points.count, 1)
    }

    @MainActor func testChangedGroupIsRefusedBeforeAnyTap() async throws {
        let ref = try XCTUnwrap(TargetRef(elementIndex: bIndex, in: obs(dupes)))
        let tapper = RecTapper()
        let r = await WDATapNavigationStep(bundleID: bundle, provider: SeqProvider([obs([el("Other", "Test Contact", b)], digest: "d2")]),
                                           tapper: tapper, clock: { self.now }).run(tap: ref, expect: .sourceChanged)
        guard case .selectionFailed(.targetChanged) = r.outcome else { return XCTFail("\(r.outcome)") }
        XCTAssertEqual([r.taps, tapper.points.count], [0, 0])
    }

    @MainActor func testAgentTapsTheListedDuplicateInsteadOfRefusingAmbiguity() async throws {
        let o = obs(dupes)
        let n = try XCTUnwrap(ElementPrompt.list(o).items.firstIndex { $0.element.frame == b })
        let after = obs(dupes, extra: [el("NavigationBar", "Chat", WDARect(x: 0, y: 47, width: 390, height: 44))],
                        digest: "after", at: now.addingTimeInterval(1))
        let provider = SeqProvider([o, o, after])
        let tapper = RecTapper()
        let model = ScriptModel(["THINK: open the second result\nDO: tap \(n)", "THINK: opened\nDO: done ok"])
        let agent = TaskAgent(provider: provider, model: model, tapper: tapper, policy: GatePolicy(), clock: { self.now })
        let outcome = await agent.run(task: "open the chat", bundleID: bundle, mode: .live)
        XCTAssertEqual(outcome, "done: ok", "\(agent.events.map(\.text))")
        XCTAssertEqual(tapper.points, [WDAPoint(x: 195, y: 300)])
    }
}

private extension Result { var isSuccess: Bool { if case .success = self { return true }; return false } }

extension CompactObservationTests {
    func bound(_ edit: ((inout [String: Any]) -> Void)? = nil) -> [String: Any] {
        compact(edit: { o in
            o["schema"] = "hermes-observation/2"
            o["runner"] = ["endpoint": "hermes/observation", "endpoint_version": 2, "wda_version": "16.15.3"]
            let side: [String: Any] = ["bundle_id": self.bundle, "pid": 42, "orientation": "PORTRAIT", "expected_state": 4]
            o["identity"] = ["expected_bundle_id": self.bundle, "before": side, "after": side, "stable": true, "refused": NSNull()]
            edit?(&o)
        })
    }
    func identity(_ o: inout [String: Any], _ k: String, _ field: String, _ v: Any) {
        var id = o["identity"] as! [String: Any]; var s = id[k] as! [String: Any]
        s[field] = v; id[k] = s; o["identity"] = id
    }

    func testBoundObservationDecodesLikeV1() throws {
        let v1 = try decode(compact()), v2 = try decode(bound())
        XCTAssertEqual(v2.elements, v1.elements)
        XCTAssertEqual(v2.sourceDigest, v1.sourceDigest, "identity is metadata, not screen content")
        XCTAssertEqual(v2.provenance?.endpointVersion, 2)
        XCTAssertEqual(v2.provenance?.schema, "hermes-observation/2")
    }

    func testBoundForegroundChangeDuringSnapshotIsRefusedEvenWhenMarkedStable() {
        assertRefused(bound { self.identity(&$0, "after", "pid", 43) }, "changed during the snapshot")
        assertRefused(bound { self.identity(&$0, "after", "bundle_id", "com.example.other") }, "changed during the snapshot")
        assertRefused(bound { self.identity(&$0, "before", "pid", 41); self.identity(&$0, "after", "pid", 41) }, "not the snapshot's app")
        assertRefused(bound { o in var id = o["identity"] as! [String: Any]; id["stable"] = false; o["identity"] = id }, "not marked stable")
        assertRefused(bound { o in var id = o["identity"] as! [String: Any]; id["refused"] = "foreground_changed_during_observation"; o["identity"] = id }, "runner refused")
        assertRefused(bound { $0.removeValue(forKey: "identity") }, "no identity")
        assertRefused(bound { o in o["runner"] = ["endpoint_version": 1] }, "endpoint_version is not 2")
    }

    func testBoundGeometryAndOrientationMustBeFresh() {
        assertRefused(bound { self.identity(&$0, "after", "orientation", "LANDSCAPE") }, "changed during the snapshot")
        assertRefused(bound { self.identity(&$0, "before", "orientation", "LANDSCAPE"); self.identity(&$0, "after", "orientation", "LANDSCAPE") },
                      "orientation is not the one read around")
        assertRefused(bound(), "orientation", orientation: "LANDSCAPE")
        assertRefused(bound { $0["window"] = ["width": 844, "height": 390] }, "window")
    }

    func testObservationWithoutScreenshotDecodes() throws {
        var o = try JSONSerialization.jsonObject(with: envelope(compact: bound())) as! [String: Any]
        XCTAssertNil(o["screenshot_png_b64"])
        o["screenshot_captured"] = false
        XCTAssertNoThrow(try WDAObservation.fromUnifiedObserveJSON(JSONSerialization.data(withJSONObject: o), observer: .compact))
        XCTAssertNoThrow(try WDAObservation.fromUnifiedObserveJSON(envelope(xml: xml()), observer: .xml))
    }
}

final class ModelTimingTests: XCTestCase {
    func testNestedUsageIsFlattenedFromReportedValuesOnly() {
        let u = ResponsesClient.usage(["input_tokens": 900, "output_tokens": 40, "total_tokens": 940,
                                       "output_tokens_details": ["reasoning_tokens": 12], "input_tokens_details": ["cached_tokens": 512]])
        XCTAssertEqual(u, ["input_tokens": 900, "output_tokens": 40, "total_tokens": 940, "reasoning_tokens": 12, "cached_input_tokens": 512])
        XCTAssertEqual(ResponsesClient.usage(["input_tokens": 5]), ["input_tokens": 5], "nothing invented when absent")
    }

    func testTimingSummaryShowsTokensAndEffectiveTier() {
        var t = StepTiming(step: 1, observeMs: 10, requestBytes: 100, candidates: 3, tappable: 1, omitted: 0, folded: 0)
        XCTAssertFalse(t.summary.contains("tier"))
        t.serverOutputTokens = 40; t.serverReasoningTokens = 12; t.tierRequested = "fast"
        XCTAssertTrue(t.summary.contains("output 40 (reasoning 12)"), t.summary)
        XCTAssertTrue(t.summary.contains("tier requested fast, confirmed no"), t.summary)
        t.tierConfirmed = "priority"
        XCTAssertTrue(t.summary.contains("confirmed priority"), t.summary)
    }
}
