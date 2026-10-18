import XCTest
@testable import UnifiedAgentCore

/// Synthetic `hermes-observation/1` payloads (no real apps' data) against the XML baseline: the compact decode must give
/// the same validated `WDAObservation` and keep every identity, orientation and target-binding check.
final class CompactObservationTests: XCTestCase {
    let bundle = "com.example.synthetic"

    /// One tree, written once as XML `/source` and once as the runner's pre-order nodes.
    let tree: [(type: String, name: String?, label: String?, value: String?, rect: [Double], enabled: Bool, visible: Bool, parent: Int)] = [
        ("Application", nil, "Synthetic", nil, [0, 0, 390, 844], true, true, -1),
        ("NavigationBar", "Chats", nil, nil, [0, 47, 390, 44], true, true, 0),
        ("StaticText", nil, "Chats", nil, [170, 58, 50, 22], true, true, 1),
        ("Button", "compose", "New chat", nil, [340, 52, 44, 34], true, true, 1),
        ("Cell", nil, "Test Contact, hello", nil, [0, 200, 390, 72], true, true, 0),
        ("StaticText", nil, "Test Contact", nil, [70, 210, 200, 20], true, true, 4),
        ("SearchField", nil, "Search", "", [10, 100, 370, 36], true, true, 0),
        ("Button", nil, "Archived", nil, [0, 900, 390, 44], false, false, 0),
    ]

    func xml() -> String {
        func attr(_ k: String, _ v: String?) -> String { v.map { " \(k)=\"\($0)\"" } ?? "" }
        func open(_ i: Int) -> String {
            let n = tree[i]; let t = "XCUIElementType" + n.type
            let r = n.rect.map { $0.rounded() == $0 ? String(Int($0)) : String($0) }
            return "<\(t) type=\"\(t)\"\(attr("name", n.name))\(attr("label", n.label))\(attr("value", n.value)) enabled=\"\(n.enabled)\" visible=\"\(n.visible)\" x=\"\(r[0])\" y=\"\(r[1])\" width=\"\(r[2])\" height=\"\(r[3])\">"
        }
        func walk(_ i: Int) -> String {
            let kids = tree.indices.filter { tree[$0].parent == i }
            return open(i) + kids.map(walk).joined() + "</XCUIElementType\(tree[i].type)>"
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><AppiumAUT>\(walk(0))</AppiumAUT>"
    }

    func compact(id: String = "OBS-1", pid: Int = 42, nodeEdit: ((inout [[String: Any]]) -> Void)? = nil,
                 edit: ((inout [String: Any]) -> Void)? = nil) -> [String: Any] {
        var nodes: [[String: Any]] = tree.enumerated().map { i, n in
            var d: [String: Any] = ["id": i, "parent": n.parent, "depth": n.parent < 0 ? 0 : (n.parent == 0 ? 1 : 2),
                                    "type": "XCUIElementType" + n.type, "enabled": n.enabled, "visible": n.visible, "rect": n.rect]
            if let v = n.name { d["name"] = v }; if let v = n.label { d["label"] = v }; if let v = n.value { d["value"] = v }
            return d
        }
        nodeEdit?(&nodes)
        var o: [String: Any] = [
            "schema": "hermes-observation/1", "observation_id": id,
            "runner": ["endpoint": "hermes/observation", "endpoint_version": 1, "wda_version": "16.15.3", "runner_bundle_id": "synthetic.runner.xctrunner"],
            "app": ["bundle_id": bundle, "pid": pid, "root_pid": pid],
            "window": ["width": 390, "height": 844], "orientation": "PORTRAIT",
            "attributes": ["type", "name", "label", "value", "enabled", "visible", "rect"],
            "limits": ["max_nodes": 6000, "snapshot_max_depth": 50], "max_depth_seen": 2,
            "truncated": false, "node_count": nodes.count, "lossy_strings": 0, "nonfinite_rects": 0,
            "started_unix_ms": 1_000, "snapshot_started_unix_ms": 1_010, "snapshot_finished_unix_ms": 1_250, "finished_unix_ms": 1_260,
            "nodes": nodes,
        ]
        edit?(&o)
        return o
    }

    /// The `uni-observation/1` envelope Rust builds around either source (`observe_foreground_in` adds the pid).
    func envelope(xml: String? = nil, compact: [String: Any]? = nil, foregroundPID: Int? = 42,
                  orientation: String = "PORTRAIT") -> Data {
        var o: [String: Any] = ["schema": "uni-observation/1", "target_bundle_id": bundle, "app_state_before": 4, "app_state_after": 4,
                                "window_size": ["width": 390, "height": 844], "orientation": orientation, "source_unix_ms": 1_300]
        if let xml { o["source_xml"] = xml }
        if let compact { o["source_compact"] = compact }
        if let foregroundPID { o["foreground_pid"] = foregroundPID }
        return try! JSONSerialization.data(withJSONObject: o)
    }

    func decode(_ c: [String: Any], pid: Int? = 42, orientation: String = "PORTRAIT") throws -> WDAObservation {
        try WDAObservation.fromUnifiedObserveJSON(envelope(compact: c, foregroundPID: pid, orientation: orientation), observer: .compact)
    }

    func assertRefused(_ c: [String: Any], _ needle: String, pid: Int? = 42, orientation: String = "PORTRAIT",
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(c, pid: pid, orientation: orientation), file: file, line: line) { e in
            XCTAssertTrue("\(e.localizedDescription)".contains(needle), "\(e.localizedDescription)", file: file, line: line)
        }
    }

