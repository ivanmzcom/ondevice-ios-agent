import Foundation

/// Holds the operator-imported pairing record in this app's private
/// Application Support container. The only way in is `importCopy(from:)`,
/// called with a URL the user picked in the system document picker.
/// Contents are never displayed or logged.
enum PairingStore {
    static let maxBytes = 256 * 1024

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing", isDirectory: true)
        return dir.appendingPathComponent("pairing.plist")
    }

    static var isPresent: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func importCopy(from picked: URL) throws {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: picked)
        guard !data.isEmpty, data.count <= maxBytes else {
            throw StoreError.invalidSize(data.count)
        }
        // Minimal shape check without exposing values.
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["HostID"] != nil, plist["DeviceCertificate"] != nil
        else { throw StoreError.notAPairingRecord }

        var dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func load() throws -> Data { try Data(contentsOf: url) }

    static func delete() throws {
        if isPresent { try FileManager.default.removeItem(at: url) }
    }

    enum StoreError: LocalizedError {
        case invalidSize(Int)
        case notAPairingRecord

        var errorDescription: String? {
            switch self {
            case .invalidSize(let n): "Pairing file size \(n) bytes is out of range."
            case .notAPairingRecord: "Selected file is not a pairing record plist."
            }
        }
    }
}
