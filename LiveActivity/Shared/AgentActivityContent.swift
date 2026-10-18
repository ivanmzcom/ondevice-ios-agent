import Foundation

// Shared by the app and the UnifiedActivity widget extension. Foundation only, so the lifecycle host test
// (tests/live_activity_main.swift) compiles it on the Mac without ActivityKit.

/// The agent's mood; drives the character in the Live Activity (upstream ios/Shared/AgentFace.swift).
enum Mood: String, Codable, Hashable {
    case sleeping, idle, listening, thinking, acting, success, failure
    /// Poke reactions in the upstream Home screen; unused here but kept so AgentFace compiles unchanged.
    case dizzy, content, wink
}

/// Dynamic state of the run's Live Activity: the upstream `AgentActivityAttributes.ContentState` without the
/// help/recording phases (the unified task agent has neither). Everything here is shown on the Lock Screen, so
/// it only ever holds fixed status strings and counters: never the task, model words, element labels or tokens.
struct AgentActivityContent: Codable, Hashable {
    var mood: Mood
    var step: Int       // actions done (WDA taps / typing sent)
    var limit: Int      // the step limit of a run
    var line: String    // fixed status line
    var finished = false
    var label = ""      // compact island ("Thinking…", "Tapping…")
    var labelFull = ""  // the same, longer, for the expanded island and the Lock Screen
    var minimalLabel: String?
    var waitingSince: Date?  // system-rendered elapsed timer, even between app updates
    var lookX = 0.0
    var lookY = 0.0
}