    // MARK: equivalence with the XML baseline

    func testCompactDecodesToTheSameElementsAsTheXMLParser() throws {
        let x = try WDAObservation.fromUnifiedObserveJSON(envelope(xml: xml()), observer: .xml)
        let c = try decode(compact())
        XCTAssertEqual(c.elements, x.elements, "type, name, label, value, frame, enabled and visible match node for node")
        XCTAssertEqual(c.elements.count, tree.count)
        XCTAssertEqual(c.elements[6].value, "", "an empty value stays empty, absent stays nil, as in XML")
        XCTAssertNil(c.elements[0].value)
        XCTAssertEqual([c.bundleID, c.orientation], [x.bundleID, x.orientation])
        XCTAssertEqual(c.windowSize, x.windowSize); XCTAssertEqual(c.capturedAt, x.capturedAt)
        XCTAssertTrue(c.foreground)
        XCTAssertNotEqual(c.sourceDigest, x.sourceDigest, "compact digests are their own namespace")
        XCTAssertTrue(c.sourceDigest.hasPrefix("c1:"))
        let p = try XCTUnwrap(c.provenance)
        XCTAssertEqual(p.observationID, "OBS-1"); XCTAssertEqual(p.wdaVersion, "16.15.3"); XCTAssertEqual(p.endpointVersion, 1)
        XCTAssertEqual(p.runnerBundleID, "synthetic.runner.xctrunner"); XCTAssertEqual(p.snapshotMs, 240); XCTAssertEqual(p.nodeCount, 8)
        XCTAssertNil(x.provenance)
    }

    func testSamePromptAndDryRunTapPlanAsXML() throws {
        let x = try WDAObservation.fromUnifiedObserveJSON(envelope(xml: xml()), observer: .xml)
        let c = try decode(compact())
        XCTAssertEqual(ElementPrompt.render(task: "t", observation: c, list: ElementPrompt.list(c), history: []),
                       ElementPrompt.render(task: "t", observation: x, list: ElementPrompt.list(x), history: []))
        let now = Date(timeIntervalSince1970: 1.3)
        let tc = try TargetSelection.select(TargetSelector(label: "New chat"), in: c).get()
        let tx = try TargetSelection.select(TargetSelector(label: "New chat"), in: x).get()
        let pc = try WDATapGate.evaluate(target: tc, observation: c, expectedBundleID: bundle, now: now).get()
        let px = try WDATapGate.evaluate(target: tx, observation: x, expectedBundleID: bundle, now: now).get()
        XCTAssertEqual(pc.point, px.point); XCTAssertEqual(pc.point, WDAPoint(x: 362, y: 69))
    }

    // MARK: identity and target binding

