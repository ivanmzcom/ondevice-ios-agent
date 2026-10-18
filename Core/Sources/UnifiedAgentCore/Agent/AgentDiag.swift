import Foundation

/// `[AgentDiag]` lines on stdout, unbuffered, for `xcrun devicectl device process launch --console` (HANG_DIAGNOSIS.md).
/// Unlike `DebugLog` (which may carry the task, prompt, model words, labels, typed text or source), a line holds only
/// stage names, run/operation ids, monotonic durations, counts, error classes and fixed config names: every value goes
/// through `Value`, whose text form keeps `[A-Za-z0-9._-]` and at most 48 characters. Never pass screen or user text.
public enum AgentDiag {
    public enum Value: Equatable, Sendable {
        case int(Int), ms(Double), bool(Bool), token(String)
        var text: String {
            switch self {
            case .int(let v): return String(v)
            case .ms(let v): return String(format: "%.0f", v)
            case .bool(let v): return v ? "1" : "0"
            case .token(let s): return AgentDiag.token(s)
            }
        }
    }
    public typealias Fields = [(String, Value)]

    /// Where lines go; stdout + fflush by default (stdout is a pipe under devicectl, so it would be block-buffered).
    nonisolated(unsafe) public static var sink: (String) -> Void = { line in
        fputs(line + "\n", stdout)
        fflush(stdout)
    }
    nonisolated(unsafe) static var monotonic: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    /// A `wait` line repeats this often while an operation is still pending (0 = never).
    nonisolated(unsafe) public static var waitEveryNanoseconds: UInt64 = 10_000_000_000

    private static let lock = NSLock()
    nonisolated(unsafe) private static var seq = 0
    nonisolated(unsafe) private static var runs = 0
    nonisolated(unsafe) private static var run = "-"
    private static let t0 = DispatchTime.now().uptimeNanoseconds

    static func token(_ s: String) -> String {
        let ok = s.unicodeScalars.map { c -> Character in
            CharacterSet.alphanumerics.contains(c) && c.isASCII || ".-_".unicodeScalars.contains(c) ? Character(c) : "_"
        }
        let t = String(ok.prefix(48))
        return t.isEmpty ? "_" : t
    }

    /// Error class only (type/domain and code); never `localizedDescription`, which may echo answers or screen text.
    public static func errorClass(_ error: Error) -> String {
        if let c = error as? AgentDiagClassified { return token(c.diagClass) }
        if error is CancellationError { return "cancelled" }
        let n = error as NSError
        return token("\(String(describing: type(of: error))).\(n.code)")  // the type name, never its payload
    }

    /// Starts a new run id (one per task run); later lines carry it.
    @discardableResult public static func newRun() -> String {
        lock.lock(); defer { lock.unlock() }
        runs += 1
        run = "r\(runs)"
        return run
    }

    static func emit(_ op: String, _ phase: String, _ fields: Fields) {
        lock.lock()
        let r = run
        lock.unlock()
        // The base first: `t0` is lazy, so reading the clock before it made the first line wrap around.
        let base = t0, now = monotonic()
        let ms = now >= base ? Double(now - base) / 1e6 : 0
        let kv = fields.map { " \(token($0.0))=\($0.1.text)" }.joined()
        sink("[AgentDiag] t=\(String(format: "%.0f", ms)) run=\(r) op=\(op) \(phase)\(kv)")
    }

    /// A point event (stop requested, session dropped, build).
    public static func event(_ name: String, _ fields: Fields = []) { emit(token(name), "event", fields) }

    public static func begin(_ name: String, _ fields: Fields = []) -> Span {
        lock.lock()
        seq += 1
        let id = "\(token(name))#\(seq)"
        lock.unlock()
        return Span(id: id, fields: fields)
    }

    /// One begin/end pair around `body`; a thrown error ends it as `err` with its class only.
    public static func measure<T>(_ name: String, _ fields: Fields = [], _ body: () async throws -> T) async rethrows -> T {
        let span = begin(name, fields)
        do {
            let v = try await body()
            span.end()
            return v
        } catch {
            span.fail(error)
            throw error
        }
    }

    /// One operation: `begin`, a `wait` line every `waitEveryNanoseconds` while pending, then exactly one `end`. A wait
    /// after Stop means the operation (for example a blocking native call) is still running; nothing was cancelled.
    public final class Span: @unchecked Sendable {
        public let id: String
        let start: UInt64
        private var ended = false
        private let lock = NSLock()
        private var waiter: Task<Void, Never>?

        init(id: String, fields: Fields) {
            self.id = id
            start = AgentDiag.monotonic()
            AgentDiag.emit(id, "begin", fields)
            let every = AgentDiag.waitEveryNanoseconds
            guard every > 0 else { return }
            waiter = Task.detached { [weak self] in
                while true {
                    try? await Task.sleep(nanoseconds: every)
                    guard let self, !Task.isCancelled, !self.isEnded else { return }
                    AgentDiag.emit(self.id, "wait", [("ms", .ms(self.elapsedMs)), ("cancelled_caller", .bool(false))])
                }
            }
        }

        var elapsedMs: Double { Double(AgentDiag.monotonic() &- start) / 1e6 }
        private var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }

        /// First call wins; later ones are ignored (one end line per begin).
        public func end(_ fields: Fields = []) { close("end ok", fields) }
        public func fail(_ error: Error, _ fields: Fields = []) { close("end err", [("err", .token(AgentDiag.errorClass(error)))] + fields) }

        private func close(_ phase: String, _ fields: Fields) {
            lock.lock()
            let first = !ended
            ended = true
            let w = waiter
            waiter = nil
            lock.unlock()
            guard first else { return }
            w?.cancel()
            AgentDiag.emit(id, phase, [("ms", .ms(elapsedMs))] + fields)
        }
    }
}

extension BuildStamp {
    /// Build and next `/source` config as diagnostic fields: preset name and numeric levers only.
    public static func diagFields(bundleVersion: String?, libVersion: String, storedSourceConfig: String?) -> AgentDiag.Fields {
        let next = WDASourcePreset.effectiveConfig(stored: storedSourceConfig)
        var f: AgentDiag.Fields = [("ui", .token(uiRevision)), ("bundle", .token(bundleVersion ?? "?")), ("ffi", .token(libVersion)),
                                   ("source_preset", .token(WDASourcePreset.matching(stored: next)?.rawValue ?? "custom"))]
        if let o = (try? JSONSerialization.jsonObject(with: Data(next.utf8))) as? [String: Any] {
            for k in o.keys.sorted() { if let n = o[k] as? NSNumber, !(o[k] is Bool) { f.append(("src_" + k, .ms(n.doubleValue))) } }
            if let ex = o["excluded_attributes"] as? [Any] { f.append(("src_excluded_count", .int(ex.count))) }
        }
        return f
    }
}

/// An error that can name its own diagnostic class (codes and fixed stage names only).
public protocol AgentDiagClassified { var diagClass: String { get } }
