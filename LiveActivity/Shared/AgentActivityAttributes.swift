import ActivityKit
import AppIntents
import Foundation

/// The Live Activity / Dynamic Island of a task run (upstream ios/Shared/AgentActivity.swift): while the agent
/// works the target app is in front, so this is what the user sees of the run. Static attributes are public
/// too: a fixed title and a random run id, never the task text.
struct AgentActivityAttributes: ActivityAttributes {
    typealias ContentState = AgentActivityContent

    var title: String
    var runID: String
}

/// What the Live Activity buttons ask the app to do.
enum AgentCommand: String {
    case stop
}

/// Set by the app; nil inside the widget extension (the intents run in the app's process).
@MainActor enum AgentControl {
    static var handle: ((AgentCommand) -> Void)?
}

/// Stop button: stops the running task.
struct StopAgentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop the agent"
    static let description = IntentDescription("Stops the running task.")
    @MainActor func perform() async throws -> some IntentResult {
        AgentControl.handle?(.stop)
        return .result()
    }
}