    func testDigestIsContentOnlyAndTargetsStayBoundToTheirObservation() throws {
        let a = try decode(compact(id: "OBS-1"))
        let same = try decode(compact(id: "OBS-2") { $0["snapshot_finished_unix_ms"] = 9_999 })
        XCTAssertEqual(a.sourceDigest, same.sourceDigest, "an unchanged screen keeps its digest (verify: screen did not change)")
        let changed = try decode(compact(id: "OBS-3", nodeEdit: { $0[3]["label"] = "New group" }))
        XCTAssertNotEqual(a.sourceDigest, changed.sourceDigest)
        let moved = try decode(compact(nodeEdit: { $0[3]["rect"] = [340, 60, 44, 34] }))
        XCTAssertNotEqual(a.sourceDigest, moved.sourceDigest)
        // a target picked on one observation is refused on another (no stale index or frame reuse)
        let t = try TargetSelection.select(TargetSelector(label: "Test Contact, hello"), in: a).get()
        guard case .failure(let b) = WDATapGate.evaluate(target: t, observation: changed, expectedBundleID: bundle,
                                                         now: Date(timeIntervalSince1970: 1.3)) else { return XCTFail() }
        XCTAssertTrue(b.reasons.contains(.targetFromOtherObservation))
    }

    func testFieldBoundariesCannotCollideInTheDigest() throws {
        let a = try decode(compact(nodeEdit: { $0[3]["name"] = "a|b"; $0[3]["label"] = "c" }))
        let b = try decode(compact(nodeEdit: { $0[3]["name"] = "a"; $0[3]["label"] = "b|c" }))
        XCTAssertNotEqual(a.sourceDigest, b.sourceDigest)
    }

    func testDuplicateLabelsStayAmbiguous() throws {
        let c = try decode(compact(nodeEdit: { n in
            n.append(["id": 8, "parent": 0, "depth": 1, "type": "XCUIElementTypeButton", "label": "New chat",
                      "enabled": true, "visible": true, "rect": [10, 600, 100, 44]])
        }) { $0["node_count"] = 9 })
        XCTAssertEqual(TargetSelection.select(TargetSelector(label: "New chat"), in: c), .failure(.ambiguous(2)))
    }

    func testForeignForegroundAndIdentityMismatchAreRefused() {
        assertRefused(compact { $0["app"] = ["bundle_id": "com.example.other", "pid": 42, "root_pid": 42] }, "observation bound to")
        assertRefused(compact(pid: 43), "foreground pid", pid: 42)
        assertRefused(compact { $0["app"] = ["bundle_id": self.bundle, "pid": 42, "root_pid": 7] }, "root pid")
        assertRefused(compact(nodeEdit: { $0[0]["type"] = "XCUIElementTypeWindow" }), "not the application")
        // selected-app mode has no foreground pid: bundle and root pid still bind it
        XCTAssertNoThrow(try decode(compact(), pid: nil))
    }

    func testOrientationAndWindowMustMatchTheSeparateReads() {
        assertRefused(compact(), "orientation", orientation: "LANDSCAPE")
        assertRefused(compact { $0["orientation"] = NSNull() }, "orientation")
        assertRefused(compact { $0["window"] = ["width": 844, "height": 390] }, "window")
    }

    // MARK: structural errors are never skipped

    func testDuplicateOrReorderedNodeIDsAreRefused() {
        assertRefused(compact(nodeEdit: { $0[3]["id"] = 2 }), "id is not its position")
        assertRefused(compact(nodeEdit: { $0.swapAt(2, 3) }), "id is not its position")
        assertRefused(compact(nodeEdit: { $0[3]["parent"] = 3 }), "bad parent")
        assertRefused(compact(nodeEdit: { $0[0]["parent"] = 0 }), "bad parent")
    }

    func testMissingOrMistypedFieldsAreRefused() {
        assertRefused(compact(nodeEdit: { $0[2].removeValue(forKey: "type") }), "no type")
        assertRefused(compact(nodeEdit: { $0[2].removeValue(forKey: "visible") }), "enabled/visible")
        assertRefused(compact(nodeEdit: { $0[2]["enabled"] = 1 }), "enabled/visible")
        assertRefused(compact(nodeEdit: { $0[2]["rect"] = [1, 2, 3] }), "bad rect")
        assertRefused(compact(nodeEdit: { $0[2]["rect"] = [1, 2, -3, 4] }), "bad rect")
        assertRefused(compact(nodeEdit: { $0[2]["label"] = 5 }), "label is not a string")
        assertRefused(compact { $0["node_count"] = 7 }, "node_count")
        assertRefused(compact { $0.removeValue(forKey: "observation_id") }, "observation_id")
        assertRefused(compact { $0.removeValue(forKey: "app") }, "app identity")
    }

