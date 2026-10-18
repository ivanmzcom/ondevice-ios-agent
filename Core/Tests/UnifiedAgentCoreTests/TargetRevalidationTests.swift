import XCTest
@testable import UnifiedAgentCore

// Pre-action targeted revalidation: identity/geometry/duplicate/missing refusals send no tap, a failed request is
// not repeated and never becomes a full observation, and a verified tap takes one full observation fewer.

private let trBundle = "com.apple.Preferences"
private let trPID = 4242
private let trWindow = WDASize(width: 390, height: 844)

private func cell(_ label: String, y: Double) -> UIElementSnapshot {
    UIElementSnapshot(type: "XCUIElementTypeCell", identifier: label, label: label, frame: WDARect(x: 0, y: y, width: 390, height: 44))
}

private func dg(_ c: Character) -> String { "s1:" + String(repeating: c, count: 64) }
private let preTap = dg("a")

private func boundObs(_ elements: [UIElementSnapshot], digest: String = "c1:a", pid: Int = trPID, at: Date = Date(),
                      runnerDigest: String? = dg("0")) -> WDAObservation {
    let root = UIElementSnapshot(type: "XCUIElementTypeApplication", identifier: "Settings", label: "Settings",
                                 frame: WDARect(x: 0, y: 0, width: 390, height: 844))
    var o = WDAObservation(bundleID: trBundle, windowSize: trWindow, elements: [root] + elements, sourceDigest: digest, capturedAt: at)
    o.provenance = WDACompactProvenance(schema: "hermes-observation/2", endpointVersion: 2, wdaVersion: nil, runnerBundleID: nil,
                                        observationID: "o", appPID: pid, nodeCount: elements.count + 1, maxDepthSeen: 2,
                                        snapshotMaxDepth: 50, lossyStrings: 0, nonFiniteRects: 0, snapshotMs: 0,
                                        runnerDigest: runnerDigest)
    return o
}

private func match(_ e: UIElementSnapshot) -> [String: Any] {
    var m: [String: Any] = ["type": e.type, "enabled": e.enabled, "visible": e.visible,
                            "rect": [e.frame.x, e.frame.y, e.frame.width, e.frame.height]]
    m["name"] = e.identifier; m["label"] = e.label; m["value"] = e.value
    return m
}

private func answer(_ matches: [UIElementSnapshot], count: Int? = nil, bundle: String = trBundle, pid: Int = trPID,
                    orientation: String = "PORTRAIT", afterPID: Int? = nil, state: Int = 4,
                    screenDigest: String? = preTap) -> String {
    func side(_ p: Int) -> [String: Any] { ["bundle_id": bundle, "pid": p, "orientation": orientation, "expected_state": state] }
    let n = count ?? matches.count
    let t: [String: Any] = [
        "schema": "hermes-target/1", "runner": ["endpoint": "hermes/target", "endpoint_version": 3],
        "identity": ["expected_bundle_id": trBundle, "before": side(pid), "after": side(afterPID ?? pid), "stable": true, "refused": NSNull()],
        "app": ["bundle_id": bundle, "pid": pid, "root_pid": pid], "window": ["width": 390, "height": 844],
        "orientation": orientation, "max_matches": 2, "match_count": n, "truncated": n > matches.count,
        "matches": matches.map(match), "keyboards": [], "nodes_walked": 40, "screen_digest": screenDigest ?? NSNull(),
        "timings_ms": ["clock": "monotonic_uptime_raw", "snapshot": 1800.5, "match": 1.2, "total": 1810.0],
    ]
    let env: [String: Any] = ["stage": "revalidate_target", "target_read": ["elapsed_ms": 1900], "target": t]
    return String(data: try! JSONSerialization.data(withJSONObject: env), encoding: .utf8)!
}

private final class TRRevalidator: WDATargetRevalidator {
    var answers: [Result<String, Error>]; var requests: [String] = []
    init(_ a: [Result<String, Error>]) { answers = a }
    func revalidateTarget(requestJSON: String) async throws -> String {
        requests.append(requestJSON)
        return try (answers.count > 1 ? answers.removeFirst() : answers[0]).get()
    }
}

