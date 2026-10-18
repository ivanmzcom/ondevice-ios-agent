import Foundation
import UnifiedAgentCore

extension UniRunner.Failure: LocalizedError, AgentDiagClassified {
    var errorDescription: String? { "unified-ffi \(code): \(json)" }
    /// Code and Rust's fixed snake_case stage name only; `detail` may echo WDA answers and is never logged.
    var diagClass: String {
        let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        guard let stage = o?["stage"] as? String, !stage.isEmpty,
              stage.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || $0 == "_" }) else { return "ffi.\(code)" }
        return "ffi.\(code).\(stage)"
    }
    /// Rust's stage name, nil when absent.
    var stage: String? { ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])?["stage"] as? String }
}

/// One `[AgentDiag]` begin/end around an FFI call (AgentDiag.swift). The span ends only when the native call has
/// returned: a Stop meanwhile leaves `wait` lines, since nothing can cancel a blocking call.
private func traced(_ op: String, fields: AgentDiag.Fields = [],
                    _ call: () async -> Result<String, UniRunner.Failure>) async -> Result<String, UniRunner.Failure> {
    let span = AgentDiag.begin(op, fields)
    let r = await call()
    switch r {
    case .success(let json): span.end(op.hasPrefix("wda.observe") ? WDASession.sourceReadFields(json) : [])
    case .failure(let f): span.fail(f, [("cancelled_caller", .bool(Task.isCancelled))])
    }
    return r
}

/// A launched WDA runner with one open WDA session (unified-ffi src/session.rs): the agent's observation provider
/// (state-preserving, no bundleId session), its tap and typing sink, and the cross-app driver. Rust serializes calls.
/// Every native call enters `gate` and leaves it when it returned: `close` frees the pointer once, after the last
/// call left; an answer carrying a `session_lost` record marks the session lost and later calls are refused unsent.
final class WDASession: WDAObservationProvider, WDATapSink, WDATargetRevalidator, WDAForegroundSource, WDANavigationSink, WDATextSink, @unchecked Sendable {
    private struct Handle: @unchecked Sendable { let p: OpaquePointer }
    private let gate: NativeCallGate<Handle>
    private let lock = NSLock()

    private init(_ p: OpaquePointer) { gate = NativeCallGate(Handle(p: p)) }

    /// Why this session is dead (`connection_refused`, `invalid_session`, `session_unusable`); nil while usable.
    var lostReason: String? { gate.lostReason }

    static func open(pairing: Data, deviceIP: String, runner: String, heartbeat: Bool) async -> Result<(WDASession, String), UniRunner.Failure> {
        let box = PointerBox()
        let r = await traced("wda.open", fields: [("heartbeat", .bool(heartbeat))]) { await UniRunner.call { j, e in
            pairing.withUnsafeBytes { p in
                uni_session_open(p.bindMemory(to: UInt8.self).baseAddress, p.count, deviceIP, runner, heartbeat ? 1 : 0,
                                 90, &box.p, j, e)
            }
        } }
        switch r {
        case .success(let json):
            guard let p = box.p else { return .failure(.init(code: ODR_ERR_RUNTIME, json: "{\"detail\":\"no session\"}")) }
            let session = WDASession(p)
            // Source levers (Avanzado preset; a missing key = Combinada, Base = explicit {}). A refused or unconfirmed
            // config fails the open instead of silently running another config.
            // The observer (Avanzado, default XML) rides in the same config; the readback must confirm it.
            let observer = WDAObserver.stored(UserDefaults.standard.string(forKey: WDAObserver.defaultsKey))
            let config = observer.apply(to: WDASourcePreset.effectiveConfig(stored: UserDefaults.standard.string(forKey: WDASourcePreset.defaultsKey)))
            switch await session.configureSource(config) {
            case .success(let readback) where !observer.confirmed(byReadback: readback):
                await session.close()
                return .failure(.init(code: ODR_ERR_ARGUMENT, json: "{\"stage\":\"observer_unconfirmed\",\"detail\":\"the native library did not confirm the \(observer.rawValue) observer\"}"))
            case .success(let readback):
                session.sourceConfig = config
                session.observer = observer
                return .success((session, Self.merged(json, sourceConfig: readback)))
            case .failure(let f):
                await session.close()
                return .failure(f)
            }
        case .failure(let f): return .failure(f)
        }
    }

    /// The source config this session was opened with (confirmed by `uni_session_configure_source`).
    private(set) var sourceConfig = ""
    /// The observer this session was opened with (confirmed by the same readback); every decode requires it.
    private(set) var observer: WDAObserver = .xml

