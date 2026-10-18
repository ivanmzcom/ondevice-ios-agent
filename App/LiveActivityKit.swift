import ActivityKit
import Foundation

/// The real boundary: one `Activity<AgentActivityAttributes>` per run. Requests happen only while the app is in
/// front (the user just tapped Iniciar); updates and the end are sent while iOS still lets the app run. A Live
/// Activity does not give the app any background execution time.
@MainActor final class ActivityKitBoundary: LiveActivityBoundary {
    /// `Activity` is not marked Sendable in the SDK; ActivityKit allows its calls from any thread, and this
    /// boundary only reaches it from nonisolated helpers.
    private final class Handle: @unchecked Sendable {
        let activity: Activity<AgentActivityAttributes>
        init(_ a: Activity<AgentActivityAttributes>) { activity = a }
    }
    private var handle: Handle?

    var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func request(runID: String, state: AgentActivityContent) throws {
        handle = Handle(try Activity.request(attributes: AgentActivityAttributes(title: "Agent task", runID: runID),
                                             content: .init(state: state, staleDate: nil), pushType: nil))
    }

    func update(_ state: AgentActivityContent) {
        guard let handle else { return }
        Task { await Self.update(handle, state) }
    }

    func end(_ state: AgentActivityContent, dismissal: LiveActivityDismissal) async {
        guard let handle else { return }
        self.handle = nil
        await Self.end(handle, state, dismissal)
    }

    func endOrphans() async { await Self.endAll(except: handle?.activity.id) }

    private nonisolated static func update(_ h: Handle, _ state: AgentActivityContent) async {
        await h.activity.update(.init(state: state, staleDate: nil))
    }

    private nonisolated static func end(_ h: Handle, _ state: AgentActivityContent, _ dismissal: LiveActivityDismissal) async {
        let policy: ActivityUIDismissalPolicy
        switch dismissal {
        case .immediate: policy = .immediate
        case .after(let s): policy = .after(.now + s)
        }
        await h.activity.end(.init(state: state, staleDate: nil), dismissalPolicy: policy)
    }

    private nonisolated static func endAll(except id: String?) async {
        for a in Activity<AgentActivityAttributes>.activities where a.id != id {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }
}