private final class TRProvider: WDAObservationProvider {
    var queue: [() -> WDAObservation]; var calls = 0
    init(_ q: [() -> WDAObservation]) { queue = q }
    func observe(targetBundleID: String) async throws -> WDAObservation {
        calls += 1
        return queue.count > 1 ? queue.removeFirst()() : queue[0]()
    }
}

private final class TRTapper: WDATapSink {
    var taps: [WDAPoint] = []
    func tap(at point: WDAPoint, window: WDASize) async throws { taps.append(point) }
}

private struct TRTimeout: LocalizedError { var errorDescription: String? { "wda_target_deadline" } }

@MainActor private final class TRModel: ChatModel {
    var replies: [String]; let model = "fake-model"
    init(_ r: [String]) { replies = r }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        ChatResult(text: replies.isEmpty ? "THINK: x\nDO: fail out of replies" : replies.removeFirst(), firstToken: nil, total: 0)
    }
}

@MainActor final class TargetRevalidationTests: XCTestCase {
    let general = cell("General", y: 100), access = cell("Accessibility", y: 200)
    lazy var decided = boundObs([general, access])
    lazy var after = boundObs([cell("About", y: 100)], digest: "c1:b", at: Date().addingTimeInterval(5), runnerDigest: dg("b"))

    private func ref(_ e: UIElementSnapshot, in o: WDAObservation) -> TargetRef {
        TargetRef(elementIndex: o.elements.firstIndex(of: e)!, in: o)!
    }

    private func run(_ answers: [Result<String, Error>], target e: UIElementSnapshot? = nil, obs: WDAObservation? = nil,
                     after a: WDAObservation? = nil) async -> (WDATapStepReport, TRRevalidator, TRProvider, TRTapper) {
        let o = obs ?? decided, r = ref(e ?? general, in: o)
        let afterObs = a ?? after
        let v = TRRevalidator(answers), p = TRProvider([{ afterObs }]), t = TRTapper()
        guard case .success(let req) = WDATargetCheck.request(ref: r, observation: o, bound: trBundle) else { fatalError() }
        let rep = await WDATargetedTapStep(bundleID: trBundle, revalidator: v, provider: p, tapper: t)
            .run(tap: r, decidedOn: o, request: req, expect: .sourceChanged)
        return (rep, v, p, t)
    }

    func testUnchangedTargetTapsOnceAndVerifiesOnOneFullObservation() async {
        let (rep, v, p, t) = await run([.success(answer([general]))])
        XCTAssertEqual(rep.outcome, .verified)
        XCTAssertEqual(rep.preAct, .targeted)
        XCTAssertEqual(v.requests.count, 1)
        XCTAssertEqual(p.calls, 1, "only the post-tap verification is a full observation")
        XCTAssertEqual(t.taps, [WDAPoint(x: 195, y: 122)])
        XCTAssertEqual(rep.revalidation?.runnerMs["snapshot"], 1800.5)
        XCTAssertEqual(rep.revalidation?.elapsedMs, 1900)
    }

    /// Regression: the screen changed during inference (decided -> pre-tap), the tap did nothing (post == pre-tap).
    /// Compared with the old decided observation it would look "changed"; against the fresh baseline it is not.
    func testUnrelatedPreActChangeWithNoEffectTapIsNeverVerified() async {
        let noEffect = boundObs([general, access, cell("Banner", y: 400)], digest: "c1:changed-during-inference",
                                at: Date().addingTimeInterval(5), runnerDigest: preTap)
        XCTAssertNotEqual(noEffect.sourceDigest, decided.sourceDigest, "differs from the decided observation")
        let (rep, _, p, t) = await run([.success(answer([general]))], after: noEffect)
        XCTAssertEqual(t.taps.count, 1)
        XCTAssertEqual(p.calls, 1)
        guard case .notVerified(let why) = rep.outcome else { return XCTFail("\(rep.outcome)") }
        XCTAssertTrue(why.contains("did not change"), why)
    }

