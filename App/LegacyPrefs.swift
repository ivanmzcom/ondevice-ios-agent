import Foundation

// UserDefaults keys stored by earlier builds of this app, whose input hardware path no longer exists. The app is
// WDA-only now: these values are never read, and startup never depends on them. They are removed once at launch
// (AgentAppModel.init). Foundation only, so tests/start_flow_main.swift checks it on the Mac.

enum LegacyPrefs {
    /// "pointerCalibration": the stored pointer calibration (JSON). "pairedBoard": the paired Bluetooth peripheral
    /// id (upstream BoardLink). The rest were never persisted by a released build of this spike but are removed too,
    /// in case a development build wrote them.
    static let keys = ["pointerCalibration", "pairedBoard", "boardID", "useWDATap", "useAbsoluteHID"]

    /// Removes exactly `keys` from `defaults`; every other key is left untouched. Safe to call on every launch.
    static func purge(_ defaults: UserDefaults) {
        for k in keys where defaults.object(forKey: k) != nil { defaults.removeObject(forKey: k) }
    }
}
