import Foundation

/// `/source` timeout levers (`uni_session_configure_source`, WDA_SOURCE_FIX_REPORT.md) as presets. The JSON is
/// persisted under `defaultsKey`; a missing key means `combined`, and `baseline` is the explicit `{}`.
public enum WDASourcePreset: String, CaseIterable, Sendable {
    case baseline, idleOnly, snapshotOnly, deadlineOnly, combined

    public static let defaultsKey = "wdaSourceConfig"
    public static let defaultPreset: WDASourcePreset = .combined

    public var title: String {
        switch self {
        case .baseline: return "Base (sin cambios)"
        case .idleOnly: return "Solo espera de reposo"
        case .snapshotOnly: return "Solo snapshot ligero"
        case .deadlineOnly: return "Solo plazo de /source"
        case .combined: return "Combinada"
        }
    }

    public var configJSON: String {
        let excluded = #""excluded_attributes":["accessible","index","traits","placeholderValue"]"#
        switch self {
        case .baseline: return "{}"
        case .idleOnly: return #"{"animation_cool_off_s":0}"#
        case .snapshotOnly: return "{\(excluded)}"
        case .deadlineOnly: return #"{"source_deadline_s":30}"#
        case .combined: return #"{"animation_cool_off_s":0,\#(excluded),"source_deadline_s":30}"#
        }
    }

    /// The config to send at session open: the stored JSON as is (an explicit custom config is kept), or
    /// `combined` when nothing (or only whitespace) is stored.
    public static func effectiveConfig(stored: String?) -> String {
        guard let s = stored, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return defaultPreset.configJSON }
        return s
    }

    /// The preset the stored config is equivalent to (key order and number spelling ignored); nil = custom.
    public static func matching(stored: String?) -> WDASourcePreset? {
        let config = effectiveConfig(stored: stored)
        guard let o = (try? JSONSerialization.jsonObject(with: Data(config.utf8))) as? NSDictionary else { return nil }
        return allCases.first { p in
            ((try? JSONSerialization.jsonObject(with: Data(p.configJSON.utf8))) as? NSDictionary)?.isEqual(o) == true
        }
    }
}
