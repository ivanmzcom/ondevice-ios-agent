import Foundation

/// The last observe/open failure, reduced to fixed tokens so it survives a session drop or close and can be shown and
/// selected (ERROR_DETAIL_REPORT.md). Built from Rust's `{stage, detail}` JSON. `detail` itself is never stored (it may
/// echo WDA answers, URLs, element text): only a reason code from a fixed table, an HTTP status, expected/actual
/// protocol tokens that match strict patterns, and numeric/boolean/token `source_read` fields from a fixed key list.
public struct FailureDetail: Codable, Equatable, Sendable {
    public var unixMs: Int64
    public var operation: String
    public var code: Int32
    public var stage: String
    public var reason: String
    public var httpStatus: Int?
    public var expected: String?
    public var actual: String?
    public var sourceRead: [String: String]
    /// Set when the session was dropped or closed after this failure (the failure is kept).
    public var sessionDropped = false

    /// `source_read` keys Rust writes (session.rs `observe_bound_in`/`source_in`); anything else is dropped.
    public static let sourceReadKeys: Set<String> = ["route", "observer", "endpoint_version", "deadline_ms", "elapsed_ms",
                                                     "after_source_failure", "wda_requests", "screenshot"]

    public static func from(code: Int32, json: String, operation: String, nowMs: Int64) -> FailureDetail {
        let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let detail = o?["detail"] as? String ?? ""
        var message = detail
        var read: [String: Any] = [:]
        if let r = detail.range(of: "; source_read=", options: .backwards) {
            message = String(detail[..<r.lowerBound])
            read = (try? JSONSerialization.jsonObject(with: Data(detail[r.upperBound...].utf8))) as? [String: Any] ?? [:]
        }
        var f = FailureDetail(unixMs: nowMs, operation: token(operation, max: 32) ?? "unknown", code: code,
                              stage: token(o?["stage"] as? String ?? "", max: 64) ?? "unknown", reason: "unclassified",
                              httpStatus: nil, expected: nil, actual: nil, sourceRead: [:])
        f.classify(message)
        for (k, v) in read where sourceReadKeys.contains(k) {
            if let s = value(v) { f.sourceRead[k] = s }
        }
        return f
    }

    /// Fixed `[a-z0-9_]` token or nil.
    static func token(_ s: String, max: Int) -> String? {
        guard (1...max).contains(s.count),
              s.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }) else { return nil }
        return s
    }

    private static func value(_ v: Any) -> String? {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            guard d.isFinite, abs(d) < 1e12 else { return nil }
            return d == d.rounded() ? String(Int64(d)) : String(d)
        }
        if let s = v as? String { return token(s, max: 32) }
        return nil
    }

    private static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }

    /// Phrases of `wda_apps.rs` `check_bound`/`check_compact` (fixed text, no runner data) and their reason codes.
    private static let phrases: [(String, String)] = [
        ("unknown identity refusal", "identity_refusal_unknown"),
        ("identity is not bound to the requested app", "identity_unbound"),
        ("runner did not mark the identity stable", "identity_not_stable"),
        ("orientation is not the one read after the snapshot", "orientation_mismatch"),
        ("no finite window from the snapshot", "window_missing"),
        ("bound observation without nodes", "nodes_empty"),
        ("compact observation without a nodes array", "nodes_missing"),
        ("malformed WDA HTTP response", "malformed_http"),
        ("no complete answer within", "deadline"),
        ("connect timed out", "connect_timeout"),
        ("unknown command", "route_missing"),
        ("invalid session id", "invalid_session"),
        ("404 of unrecognized kind", "http_404_unrecognized"),
    ]

    private mutating func classify(_ m: String) {
        httpStatus = Self.groups(#"status=(\d{3})\)"#, m).flatMap { Int($0[0]) } ?? Self.groups(#"HTTP (\d{3})"#, m).flatMap { Int($0[0]) }
        if m.contains("bound observation schema") || m.contains("compact observation schema") {
            reason = m.contains("bound observation schema") ? "bound_schema_mismatch" : "compact_schema_mismatch"
            expected = Self.groups(#"expected (hermes-observation/\d{1,3})$"#, m)?[0]
            actual = Self.groups(#"schema Some\("(hermes-observation/\d{1,3})"\)"#, m)?[0] ?? (m.contains("schema None") ? "none" : "other")
        } else if let g = Self.groups(#"^identity_refused reason=([a-z0-9_]{1,64}) expected=([a-z0-9_]{1,32}) actual=([a-z0-9_]{1,32})$"#, m), g.count == 3 {
            // `wda_apps.rs` `identity_detail`: the runner/client refusal token and safe state enums only.
            reason = g[0]
            expected = g[1]
            actual = g[2]
        } else if m.contains("runner endpoint_version") {
            reason = "endpoint_version_mismatch"
            expected = Self.groups(#"needs (\d{1,6})$"#, m)?[0]
            actual = Self.groups(#"endpoint_version Some\((\d{1,6})\)"#, m)?[0] ?? (m.contains("endpoint_version None") ? "none" : "other")
        } else if let g = Self.groups(#"identity\.(before|after) without (bundle_id|pid|orientation)"#, m), g.count == 2 {
            reason = "identity_field_missing"
            actual = "\(g[0]).\(g[1]) absent"
        } else if Self.groups(#"no identity\.(before|after)$"#, m) != nil || m.hasSuffix("no identity") {
            reason = "identity_missing"
        } else if m.hasSuffix("no app") {
            reason = "app_missing"
        } else if let p = Self.phrases.first(where: { m.contains($0.0) }) {
            reason = p.1
        } else if httpStatus != nil {
            reason = "runner_http_error"
        }
    }

    /// Selectable multi-line text; only the fields above.
    public var text: String {
        let at = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(unixMs) / 1000))
        var lines = ["\(at) \(operation)", "ffi.\(code).\(stage)", "reason: \(reason)"]
        if let h = httpStatus { lines.append("http_status: \(h)") }
        if let e = expected { lines.append("expected: \(e)") }
        if let a = actual { lines.append("actual: \(a)") }
        if !sourceRead.isEmpty { lines.append("source_read: " + sourceRead.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
        lines.append(sessionDropped ? "session: dropped/closed after this failure" : "session: not dropped since")
        return lines.joined(separator: "\n")
    }
}

/// Persists the one last `FailureDetail` independently of any WDA session.
public struct FailureDetailStore {
    public static let key = "lastFailureDetail"
    let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> FailureDetail? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(FailureDetail.self, from: $0) }
    }
    public func save(_ f: FailureDetail) { defaults.set(try? JSONEncoder().encode(f), forKey: Self.key) }
    public func clear() { defaults.removeObject(forKey: Self.key) }
}
