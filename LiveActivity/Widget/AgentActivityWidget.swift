import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// Ported from upstream ios/AgentActivity/AgentActivityWidget.swift: the running presentation (eyes, "3/12",
// what it does now, progress, Stop) and the finished one. Without the help/recording phases, the Home Screen
// widget and the controls, which the unified agent does not have. Only fixed strings and counters are shown;
// the static title is "Agent task", never the task itself.

@main
struct UnifiedActivityBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivity()
    }
}

struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Eyes(state: s).frame(width: 44, height: 44).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Counter(state: s).font(.headline).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(verbatim: context.attributes.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Says(state: s, full: true).font(.subheadline.weight(.semibold))
                        if let since = s.waitingSince, !s.finished {
                            Text(since, style: .timer).monospacedDigit().font(.footnote)
                                .accessibilityLabel("Waiting time")
                        }
                        if s.finished && s.line != s.labelFull {
                            Text(verbatim: s.line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        ProgressView(value: Double(min(s.step, s.limit)), total: Double(max(s.limit, 1))).tint(.white)
                        if !s.finished { StopButton() }
                    }
                }
            } compactLeading: {
                Eyes(state: s).frame(width: 24, height: 24)
            } compactTrailing: {
                Says(state: s, full: false).font(.caption.bold()).frame(maxWidth: 92, alignment: .trailing)
            } minimal: {
                // Text-only, as upstream: the face over a label was too small to read.
                Text(verbatim: s.minimalLabel ?? s.label)
                    .font(.caption2.bold()).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: 36, height: 24)
                    .accessibilityLabel(Text(verbatim: s.labelFull))
            }
            .keylineTint(.white)
        }
    }
}

/// "3/12": clicks sent out of the step limit.
private struct Counter: View {
    let state: AgentActivityContent
    var body: some View {
        Text(verbatim: "\(state.step)/\(state.limit)").monospacedDigit().foregroundStyle(.secondary)
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopAgentIntent()) { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
            .tint(.red)
            .buttonStyle(.borderedProminent)
    }
}

/// The character's face without the USB tab; a change of `look` springs between updates.
private struct Eyes: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: AgentActivityContent
    var body: some View {
        AgentFace(mood: state.mood, look: CGPoint(x: state.lookX, y: state.lookY), lookRange: 2.4, animated: false, showsTab: false)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.65), value: state.lookX)
    }
}

/// What the character says ("Thinking…", "Tapping…", "Done!"), colored by how things stand.
private struct Says: View {
    let state: AgentActivityContent
    let full: Bool
    var body: some View {
        let text = full ? state.labelFull : state.label
        Text(verbatim: text.isEmpty ? state.line : text)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(color)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.25), value: text)
    }

    private var color: Color {
        if state.finished { return state.mood == .success ? .green : state.mood == .failure ? .orange : .secondary }
        return .white
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<AgentActivityAttributes>

    var body: some View {
        let s = context.state
        HStack(alignment: .top, spacing: 14) {
            Eyes(state: s).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(verbatim: context.attributes.title).font(.headline).lineLimit(1)
                    Spacer()
                    Counter(state: s).font(.subheadline)
                }
                if !s.labelFull.isEmpty {
                    Says(state: s, full: true).font(.subheadline.weight(.semibold))
                }
                if s.finished {
                    Text(verbatim: s.line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    Label(s.mood == .success ? "Done" : "Ended",
                          systemImage: s.mood == .success ? "checkmark.circle.fill" : "stop.circle")
                        .font(.footnote.weight(.semibold))
                } else {
                    ProgressView(value: Double(min(s.step, s.limit)), total: Double(max(s.limit, 1))).tint(.white)
                    StopButton().controlSize(.small)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}
