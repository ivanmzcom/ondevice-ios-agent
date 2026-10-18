import Foundation

// The vendored model client (Upstream/LLMClient.swift, unchanged) and this package's agent and ChatGPT code log
// through `DebugLog`, as the upstream app does. This package has no app log of its own: lines go to `sink`, which
// the host app may set to forward them.

enum DebugLog {
    /// Each line goes here; the host app may forward it to its own log.
    nonisolated(unsafe) static var sink: ((String) -> Void)?
    static func write(_ text: String) { sink?(text) }
}

/// Wall-clock seconds, as the upstream app defines it; the unchanged LLMClient times its requests with it.
func now() -> Double { Date().timeIntervalSince1970 }
