import Foundation

// Pre-action target revalidation (`POST /session/{id}/hermes/target`, runner endpoint version 3) instead of a second
// full observation between the model's decision and a tap. The runner reads app/pid/orientation before and after one
// snapshot and returns only the elements matching the chosen selector (plus keyboards), in observation order; this
// file checks all of it again against the observation the model decided on and refuses any difference. Taps only;
// typing and cross-app steps keep their full fresh observation (focus/foreground checks need the whole screen).

/// Sends exactly one revalidation request (request JSON in, the session's answer envelope out). Never retried; an
/// implementation never answers with a full observation instead.
public protocol WDATargetRevalidator: AnyObject {
    func revalidateTarget(requestJSON: String) async throws -> String
}

/// Which pre-action check a tap step used, and why when it was the full one.
public enum WDAPreActPath: Equatable, Sendable {
    case full(String)
    case targeted
    public var token: String { if case .targeted = self { return "targeted" }; return "full" }
}

/// Counts and runner-measured durations of one revalidation (no element text).
public struct WDATargetRevalidationInfo: Equatable, Sendable {
    public var matchCount: Int
    public var keyboards: Int
    public var nodesWalked: Int?
    /// Runner-measured monotonic stage durations (identity_before, snapshot, match, identity_after, total).
    public var runnerMs: [String: Double]
    /// Client wall time of the request as Rust measured it.
    public var elapsedMs: Int?
    /// Runner `screen_digest` of the fresh pre-tap snapshot: the post-tap verification baseline.
    public var baselineDigest: String = ""
}

/// Why a tap keeps the full pre-action observation (decided before anything is sent).
public struct WDAPreActUnsupported: Error, Equatable, Sendable { public var reason: String }

public enum WDATargetCheck {
    public static let schema = "hermes-target/1"
    public static let endpointVersion = 3
    public static let hardMaxMatches = 32

    /// "s1:" + 64 lowercase hex characters (runner `FBHermesScreenDigest`).
    public static func isScreenDigest(_ d: String) -> Bool {
        d.utf8.count == 67 && d.hasPrefix("s1:") && d.utf8.dropFirst(3).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The request for `ref` chosen on `obs`, or why this tap needs the full pre-action observation instead.
    public static func request(ref: TargetRef, observation obs: WDAObservation, bound: String) -> Result<String, WDAPreActUnsupported> {
        guard let p = obs.provenance, p.endpointVersion == WDACompactSource.boundEndpointVersion, p.appPID > 0 else {
            return .failure(WDAPreActUnsupported(reason: "observation is not a bound compact observation (no runner pid)"))
        }
        guard obs.bundleID == bound else { return .failure(WDAPreActUnsupported(reason: "observation is not of the bound app")) }
        guard WDAOrientation.known.contains(obs.orientation) else { return .failure(WDAPreActUnsupported(reason: "unknown orientation")) }
        guard ref.selector.identifier != nil || ref.selector.label != nil else { return .failure(WDAPreActUnsupported(reason: "empty selector")) }
        // One more than the observation had, so an added duplicate is seen (match_count is the total anyway).
        guard ref.matches.count < hardMaxMatches else { return .failure(WDAPreActUnsupported(reason: "too many same-selector elements")) }
        var o: [String: Any] = ["expected_bundle_id": bound, "expected_pid": p.appPID, "expected_orientation": obs.orientation,
                                "max_matches": ref.matches.count + 1]
        o["name"] = ref.selector.identifier ?? NSNull()
        o["label"] = ref.selector.label ?? NSNull()
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return .failure(WDAPreActUnsupported(reason: "request not encodable")) }
        return .success(s)
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// The answer is not a usable version-3 answer or its identity is not the observation's.
        case bad(String)
        /// The target is missing, duplicated or changed: refused before any tap.
        case selection(SelectionError)
    }