    func testTruncationAndDepthLimitAreErrors() {
        assertRefused(compact { $0["truncated"] = true; $0["truncation"] = ["reason": "max_nodes", "pending_subtrees": 3] },
                      "truncated by the runner (max_nodes, 3 subtrees pending)")
        assertRefused(compact { $0.removeValue(forKey: "truncated") }, "truncated flag")
        assertRefused(compact { $0["max_depth_seen"] = 49 }, "snapshot_max_depth 50")
    }

    func testNonFiniteRectsAreCountedNotSilentlyLost() throws {
        let c = try decode(compact(nodeEdit: { $0[7]["rect"] = NSNull() }) { $0["nonfinite_rects"] = 1 })
        XCTAssertEqual(c.elements.count, 7); XCTAssertEqual(c.provenance?.nonFiniteRects, 1)
        assertRefused(compact(nodeEdit: { $0[7]["rect"] = NSNull() }), "null rects, runner reported 0")
    }

    func testLossyStringsAreReportedInProvenance() throws {
        let c = try decode(compact(nodeEdit: { $0[5]["lossy_strings"] = 1; $0[5]["label"] = "Test Contact ?" }) { $0["lossy_strings"] = 1 })
        XCTAssertEqual(c.provenance?.lossyStrings, 1)
    }

    func testSchemaAndRunnerVersionGates() {
        assertRefused(compact { $0["schema"] = "hermes-observation/3" }, "schema")
        // v2 is the bound read: a v2 schema from a runner that reports endpoint version 1 is refused
        assertRefused(compact { $0["schema"] = "hermes-observation/2" }, "endpoint_version is not 2")
        assertRefused(compact { $0["runner"] = ["endpoint_version": 2] }, "endpoint_version")
        assertRefused(compact { $0.removeValue(forKey: "runner") }, "endpoint_version")
    }

    // MARK: observer choice, never a silent fallback

    func testObserverMismatchIsRefusedBothWays() throws {
        XCTAssertThrowsError(try WDAObservation.fromUnifiedObserveJSON(envelope(xml: xml()), observer: .compact))
        XCTAssertThrowsError(try WDAObservation.fromUnifiedObserveJSON(envelope(compact: compact()), observer: .xml))
        XCTAssertThrowsError(try WDAObservation.fromUnifiedObserveJSON(envelope(xml: xml(), compact: compact())))
        // existing callers without an observer keep decoding XML exactly as before
        XCTAssertNoThrow(try WDAObservation.fromUnifiedObserveJSON(envelope(xml: xml())))
    }

    func testObserverConfigAndReadbackGate() {
        XCTAssertEqual(WDAObserver.stored(nil), .xml); XCTAssertEqual(WDAObserver.stored("bogus"), .xml)
        let combined = WDASourcePreset.combined.configJSON
        XCTAssertEqual(WDAObserver.xml.apply(to: combined), combined, "XML keeps the config byte for byte")
        let c = WDAObserver.compact.apply(to: combined)
        let o = (try? JSONSerialization.jsonObject(with: Data(c.utf8))) as? [String: Any]
        XCTAssertEqual(o?["observer"] as? String, "compact"); XCTAssertEqual(o?["source_deadline_s"] as? Int, 30)
        XCTAssertEqual(WDAObserver.compact.apply(to: "{}"), #"{"observer":"compact"}"#)
        XCTAssertTrue(WDAObserver.compact.confirmed(byReadback: #"{"observer":"compact","source_route":"compact"}"#))
        XCTAssertFalse(WDAObserver.compact.confirmed(byReadback: #"{"source_route":"direct"}"#), "an old native library cannot confirm it")
        XCTAssertFalse(WDAObserver.compact.confirmed(byReadback: #"{"observer":"xml"}"#))
        XCTAssertTrue(WDAObserver.xml.confirmed(byReadback: #"{"source_route":"direct"}"#))
        XCTAssertFalse(WDAObserver.xml.confirmed(byReadback: #"{"observer":"compact"}"#))
    }
}
