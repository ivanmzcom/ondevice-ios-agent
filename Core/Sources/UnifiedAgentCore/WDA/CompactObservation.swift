import Foundation

/// Which read serves observations, chosen by the operator (Avanzado). `xml` is the baseline `/source` and the default;
/// `compact` is the Hermes-patched runner's `GET /session/{id}/hermes/observation` (COMPACT_RUNNER_REPORT.md).
/// Never switched automatically: with `compact` an unavailable route or a bad answer fails the observation.
public enum WDAObserver: String, CaseIterable, Sendable {
    case xml, compact

    public static let defaultsKey = "wdaObserver"
    public static let defaultObserver: WDAObserver = .xml

    public var title: String {
        switch self {
        case .xml: return "XML /source (base)"
        case .compact: return "Compacto runner Hermes (experimental)"
        }
    }

    /// The stored choice; anything missing or unknown is the XML baseline.
    public static func stored(_ raw: String?) -> WDAObserver { raw.flatMap(WDAObserver.init(rawValue:)) ?? defaultObserver }

    /// The source config to send at open. `xml` leaves it byte-for-byte unchanged; `compact` adds `"observer":"compact"`
    /// (a config that is not a JSON object is passed through so Rust refuses it).
    public func apply(to config: String) -> String {
        guard self == .compact,
              var o = (try? JSONSerialization.jsonObject(with: Data(config.utf8))) as? [String: Any] else { return config }
        o["observer"] = rawValue
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return config }
        return s
    }

    /// The configure readback must confirm this observer (`uni_session_configure_source` answers `observer`).
    /// An XML choice also accepts a readback without the key; a compact choice never does.
    public func confirmed(byReadback readback: String) -> Bool {
        let o = (try? JSONSerialization.jsonObject(with: Data(readback.utf8))) as? [String: Any]
        switch (self, o?["observer"] as? String) {
        case (.compact, "compact"), (.xml, "xml"), (.xml, nil): return true
        default: return false
        }
    }
}

/// What a compact observation says about where it came from (diagnostics; never element text).
public struct WDACompactProvenance: Equatable, Sendable {
    public var schema: String
    public var endpointVersion: Int
    public var wdaVersion: String?
    public var runnerBundleID: String?
    public var observationID: String
    public var appPID: Int
    public var nodeCount: Int
    public var maxDepthSeen: Int
    public var snapshotMaxDepth: Int
    public var lossyStrings: Int
    public var nonFiniteRects: Int
    public var snapshotMs: Int
    /// Runner `screen_digest` ("s1:" + SHA-256 hex) of this snapshot walk; nil from runners without it or when
    /// truncated. Only comparable with another runner digest (`WDATargetedTapStep` verification).
    public var runnerDigest: String? = nil
}

/// Decoder for the runner's `hermes-observation/1` projection: a flat pre-order node list built straight from one
/// XCTest snapshot (no XML anywhere). Produces the same `UIElementSnapshot` list the XML parser does for the same tree.
/// Every structural problem is an error: nothing is skipped silently except nodes the runner itself marked with a
/// null (non-finite) rect, which are counted in `nonfinite_rects` and in the provenance (XML drops frameless nodes too).
public enum WDACompactSource {
    public static let schema = "hermes-observation/1"
    public static let endpointVersion = 1
    /// The bound read (`?bind=1`): the runner reads bundle, pid and orientation before and after its snapshot.
    public static let boundSchema = "hermes-observation/2"
    public static let boundEndpointVersion = 2

    public struct Decoded: Equatable, Sendable {
        public var elements: [UIElementSnapshot]
        public var digest: String
        public var provenance: WDACompactProvenance
    }

    static func fail(_ m: String) -> ObservationDecodeError { ObservationDecodeError(message: "source_compact: \(m)") }

