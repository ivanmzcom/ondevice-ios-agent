import Foundation

/// Visible build identifier, so an installed app can be matched to a source tree (ARTIFACT_DIAGNOSIS.md). It holds no
/// task, account or screen content: only the UI revision, bundle version, executable date, FFI version and the
/// `/source` config (next open and, if open, the confirmed one).
public enum BuildStamp {
    /// Bump when user-visible behaviour changes. Builds before WDA-only showed ESP32 wording and had no stamp at all.
    public static let uiRevision = "wda-only+source-fix+stamp-1"

    public static func line(bundleVersion: String?, executableDate: Date?, libVersion: String,
                            storedSourceConfig: String?, openSessionConfig: String?) -> String {
        let date = executableDate.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        let name = { (c: String) in WDASourcePreset.matching(stored: c)?.rawValue ?? "custom" }
        let next = WDASourcePreset.effectiveConfig(stored: storedSourceConfig)
        let open = openSessionConfig.map { "\(name($0)) \($0)" } ?? "sin sesión"
        return "build \(uiRevision) · v\(bundleVersion ?? "?") · bin \(date) · \(libVersion) · /source próxima: \(name(next)) \(next) · abierta: \(open)"
    }
}
