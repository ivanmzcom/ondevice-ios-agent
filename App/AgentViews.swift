import SwiftUI
import UnifiedAgentCore

/// Sections 4–6: WDA session, model, last run.
struct AgentSections: View {
    @ObservedObject var model: AgentAppModel
    let runner: String
    let target: String
    let heartbeat: Bool
    let hasPairing: Bool
    let flowBusy: Bool

    @State private var presetID = ""

    var body: some View {
        Section("4. WDA session (runner launched once)") {
            LabeledContent("Session", value: model.sessionStatus)
            if model.session == nil {
                Button("Open WDA session") { model.openSession(runner: runner, heartbeat: heartbeat) }
                    .disabled(runner.isEmpty || !hasPairing || model.sessionBusy || flowBusy)
            } else {
                Button("Observe target (this session)") { model.observe(target: target) }
                    .disabled(model.sessionBusy || target.isEmpty || flowBusy)
                Button("Close session", role: .destructive) { model.closeSession() }.disabled(model.sessionBusy || flowBusy)
            }
            Button("Comparar /source JSON/XML (solo lectura)") { model.compareSourceFormats() }
                .disabled(model.session == nil || model.sessionBusy || flowBusy || model.agent?.running == true)
            if !model.sourceCompare.isEmpty { Text(model.sourceCompare).font(.caption2.monospaced()) }
            if model.sessionBusy { ProgressView() }
        }

        Section("5. Model (OpenAI-compatible endpoint, your own key)") {
            Picker("Provider preset", selection: $presetID) {
                Text("Custom").tag("")
                ForEach(ProviderPreset.all.filter { !$0.baseURL.isEmpty }) { Text($0.title).tag($0.id) }
            }
            .onChange(of: presetID) { _, id in
                if let p = ProviderPreset.all.first(where: { $0.id == id }) { model.baseURL = p.baseURL }
            }
            TextField("Base URL (https://…/v1)", text: $model.baseURL)
            TextField("Model ID", text: $model.modelID)
            SecureField("API key (stored in this app's Keychain)", text: $model.apiKey)
            Text("The model ID is sent as-is to this endpoint with your key. ChatGPT plan sign-in is a separate, experimental Debug-only backend below; it never uses this key.")
                .font(.caption2)
            if model.usesChatGPTPlan {
                Text("Not used for tasks: the ChatGPT plan backend is selected (5b).").font(.caption).foregroundStyle(.orange)
            }
            Button("Check endpoint lists this model") { model.checkModel() }.disabled(model.endpoint.problem != nil)
            if !model.modelCheck.isEmpty { Text(model.modelCheck).font(.footnote) }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()

        #if DEBUG
        ChatGPTPlanSection(model: model, account: model.chatGPT)
        #endif

        Section("6. Last run (started from the main screen)") {
            if let a = model.agent { AgentLog(agent: a) } else { Text("No run yet.").font(.caption) }
        }
    }
}

struct AgentLog: View {
    @ObservedObject var agent: TaskAgent
    var body: some View {
        ForEach(agent.events) { e in
            Text("\(e.kind.rawValue): \(e.text)").font(.caption2.monospaced())
                .foregroundStyle(e.kind == .error || e.kind == .blocked ? .red : .primary)
        }
        if let o = agent.outcome { Text(o).font(.footnote.bold()) }
        // Client-side timings (monotonic); the model figure is wall time including network and waiting.
        ForEach(agent.timings, id: \.step) { t in
            Text(t.summary).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }
}