    /// `expectedBundleID`: the app the observation is bound to (selected app, or `activeAppInfo`'s bundle).
    /// `expectedPID`: `activeAppInfo`'s pid when known. `window`/`orientation`: the separate reads of the same
    /// observation; the projection must agree with both or the screen changed under us.
    public static func decode(_ o: [String: Any], expectedBundleID: String, expectedPID: Int?, window: WDASize,
                              orientation: String) throws -> Decoded {
        func num(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        }
        func int(_ v: Any?) -> Int? { num(v).flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil } }
        func bool(_ v: Any?) -> Bool? {
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        }

        let version: Int
        switch o["schema"] as? String {
        case schema?: version = endpointVersion
        case boundSchema?: version = boundEndpointVersion
        default: throw fail("schema \(o["schema"] ?? "missing"), expected \(schema) or \(boundSchema)")
        }
        guard let runner = o["runner"] as? [String: Any], int(runner["endpoint_version"]) == version else {
            throw fail("runner endpoint_version is not \(version)")
        }
        guard let observationID = o["observation_id"] as? String, !observationID.isEmpty else { throw fail("no observation_id") }
        guard let truncated = bool(o["truncated"]) else { throw fail("no truncated flag") }
        if truncated {
            let t = o["truncation"] as? [String: Any]
            throw fail("truncated by the runner (\(t?["reason"] as? String ?? "?"), \(int(t?["pending_subtrees"]) ?? -1) subtrees pending)")
        }
        guard let limits = o["limits"] as? [String: Any], let snapshotMaxDepth = int(limits["snapshot_max_depth"]),
              let maxDepthSeen = int(o["max_depth_seen"]) else { throw fail("no depth limits") }
        // XCTest cuts the snapshot at snapshotMaxDepth without saying so; a tree that reaches it may be incomplete.
        if snapshotMaxDepth > 0 && maxDepthSeen + 1 >= snapshotMaxDepth {
            throw fail("tree reaches snapshot_max_depth \(snapshotMaxDepth); nodes below it may be missing")
        }

        guard let app = o["app"] as? [String: Any], let bundle = app["bundle_id"] as? String,
              let pid = int(app["pid"]), let rootPID = int(app["root_pid"]) else { throw fail("no app identity") }
        guard bundle == expectedBundleID else { throw fail("snapshot of \(bundle), observation bound to \(expectedBundleID)") }
        guard pid > 0, rootPID == pid else { throw fail("snapshot root pid \(rootPID) is not app pid \(pid)") }
        if let expectedPID, expectedPID != pid { throw fail("snapshot app pid \(pid), foreground pid \(expectedPID)") }
        if version == boundEndpointVersion {
            // Checked again here, not taken from the runner's `stable` flag or from Rust: before and after must be one
            // app, one process, one orientation, and the snapshot's own app.
            guard let id = o["identity"] as? [String: Any] else { throw fail("no identity") }
            if let r = id["refused"] as? String { throw fail("runner refused the observation: \(r)") }
            guard bool(id["stable"]) == true else { throw fail("identity not marked stable") }
            func side(_ k: String) throws -> (bundle: String, pid: Int, orientation: String) {
                guard let s = id[k] as? [String: Any], let b = s["bundle_id"] as? String, let p = int(s["pid"]),
                      let ori = s["orientation"] as? String else { throw fail("no identity.\(k)") }
                return (b, p, ori)
            }
            let before = try side("before"), after = try side("after")
            guard before == after else { throw fail("foreground app or orientation changed during the snapshot") }
            guard before.bundle == bundle, before.pid == pid else { throw fail("identity is not the snapshot's app") }
            guard before.orientation == orientation else { throw fail("orientation is not the one read around the snapshot") }
        }

        guard let w = o["window"] as? [String: Any], let ww = num(w["width"]), let wh = num(w["height"]) else {
            throw fail("no window")
        }
        guard ww == window.width, wh == window.height else {
            throw fail("window \(ww)x\(wh) differs from the observation's \(window.width)x\(window.height)")
        }
        guard let ori = o["orientation"] as? String, ori == orientation else {
            throw fail("orientation \(o["orientation"] ?? "null") differs from the observation's \(orientation)")
        }