    /// The answer envelope checked against `obs`: on success a minimal observation holding only the matches and
    /// keyboards (fresh `capturedAt = now`), the target resolved on it exactly as on a full observation, and counts.
    public static func evaluate(answer json: String, ref: TargetRef, observation obs: WDAObservation, bound: String,
                                now: Date) -> Result<(WDAObservation, SelectedTarget, WDATargetRevalidationInfo), Refusal> {
        func bad(_ m: String) -> Result<(WDAObservation, SelectedTarget, WDATargetRevalidationInfo), Refusal> { .failure(.bad(m)) }
        func changed(_ m: String) -> Result<(WDAObservation, SelectedTarget, WDATargetRevalidationInfo), Refusal> {
            .failure(.selection(.targetChanged(m)))
        }
        func num(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        }
        func int(_ v: Any?) -> Int? { num(v).flatMap { $0.rounded() == $0 ? Int(exactly: $0) : nil } }
        func bool(_ v: Any?) -> Bool? {
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        }
        func rect(_ v: Any?) -> WDARect? {
            guard let r = v as? [Any], r.count == 4, let x = num(r[0]), let y = num(r[1]), let w = num(r[2]), let h = num(r[3]),
                  [x, y, w, h].allSatisfy(\.isFinite), w >= 0, h >= 0 else { return nil }
            return WDARect(x: x, y: y, width: w, height: h)
        }

        guard let env = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let o = env["target"] as? [String: Any] else { return bad("no target answer") }
        guard o["schema"] as? String == schema, let runner = o["runner"] as? [String: Any],
              int(runner["endpoint_version"]) == endpointVersion else { return bad("not a \(schema) v\(endpointVersion) answer") }
        guard let pid = obs.provenance?.appPID else { return bad("observation has no runner pid") }
        guard let baseline = o["screen_digest"] as? String, isScreenDigest(baseline) else {
            return bad("no screen_digest of the fresh snapshot (no verification baseline)")
        }

        // Identity, again here: one app, one process, one orientation, all the observation's, foreground both times.
        guard let id = o["identity"] as? [String: Any] else { return bad("no identity") }
        if let r = id["refused"] as? String { return bad("runner refused: \(r)") }
        guard bool(id["stable"]) == true else { return bad("identity not marked stable") }
        for k in ["before", "after"] {
            guard let s = id[k] as? [String: Any], s["bundle_id"] as? String == bound, int(s["pid"]) == pid,
                  s["orientation"] as? String == obs.orientation, int(s["expected_state"]) == WDAObservation.runningForeground else {
                return bad("identity.\(k) is not the observed app, process, orientation in the foreground")
            }
        }
        guard let app = o["app"] as? [String: Any], app["bundle_id"] as? String == bound, int(app["pid"]) == pid,
              int(app["root_pid"]) == pid else { return bad("snapshot is not of the observed process") }
        guard let w = o["window"] as? [String: Any], let ww = num(w["width"]), let wh = num(w["height"]) else { return bad("no window") }
        guard ww == obs.windowSize.width, wh == obs.windowSize.height, o["orientation"] as? String == obs.orientation else {
            return changed("window or orientation changed since the observation")
        }

        guard let matchCount = int(o["match_count"]), let truncated = bool(o["truncated"]),
              let raw = o["matches"] as? [[String: Any]], let rawKeys = o["keyboards"] as? [[String: Any]] else {
            return bad("no match counts")
        }
        guard truncated == (matchCount > raw.count) else { return bad("truncation flag disagrees with match_count") }
        if matchCount == 0 { return .failure(.selection(.notFound)) }
        if matchCount > ref.matches.count { return .failure(.selection(.ambiguous(matchCount))) }
        var matches: [UIElementSnapshot] = []
        for m in raw {
            guard let type = m["type"] as? String, let enabled = bool(m["enabled"]), let visible = bool(m["visible"]) else {
                return bad("malformed match")
            }
            guard let f = rect(m["rect"]) else { return changed("a same-selector element has no finite frame now") }
            matches.append(UIElementSnapshot(type: type, identifier: m["name"] as? String, label: m["label"] as? String,
                                             value: m["value"] as? String, frame: f, enabled: enabled, visible: visible))
        }
        // Every same-selector element exactly as observed (type, strings, value, enabled, visible, frame, order).
        guard matches == ref.matches else {
            return changed("target identity or geometry changed since the observation; not rebound")
        }
        var keyboards: [UIElementSnapshot] = []
        for k in rawKeys {
            guard let f = rect(k["rect"]), let v = bool(k["visible"]) else { return changed("keyboard has no finite frame") }
            keyboards.append(UIElementSnapshot(type: "XCUIElementTypeKeyboard", frame: f, visible: v))
        }
        let visibleKeys = { (es: [UIElementSnapshot]) in es.filter { $0.type == "XCUIElementTypeKeyboard" && $0.visible }.map(\.frame) }
        guard visibleKeys(keyboards) == visibleKeys(obs.elements) else { return changed("keyboard appeared, vanished or moved") }

        var canonical = "t1|\(ww)x\(wh)|\(obs.orientation)|\(bound)|\(pid)\n"
        for e in matches + keyboards {
            canonical += "\(e.type)|\(WDACompactSource.field(e.identifier))|\(WDACompactSource.field(e.label))|"
            canonical += "\(WDACompactSource.field(e.value))|\(e.enabled ? 1 : 0)\(e.visible ? 1 : 0)|\(e.frame.x),\(e.frame.y),\(e.frame.width),\(e.frame.height)\n"
        }
        let mini = WDAObservation(bundleID: bound, windowSize: obs.windowSize, orientation: obs.orientation,
                                  elements: matches + keyboards, sourceDigest: "t1:" + WDASource.digest(canonical), capturedAt: now)
        // The same resolution a full observation gets: it reads only selector matches and keyboards.
        switch TargetSelection.resolve(ref, in: mini) {
        case .failure(let e): return .failure(.selection(e))
        case .success(let t):
            guard t.element == ref.element else { return changed("selector now resolves to another element") }
            var runnerMs: [String: Double] = [:]
            for (k, v) in (o["timings_ms"] as? [String: Any]) ?? [:] { if let d = num(v) { runnerMs[k] = d } }
            let elapsed = int((env["target_read"] as? [String: Any])?["elapsed_ms"])
            return .success((mini, t, WDATargetRevalidationInfo(matchCount: matchCount, keyboards: keyboards.count,
                                                                nodesWalked: int(o["nodes_walked"]), runnerMs: runnerMs,
                                                                elapsedMs: elapsed, baselineDigest: baseline)))
        }
    }
}

