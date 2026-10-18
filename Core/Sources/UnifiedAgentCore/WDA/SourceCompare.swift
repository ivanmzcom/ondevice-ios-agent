import Foundation

public enum WDASourceComparisonError: Error { case malformed }

/// The answer of `uni_session_compare_source` (WDA_500_DIAGNOSIS.md §7 R0/R1): one read-only `/source` per format,
/// statuses, durations and body sizes only. The two reads are comparable, not one snapshot, so a verdict is
/// evidence, never proof.
public struct WDASourceComparison: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public let format: String
        public let outcome: String
        public let httpStatus: Int?
        public let durationMs: Int
        public let responseBytes: Int?
        public let wdaError: String?
        public let foregroundStable: Bool
    }

    public let samples: [Sample]
    public let excludedAttributes: [String]
    public let deadlineMs: Int
    public let afterSourceFailure: Bool
    /// Why the run stopped early (a foreground mismatch or change), nil when every format was read.
    public let void: String?

    public init(json: String) throws {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              o["stage"] as? String == "compare_source", let raw = o["samples"] as? [[String: Any]] else {
            throw WDASourceComparisonError.malformed
        }
        samples = raw.map { s in
            Sample(format: Self.token(s["format"]) ?? "?", outcome: Self.token(s["outcome"]) ?? "?",
                   httpStatus: (s["http_status"] as? NSNumber)?.intValue, durationMs: (s["duration_ms"] as? NSNumber)?.intValue ?? 0,
                   responseBytes: (s["response_bytes"] as? NSNumber)?.intValue, wdaError: Self.token(s["wda_error"]),
                   foregroundStable: s["foreground_stable"] as? Bool ?? false)
        }
        excludedAttributes = ((o["excluded_attributes"] as? [String]) ?? []).compactMap { Self.token($0) }
        deadlineMs = (o["deadline_ms"] as? NSNumber)?.intValue ?? 0
        afterSourceFailure = o["after_source_failure"] as? Bool ?? false
        void = Self.token(o["void"])
    }

    /// Lowercase snake_case / camelCase identifiers only: anything else from the native side is dropped.
    static func token(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty, s.count <= 64,
              s.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == ".") }) else { return nil }
        return s
    }

    public func sample(_ format: String) -> Sample? { samples.first { $0.format == format } }

    /// What the pair suggests (Spanish UI text). Evidence only: the reads are not the same snapshot.
    public var verdict: String {
        if let void { return "Anulada (\(void)): la app en primer plano cambió; repite con la pantalla quieta." }
        guard let j = sample("json"), let x = sample("xml") else { return "Incompleta." }
        switch (j.outcome == "ok", x.outcome == "ok") {
        case (true, false): return "JSON bien y XML falla: indicio de fallo en la serialización XML (no es prueba)."
        case (false, false): return "Ambos fallan: indicio de fallo compartido (snapshot/atributos), no de XML."
        case (true, true): return "Ambos bien: el fallo no se reprodujo en esta pareja."
        case (false, true): return "JSON falla y XML bien: inesperado; repite antes de concluir."
        }
    }

    /// One line per sample for the UI and `[AgentDiag]`: format, outcome, status, duration, size only.
    public var lines: [String] {
        samples.map { s in
            var l = "\(s.format): \(s.outcome)"
            if let c = s.httpStatus { l += " HTTP \(c)" }
            l += " \(s.durationMs) ms"
            if let b = s.responseBytes { l += " \(b) B" }
            if let e = s.wdaError { l += " [\(e)]" }
            if !s.foregroundStable { l += " (primer plano cambió)" }
            return l
        }
    }

    public var diagFields: AgentDiag.Fields {
        var f: AgentDiag.Fields = [("deadline_ms", .int(deadlineMs)), ("excluded", .int(excludedAttributes.count)),
                                   ("after_source_failure", .bool(afterSourceFailure))]
        if let void { f.append(("void", .token(void))) }
        for s in samples {
            f.append(("\(s.format)_outcome", .token(s.outcome)))
            f.append(("\(s.format)_ms", .int(s.durationMs)))
            if let c = s.httpStatus { f.append(("\(s.format)_status", .int(c))) }
            if let b = s.responseBytes { f.append(("\(s.format)_bytes", .int(b))) }
            if let e = s.wdaError { f.append(("\(s.format)_wda_error", .token(e))) }
        }
        return f
    }

    /// The native session no longer exists (WDA answered `invalid_session` for a sample).
    public var sessionLost: Bool { samples.contains { $0.wdaError == "invalid_session" } }
}