        guard let nodes = o["nodes"] as? [[String: Any]] else { throw fail("no nodes array") }
        guard let nodeCount = int(o["node_count"]), nodeCount == nodes.count, !nodes.isEmpty else {
            throw fail("node_count does not match \(nodes.count) nodes")
        }
        guard let nonFinite = int(o["nonfinite_rects"]), let lossy = int(o["lossy_strings"]) else {
            throw fail("no nonfinite_rects/lossy_strings counters")
        }

        var elements: [UIElementSnapshot] = []
        var skipped = 0
        var canonical = "c1|\(window.width)x\(window.height)|\(orientation)|\(bundle)\n"
        for (index, n) in nodes.enumerated() {
            guard let id = int(n["id"]), id == index else { throw fail("node \(index): id is not its position (duplicate or reordered)") }
            guard let parent = int(n["parent"]), index == 0 ? parent == -1 : (0 <= parent && parent < index) else {
                throw fail("node \(index): bad parent")
            }
            guard let type = n["type"] as? String, !type.isEmpty else { throw fail("node \(index): no type") }
            if index == 0 && type != "XCUIElementTypeApplication" { throw fail("root is \(type), not the application") }
            guard let enabled = bool(n["enabled"]), let visible = bool(n["visible"]) else {
                throw fail("node \(index): no enabled/visible")
            }
            var strings: [String?] = []
            for key in ["name", "label", "value"] {
                switch n[key] {
                case nil: strings.append(nil)
                case let s as String: strings.append(s)
                default: throw fail("node \(index): \(key) is not a string")
                }
            }
            if n["rect"] is NSNull { skipped += 1; continue }
            guard let r = n["rect"] as? [Any], r.count == 4, let x = num(r[0]), let y = num(r[1]), let rw = num(r[2]),
                  let rh = num(r[3]), [x, y, rw, rh].allSatisfy(\.isFinite), rw >= 0, rh >= 0 else {
                throw fail("node \(index): bad rect")
            }
            let e = UIElementSnapshot(type: type, identifier: strings[0], label: strings[1], value: strings[2],
                                      frame: WDARect(x: x, y: y, width: rw, height: rh), enabled: enabled, visible: visible)
            elements.append(e)
            canonical += "\(index)|\(parent)|\(type)|\(Self.field(e.identifier))|\(Self.field(e.label))|\(Self.field(e.value))|"
            canonical += "\(enabled ? 1 : 0)\(visible ? 1 : 0)|\(x),\(y),\(rw),\(rh)\n"
        }
        guard skipped == nonFinite else { throw fail("\(skipped) null rects, runner reported \(nonFinite)") }

        let started = int(o["snapshot_started_unix_ms"]) ?? 0, finished = int(o["snapshot_finished_unix_ms"]) ?? 0
        let provenance = WDACompactProvenance(
            schema: version == boundEndpointVersion ? boundSchema : schema, endpointVersion: version, wdaVersion: runner["wda_version"] as? String,
            runnerBundleID: runner["runner_bundle_id"] as? String, observationID: observationID, appPID: pid,
            nodeCount: nodes.count, maxDepthSeen: maxDepthSeen, snapshotMaxDepth: snapshotMaxDepth,
            lossyStrings: lossy, nonFiniteRects: nonFinite, snapshotMs: max(0, finished - started),
            runnerDigest: (o["screen_digest"] as? String).flatMap { WDATargetCheck.isScreenDigest($0) ? $0 : nil })
        // Content only (not observation_id or times): an unchanged screen keeps its digest, as with XML, so the
        // "screen did not change" check and the same-observation target binding keep their meaning.
        return Decoded(elements: elements, digest: "c1:" + WDASource.digest(canonical), provenance: provenance)
    }

    /// Length-prefixed so separators inside text can never make two different nodes canonicalize alike.
    static func field(_ s: String?) -> String { s.map { "\($0.utf8.count):\($0)" } ?? "-" }
}