    /// Applies source options; the answer holds the readback of the effective WDA settings.
    func configureSource(_ config: String) async -> Result<String, UniRunner.Failure> {
        let h: Handle
        do { h = try enter() } catch { return .failure(error as? UniRunner.Failure ?? Self.closed) }
        let preset = WDASourcePreset.allCases.first { $0.configJSON == config }.map(\.rawValue) ?? "custom"
        return leave(await traced("wda.configure_source", fields: [("preset", .token(preset))]) {
            await UniRunner.call { j, e in uni_session_configure_source(h.p, config, 15, j, e) }
        })
    }

    private static func merged(_ open: String, sourceConfig: String) -> String {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(open.utf8))) as? [String: Any],
              let c = try? JSONSerialization.jsonObject(with: Data(sourceConfig.utf8)),
              let d = try? JSONSerialization.data(withJSONObject: o.merging(["source_config": c]) { $1 }),
              let s = String(data: d, encoding: .utf8) else { return open }
        return s
    }

    private final class PointerBox: @unchecked Sendable { var p: OpaquePointer? }

    private static let closed = UniRunner.Failure(code: ODR_ERR_ARGUMENT, json: "{\"detail\":\"WDA session is closed\"}")

    /// The pointer for one native call, which must `leave`. Closed or lost: refused, nothing reaches Rust.
    private func enter() throws -> Handle {
        do { return try gate.enter() } catch NativeCallGate<Handle>.Refusal.lost(let why) {
            throw UniRunner.Failure(code: ODR_ERR_WDA_SESSION, json: "{\"stage\":\"session_unusable\",\"detail\":\"WDA session lost (\(why)); nothing was sent\"}")
        } catch {
            throw Self.closed
        }
    }

    /// Ends a native call; a `session_lost` record in its error marks the session lost.
    private func leave(_ r: Result<String, UniRunner.Failure>) -> Result<String, UniRunner.Failure> {
        var reason: String?
        if case .failure(let f) = r { reason = WDASessionLoss.reason(json: f.json) }
        if let reason, gate.lostReason == nil { AgentDiag.event("wda.session_lost", [("reason", .token(reason))]) }
        gate.leave(lostReason: reason)
        return r
    }

    func observe(targetBundleID: String) async throws -> WDAObservation {
        let h = try enter()
        switch leave(await traced("wda.observe", { await UniRunner.call({ j, e in uni_session_observe(h.p, targetBundleID, 45, j, e) }) })) {
        case .success(let json): return try WDAObservation.fromUnifiedObserveJSON(Data(json.utf8), observer: observer)
        case .failure(let f): throw f
        }
    }

    /// Exactly one `POST /session/{id}/hermes/target` (uni_session_revalidate_target); never retried, never a full
    /// observation instead.
    func revalidateTarget(requestJSON: String) async throws -> String {
        let h = try enter()
        switch leave(await traced("wda.revalidate_target", { await UniRunner.call({ j, e in uni_session_revalidate_target(h.p, requestJSON, 25, j, e) }) })) {
        case .success(let json): return json
        case .failure(let f): throw f
        }
    }

    /// Exactly one `POST /session/{id}/wda/tap` (uni_session_tap). Rust refuses points outside the window and never
    /// retries; a written request without a clear answer comes back as `.uncertain`, never as a retryable error.
    func tap(at point: WDAPoint, window: WDASize) async throws {
        let h: Handle
        do { h = try enter() } catch { throw WDATapError.notSent("WDA session is closed or lost") }
        try Self.mutation(leave(await traced("wda.tap", { await UniRunner.call({ j, e in uni_session_tap(h.p, point.x, point.y, window.width, window.height, 25, j, e) }) })))
    }

    /// Read-only foreground bundle (`GET /session/{id}/wda/activeAppInfo`, uni_session_active_app).
    func activeApp() async throws -> String {
        let h = try enter()
        switch leave(await traced("wda.active_app", { await UniRunner.call({ j, e in uni_session_active_app(h.p, 15, j, e) }) })) {
        case .success(let json):
            guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                  let b = o["bundle_id"] as? String, !b.isEmpty else {
                throw UniRunner.Failure(code: ODR_ERR_WDA_SESSION, json: "{\"detail\":\"activeAppInfo without bundle id\"}")
            }
            return b
        case .failure(let f): throw f
        }
    }

    /// Observation of the real foreground app, never activated (uni_session_observe_foreground).
    func observeForeground(expected: String?) async throws -> WDAObservation {
        let h = try enter()
        let r: Result<String, UniRunner.Failure>
        if let expected {
            r = await traced("wda.observe_foreground", fields: [("expected", .bool(true))]) { await UniRunner.call({ j, e in uni_session_observe_foreground(h.p, expected, 45, j, e) }) }
        } else {
            r = await traced("wda.observe_foreground", fields: [("expected", .bool(false))]) { await UniRunner.call({ j, e in uni_session_observe_foreground(h.p, nil, 45, j, e) }) }
        }
        switch leave(r) {
        case .success(let json): return try WDAObservation.fromUnifiedObserveJSON(Data(json.utf8), observer: observer)
        case .failure(let f): throw f
        }
    }

    /// Exactly one Home press (uni_session_press_home); never retried.
    func pressHome() async throws {
        let h: Handle
        do { h = try enter() } catch { throw WDATapError.notSent("WDA session is closed or lost") }
        try Self.mutation(leave(await traced("wda.press_home") { await UniRunner.call({ j, e in uni_session_press_home(h.p, 25, j, e) }) }))
    }

    /// Exactly one explicit open-app action (uni_session_activate); never retried.
    func activate(bundleID: String) async throws {
        let h: Handle
        do { h = try enter() } catch { throw WDATapError.notSent("WDA session is closed or lost") }
        try Self.mutation(leave(await traced("wda.activate") { await UniRunner.call({ j, e in uni_session_activate(h.p, bundleID, 25, j, e) }) }))
    }

    /// Exactly one `POST /session/{id}/wda/keys` into the focused field (uni_session_type_text); never retried.
    func typeText(_ text: String) async throws {
        let h: Handle
        do { h = try enter() } catch { throw WDATapError.notSent("WDA session is closed or lost") }
        try Self.mutation(leave(await traced("wda.type", fields: [("chars", .int(text.count))]) { await UniRunner.call({ j, e in uni_session_type_text(h.p, text, 25, j, e) }) }))
    }

    private static func mutation(_ r: Result<String, UniRunner.Failure>) throws {
        guard case .failure(let f) = r else { return }
        switch f.code {
        case ODR_ERR_TAP_REJECTED: throw WDATapError.rejected(f.json)
        case ODR_ERR_TAP_NOT_SENT, ODR_ERR_ARGUMENT: throw WDATapError.notSent(f.json)
        // Refused by Rust on a session already lost: nothing was written.
        case _ where f.stage == "session_unusable": throw WDATapError.notSent(f.json)
        default: throw WDATapError.uncertain("(\(f.code)) \(f.json)")
        }
    }

    private var comparing = false

    /// Read-only `/source` JSON then XML with this session's confirmed config (uni_session_compare_source): one
    /// request per format, no retry, foreground bound by activeAppInfo. Refused while another comparison runs.
    func compareSource() async -> Result<String, UniRunner.Failure> {
        let busy: Bool = lock.withLock { if comparing { return true }; comparing = true; return false }
        guard !busy else { return .failure(.init(code: ODR_ERR_ARGUMENT, json: "{\"detail\":\"WDA session is closed or busy\"}")) }
        defer { lock.withLock { comparing = false } }
        let h: Handle
        do { h = try enter() } catch { return .failure(error as? UniRunner.Failure ?? Self.closed) }
        return leave(await traced("wda.compare_source") { await UniRunner.call { j, e in uni_session_compare_source(h.p, nil, 120, j, e) } })
    }

    /// Deletes the WDA session (the target app keeps running; a lost session sends no DELETE) and stops the runner.
    /// Returns only when the native session is freed, which happens once and after every running call returned.
    func close() async {
        guard let h = await gate.close() else { AgentDiag.event("wda.close_noop"); return }
        let span = AgentDiag.begin("wda.close", [("lost", .bool(lostReason != nil))])
        await Task.detached { uni_session_close(h.p) }.value
        span.end()
    }

    /// `source_read` timings of an observe answer (route, deadline, elapsed, app-issued WDA request count, whether a
    /// screenshot was taken; never hierarchy text).
    static func sourceReadFields(_ json: String) -> AgentDiag.Fields {
        guard let r = json.range(of: "\"source_read\":{"), let close = json[r.upperBound...].firstIndex(of: "}"),
              let o = (try? JSONSerialization.jsonObject(with: Data(("{" + json[r.upperBound..<close] + "}").utf8))) as? [String: Any]
        else { return [] }
        var f: AgentDiag.Fields = []
        if let v = o["route"] as? String { f.append(("source_route", .token(v))) }
        if let v = o["observer"] as? String { f.append(("source_observer", .token(v))) }
        for k in ["elapsed_ms", "deadline_ms", "wda_requests", "endpoint_version"] {
            if let n = o[k] as? NSNumber { f.append(("source_" + k, .int(n.intValue))) }
        }
        if let b = o["screenshot"] as? Bool { f.append(("source_screenshot", .bool(b))) }
        if let b = o["after_source_failure"] as? Bool { f.append(("source_after_failure", .bool(b))) }
        return f
    }
}