/// One navigation tap whose pre-action check is the targeted revalidation: request -> independent check against the
/// observation the model decided on -> gate -> one tap -> FULL fresh observation to verify (unchanged). Single use.
/// A failed, refused or timed-out revalidation sends nothing and is not repeated; it never turns into a full
/// observation inside this step (the caller observes again for the next decision).
@MainActor public final class WDATargetedTapStep {
    public let bundleID: String
    let revalidator: WDATargetRevalidator
    let provider: WDAObservationProvider
    let tapper: WDATapSink
    let policy: GatePolicy
    let clock: () -> Date
    private(set) var consumed = false

    public init(bundleID: String, revalidator: WDATargetRevalidator, provider: WDAObservationProvider, tapper: WDATapSink,
                policy: GatePolicy = GatePolicy(), clock: @escaping () -> Date = Date.init) {
        self.bundleID = bundleID; self.revalidator = revalidator; self.provider = provider; self.tapper = tapper
        self.policy = policy; self.clock = clock
    }

    /// `request` from `WDATargetCheck.request(ref:observation:bound:)` for the same `ref` and `decided`.
    public func run(tap ref: TargetRef, decidedOn decided: WDAObservation, request: String, expect: Expectation) async -> WDATapStepReport {
        var report = WDATapStepReport(outcome: .alreadyConsumed)
        guard !consumed else { return report }
        consumed = true  // one revalidation request per step, whatever its answer
        report.preAct = .targeted
        let answer: String
        do { answer = try await revalidator.revalidateTarget(requestJSON: request) } catch {
            report.outcome = .observationFailed("target revalidation: \(error.localizedDescription)")
            return report
        }
        let mini: WDAObservation, target: SelectedTarget
        switch WDATargetCheck.evaluate(answer: answer, ref: ref, observation: decided, bound: bundleID, now: clock()) {
        case .failure(.bad(let m)): report.outcome = .observationFailed("target revalidation: \(m)"); return report
        case .failure(.selection(let e)): report.outcome = .selectionFailed(e); return report
        case .success(let r): (mini, target, report.revalidation) = (r.0, r.1, r.2)
        }
        report.target = target
        let plan: WDATapPlan
        switch WDATapGate.evaluate(target: target, observation: mini, expectedBundleID: bundleID, now: clock(), policy: policy) {
        case .failure(let b): report.outcome = .blocked(b.reasons); return report
        case .success(let p): plan = p
        }
        report.plan = plan
        report.taps = 1
        do {
            try await tapper.tap(at: plan.point, window: plan.window)
        } catch WDATapError.notSent(let m) {
            report.outcome = .tapNotSent(m); return report
        } catch WDATapError.rejected(let m) {
            report.outcome = .tapRejected(m); return report
        } catch {
            report.outcome = .tapUncertain(error.localizedDescription); return report
        }
        let acted = clock()
        let after: WDAObservation
        do { after = try await provider.observe(targetBundleID: bundleID) } catch {
            report.outcome = .notVerified("no observation after the tap: \(error.localizedDescription)")
            return report
        }
        report.after = after
        if after.windowSize != decided.windowSize || after.orientation != decided.orientation {
            report.outcome = .notVerified("window size / orientation changed after the tap")
            return report
        }
        report.outcome = Self.verify(after, expect: expect, baseline: report.revalidation?.baselineDigest, bundleID: bundleID,
                                     actedAt: acted)
        return report
    }

    /// "Changed" is judged only against the runner fingerprint of the fresh pre-tap snapshot, never against the
    /// (older) observation the model decided on: a screen that changed during inference must not verify a tap that
    /// did nothing. Without both runner digests the result is indeterminate, never success.
    static func verify(_ after: WDAObservation, expect: Expectation, baseline: String?, bundleID: String,
                       actedAt: Date) -> WDATapStepOutcome {
        guard after.capturedAt > actedAt else { return .notVerified("observation is older than the click") }
        guard after.bundleID == bundleID else { return .notVerified("observation is of \(after.bundleID)") }
        guard after.foreground else { return .notVerified("\(bundleID) is not in the foreground") }
        switch expect {
        case .elementPresent(let s):
            return after.elements.contains(where: s.matches) ? .verified : .notVerified("expected element not found")
        case .sourceChanged:
            guard let baseline, WDATargetCheck.isScreenDigest(baseline), let now = after.provenance?.runnerDigest else {
                return .notVerified("verification indeterminate: no runner screen digest for the pre-tap baseline or the post-tap observation; not counted as success")
            }
            return now != baseline ? .verified : .notVerified("screen did not change (runner digest equals the fresh pre-tap baseline)")
        }
    }
}