    func testRealPostTapChangeIsVerifiedAgainstFreshBaseline() async {
        let changed = boundObs([cell("About", y: 100)], digest: "c1:b", at: Date().addingTimeInterval(5), runnerDigest: dg("c"))
        let (rep, _, _, _) = await run([.success(answer([general], screenDigest: dg("b")))], after: changed)
        XCTAssertEqual(rep.outcome, .verified)
        XCTAssertEqual(rep.revalidation?.baselineDigest, dg("b"))
    }

    func testPostTapObservationWithoutRunnerDigestIsIndeterminate() async {
        let noDigest = boundObs([cell("About", y: 100)], digest: "c1:b", at: Date().addingTimeInterval(5), runnerDigest: nil)
        let (rep, _, _, t) = await run([.success(answer([general]))], after: noDigest)
        XCTAssertEqual(t.taps.count, 1)
        guard case .notVerified(let why) = rep.outcome else { return XCTFail("\(rep.outcome)") }
        XCTAssertTrue(why.hasPrefix("verification indeterminate"), why)
    }

    func testAnswerWithoutBaselineDigestSendsNoTap() async {
        for d in [nil, "c1:abc", "s1:" + String(repeating: "A", count: 64)] as [String?] {
            let (rep, _, p, t) = await run([.success(answer([general], screenDigest: d))])
            guard case .observationFailed = rep.outcome else { return XCTFail("\(rep.outcome)") }
            XCTAssertEqual(t.taps.count, 0); XCTAssertEqual(p.calls, 0)
        }
    }

    func testRequestCarriesExpectedIdentityAndOneExtraMatchSlot() throws {
        guard case .success(let s) = WDATargetCheck.request(ref: ref(general, in: decided), observation: decided, bound: trBundle) else {
            return XCTFail()
        }
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        XCTAssertEqual(o["expected_pid"] as? Int, trPID)
        XCTAssertEqual(o["expected_orientation"] as? String, "PORTRAIT")
        XCTAssertEqual(o["max_matches"] as? Int, 2)
        XCTAssertEqual(o["label"] as? String, "General")
    }

    func testChangedGeometryIsRefusedWithoutTap() async {
        let (rep, _, p, t) = await run([.success(answer([cell("General", y: 140)]))])
        guard case .selectionFailed(.targetChanged) = rep.outcome else { return XCTFail("\(rep.outcome)") }
        XCTAssertEqual(t.taps.count, 0); XCTAssertEqual(rep.taps, 0); XCTAssertEqual(p.calls, 0)
    }

    func testChangedValueIsRefused() async {
        var g = general; g.value = "1"
        let (rep, _, _, t) = await run([.success(answer([g]))])
        guard case .selectionFailed(.targetChanged) = rep.outcome else { return XCTFail("\(rep.outcome)") }
        XCTAssertEqual(t.taps.count, 0)
    }

    func testDuplicateTargetIsAmbiguousWithoutTap() async {
        let (rep, _, _, t) = await run([.success(answer([general, cell("General", y: 300)]))])
        XCTAssertEqual(rep.outcome, .selectionFailed(.ambiguous(2)))
        XCTAssertEqual(t.taps.count, 0)
        let (rep2, _, _, t2) = await run([.success(answer([general], count: 3))])  // truncated by the runner
        XCTAssertEqual(rep2.outcome, .selectionFailed(.ambiguous(3)))
        XCTAssertEqual(t2.taps.count, 0)
    }

    func testMissingTargetIsNotFoundWithoutTap() async {
        let (rep, _, _, t) = await run([.success(answer([]))])
        XCTAssertEqual(rep.outcome, .selectionFailed(.notFound))
        XCTAssertEqual(t.taps.count, 0)
    }

    func testWrongForegroundProcessOrientationAreRefusedWithoutTap() async {
        for a in [answer([general], bundle: "com.other.app"), answer([general], pid: 999), answer([general], afterPID: 999),
                  answer([general], orientation: "LANDSCAPE"), answer([general], state: 3)] {
            let (rep, _, p, t) = await run([.success(a)])
            guard case .observationFailed(let m) = rep.outcome else { return XCTFail("\(rep.outcome)") }
            XCTAssertTrue(m.hasPrefix("target revalidation:"), m)
            XCTAssertEqual(t.taps.count, 0); XCTAssertEqual(p.calls, 0)
        }
    }

    func testTimeoutOrStaleSessionIsNotRepeatedAndSendsNothing() async {
        let (rep, v, p, t) = await run([.failure(TRTimeout()), .success(answer([general]))])
        XCTAssertEqual(rep.outcome, .observationFailed("target revalidation: wda_target_deadline"))
        XCTAssertEqual(v.requests.count, 1, "never repeated")
        XCTAssertEqual(p.calls, 0, "never replaced by a full observation in this step")
        XCTAssertEqual(t.taps.count, 0)
    }

    func testStepIsSingleUse() async {
        let r = ref(general, in: decided)
        let v = TRRevalidator([.failure(TRTimeout())]), t = TRTapper()
        let step = WDATargetedTapStep(bundleID: trBundle, revalidator: v, provider: TRProvider([{ self.after }]), tapper: t)
        _ = await step.run(tap: r, decidedOn: decided, request: "{}", expect: .sourceChanged)
        let second = await step.run(tap: r, decidedOn: decided, request: "{}", expect: .sourceChanged)
        XCTAssertEqual(second.outcome, .alreadyConsumed)
        XCTAssertEqual(v.requests.count, 1)
    }

    func testUnboundObservationKeepsFullPath() {
        var o = decided; o.provenance = nil
        guard case .failure = WDATargetCheck.request(ref: ref(general, in: o), observation: o, bound: trBundle) else { return XCTFail() }
    }

    // MARK: TaskAgent

    private func tapReply(_ label: String, in o: WDAObservation) -> String {
        let i = ElementPrompt.candidates(o).firstIndex { $0.element.label == label }!
        return "THINK: open\nDO: tap \(i)"
    }

    func testAgentTargetedTapSkipsTheFullPreActObservation() async {
        let p = TRProvider([{ self.decided }, { self.after }]), t = TRTapper()
        let a = TaskAgent(provider: p, model: TRModel([tapReply("General", in: decided), "THINK: ok\nDO: done ok"]),
                          tapper: t, policy: GatePolicy())
        let v = TRRevalidator([.success(answer([general]))])
        a.targetRevalidator = v
        let out = await a.run(task: "open General", bundleID: trBundle, mode: .live)
        XCTAssertEqual(out, "done: ok")
        XCTAssertEqual(p.calls, 2, "first observation + post-tap verification; no pre-act full observation")
        XCTAssertEqual(t.taps.count, 1); XCTAssertEqual(v.requests.count, 1)
        XCTAssertEqual(a.timings.first?.preActPath, "targeted")
        XCTAssertEqual(a.timings.first?.preActFullObservations, 0)
    }

    func testAgentWithoutRevalidatorUsesFullPreAct() async {
        let p = TRProvider([{ self.decided }, { self.decided }, { self.after }]), t = TRTapper()
        let a = TaskAgent(provider: p, model: TRModel([tapReply("General", in: decided), "THINK: ok\nDO: done ok"]),
                          tapper: t, policy: GatePolicy())
        _ = await a.run(task: "open General", bundleID: trBundle, mode: .live)
        XCTAssertEqual(p.calls, 3)
        XCTAssertEqual(a.timings.first?.preActPath, "full")
        XCTAssertEqual(a.timings.first?.preActFullObservations, 1)
    }

    func testAgentChangedTargetSendsNothingAndReobservesForTheNextDecision() async {
        let p = TRProvider([{ self.decided }]), t = TRTapper()
        let a = TaskAgent(provider: p, model: TRModel([tapReply("General", in: decided), "THINK: stop\nDO: fail changed"]),
                          tapper: t, policy: GatePolicy())
        a.targetRevalidator = TRRevalidator([.success(answer([cell("General", y: 160)]))])
        let out = await a.run(task: "open General", bundleID: trBundle, mode: .live)
        XCTAssertEqual(out, "model stopped: changed")
        XCTAssertEqual(t.taps.count, 0)
        XCTAssertEqual(p.calls, 2, "a full observation for the next decision, after the refusal")
    }
}
