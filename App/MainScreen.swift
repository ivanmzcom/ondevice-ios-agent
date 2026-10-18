import SwiftUI
import UnifiedAgentCore

/// The coordinator's view of the app: TunnelController, AgentAppModel (WDA session, model, task agent).
@MainActor final class AppStartSteps: StartSteps {
    let tunnel: TunnelController
    let model: AgentAppModel
    var runner = ""
    var target = ""
    var heartbeat = true

    init(tunnel: TunnelController, model: AgentAppModel) { (self.tunnel, self.model) = (tunnel, model) }

    var tunnelInstalled: Bool { tunnel.installed }
    var hasPairing: Bool { PairingStore.isPresent }
    var runnerConfigured: Bool { !runner.trimmingCharacters(in: .whitespaces).isEmpty }
    var targetConfigured: Bool { !target.trimmingCharacters(in: .whitespaces).isEmpty }
    var modelProblem: String? { model.modelProblem }

    var tunnelConnected: Bool { tunnel.status == .connected }
    func startTunnel() async throws {
        let span = AgentDiag.begin("tunnel.start")
        tunnel.start()
        guard await wait(seconds: 20, until: { self.tunnel.status == .connected }) else {
            span.end([("connected", .bool(false))])
            throw StartFlowError.step("El túnel no conectó" + (tunnel.lastError.isEmpty ? "" : ": \(tunnel.lastError)"))
        }
        span.end([("connected", .bool(true))])
    }

    var sessionOpen: Bool { model.session != nil }
    func openSession() async throws { try await model.openSessionNow(runner: runner, heartbeat: heartbeat) }
    func dropSession() { model.dropSession() }
    func observe() async throws { try await model.observeNow(target: target) }

    func startTask(task: String, mode: RunMode, onEnd: @escaping @MainActor (String?) -> Void) -> Bool {
        model.run(task: task, target: target, mode: mode == .live ? .live : .dryRun, onEnd: onEnd)
    }
    func stopTask() { AgentDiag.event("start.stop_task"); model.stopRun() }
    func runWillPrepare() { model.beginActivity() }
    func runDidNotStart(_ end: RunEnd) { Task { await model.endActivity(end) } }

    private func wait(seconds: Double, until ok: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !ok() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return true
    }
}

/// Main screen: the task, the start (Inicio or the target app), the mode and one Iniciar / Detener. Setup the OS or
/// the operator must do (VPN consent, pairing import, model sign-in) is listed until done; diagnostics live in
/// "Avanzado". Every tap and keystroke goes through WDA.
struct MainScreen: View {
    @StateObject private var tunnel: TunnelController
    @StateObject private var model: AgentAppModel
    @StateObject private var flow: StartCoordinator
    private let steps: AppStartSteps

    @AppStorage("agentTask") private var task = ""
    @AppStorage("runnerBundleID") private var runnerBundleID = "com.example.WebDriverAgentRunner"
    @AppStorage("targetBundleID") private var targetBundleID = "com.apple.Preferences"
    @AppStorage("heartbeat") private var heartbeat = true
    @AppStorage("liveMode") private var live = false

    @State private var hasPairing = PairingStore.isPresent
    @State private var importing = false
    @State private var importError = ""
    @State private var advanced = false
    @State private var confirmingLive = false

    init() {
        let t = TunnelController(), m = AgentAppModel()
        let s = AppStartSteps(tunnel: t, model: m)
        _tunnel = StateObject(wrappedValue: t)
        _model = StateObject(wrappedValue: m)
        _flow = StateObject(wrappedValue: StartCoordinator(steps: s))
        steps = s
    }

    private var mode: RunMode { live ? .live : .dryRun }

    var body: some View {
        NavigationStack {
            Form {
                SetupSection(tunnel: tunnel, model: model, hasPairing: hasPairing, importing: $importing,
                             importError: importError)
                Section {
                    TextField("¿Qué debe hacer el agente?", text: $task, axis: .vertical)
                        .lineLimit(2...5)
                        .disabled(flow.busy)
                    Picker("Empezar en", selection: $model.startAtHome) {
                        Text("Inicio").tag(true)
                        Text(Self.shortName(targetBundleID)).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(flow.busy)
                    if model.startAtHome {
                        Picker("Abrir apps", selection: $model.launchMethod) {
                            Text("Tocando su icono").tag(LaunchMethod.icon)
                            Text("Activación directa").tag(LaunchMethod.activate)
                        }
                        .disabled(flow.busy)
                    }
                    if !model.startAtHome { LabeledContent("App objetivo", value: Self.appName(targetBundleID)) }
                    Picker("Modo", selection: $live) {
                        Text("Prueba (sin toques)").tag(false)
                        Text("Real (toques WDA)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(flow.busy)
                    Toggle("Audio silencioso en segundo plano (experimental)", isOn: $model.backgroundAudio)
                        .disabled(flow.busy)
                    if model.backgroundAudio || model.audioState != .off {
                        Text(Self.audioNote(model.audioState)).font(.caption)
                            .foregroundStyle(model.audioState == .active ? .green : .secondary)
                    }
                    if flow.busy {
                        Button(role: .destructive) { flow.stop() } label: {
                            Label(flow.phase == .stopping ? "Deteniendo…" : "Detener", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(flow.phase == .stopping)
                    } else {
                        Button { iniciar() } label: {
                            Label(live ? "Iniciar (modo real)" : "Iniciar prueba", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } footer: {
                    Text(footer)
                }
                StatusSection(flow: flow, model: model)
            }
            .navigationTitle("Agente")
            .toolbar {
                Button { advanced = true } label: { Label("Avanzado", systemImage: "gearshape") }
            }
            .sheet(isPresented: $advanced) {
                AdvancedView(tunnel: tunnel, agent: model, flowBusy: flow.busy, hasPairing: $hasPairing,
                             runnerBundleID: $runnerBundleID, targetBundleID: $targetBundleID, heartbeat: $heartbeat)
            }
            .confirmationDialog("¿Iniciar en modo real?", isPresented: $confirmingLive, titleVisibility: .visible) {
                Button("Iniciar: hará toques WDA en \(scopeName)") {
                    flow.confirm(task: task, target: scopeTarget, mode: .live)
                    begin()
                }
            } message: {
                Text("El agente tocará la pantalla y escribirá con WDA en \(scopeName) para esta tarea. Mira el iPhone; Detener lo para en cualquier momento. No se vuelve a preguntar para la misma tarea y app.")
            }
            .task { await tunnel.refresh() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .xml, .data]) { result in
                do { try PairingStore.importCopy(from: result.get()); importError = "" } catch {
                    importError = "No se importó: \(error.localizedDescription)"
                }
                hasPairing = PairingStore.isPresent
            }
        }
    }

    /// What a live run may touch: the selected app, or from Inicio the Home Screen and the app it opens.
    private var scopeName: String {
        model.startAtHome ? "Inicio y las apps que pida la tarea" : Self.appName(targetBundleID)
    }

    /// The scope string the confirmation is bound to: Inicio and the selected app are different scopes.
    private var scopeTarget: String { model.startAtHome ? "inicio:\(model.launchMethod.rawValue)" : targetBundleID }

    private var footer: String {
        let start = model.startAtHome
            ? "Empieza en Inicio (botón Inicio vía WDA), abre la app pedida y sigue la app que de verdad está en primer plano. \"Abrir X\" solo abre la app, confirma y para: no lee su contenido."
            : "Trabaja solo en \(Self.appName(targetBundleID))."
        return live ? "Modo real: toques y escritura WDA directos. " + start + " Mira el iPhone mientras trabaja."
                    : "Prueba: el agente mira la pantalla y decide el primer toque, pero no envía nada a WDA. " + start
    }

    private func iniciar() {
        if flow.needsConfirmation(task: task, target: scopeTarget, mode: mode) { confirmingLive = true } else { begin() }
    }

    private func begin() {
        steps.runner = runnerBundleID
        steps.target = targetBundleID
        steps.heartbeat = heartbeat
        flow.start(task: task, target: scopeTarget, mode: mode)
    }

    /// Experimental silence: what it does and its current state. It is not guaranteed, and the Live Activity
    /// gives no execution time.
    static func audioNote(_ s: BackgroundAudioKeeper.State) -> String {
        let what = "Solo durante una tarea: silencio local que se mezcla con tu audio, sin micrófono. Experimental: iOS puede pausar la app igualmente; la Isla Dinámica no da tiempo de ejecución."
        switch s {
        case .off: return what
        case .active: return "Audio silencioso activo. " + what
        case .lost(let why): return "El audio silencioso se detuvo (\(why)); la tarea se detuvo sin repetir nada."
        }
    }

    static func shortName(_ id: String) -> String {
        ["com.apple.Preferences": "Ajustes", "net.whatsapp.WhatsApp": "WhatsApp", "com.apple.mobilesafari": "Safari"][id] ?? "App objetivo"
    }

    static func appName(_ id: String) -> String {
        let known = ["com.apple.Preferences": "Ajustes", "net.whatsapp.WhatsApp": "WhatsApp", "com.apple.mobilesafari": "Safari"]
        return known[id].map { "\($0) (\(id))" } ?? id
    }
}

/// First-time setup: only what iOS or the operator has to do. Hidden once everything is done.
private struct SetupSection: View {
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var model: AgentAppModel
    let hasPairing: Bool
    @Binding var importing: Bool
    let importError: String

    var body: some View {
        let modelOK = model.modelProblem == nil
        if !tunnel.installed || !hasPairing || !modelOK {
            Section {
                row(tunnel.installed, "VPN local del agente") {
                    Button("Añadir VPN (iOS pide permiso)") { Task { await tunnel.install() } }
                }
                if !tunnel.lastError.isEmpty { Text(tunnel.lastError).font(.caption).foregroundStyle(.red) }
                row(hasPairing, "Registro de emparejamiento") {
                    Button("Importar desde Archivos…") { importing = true }
                }
                if !importError.isEmpty { Text(importError).font(.caption).foregroundStyle(.red) }
                ModelSetupRow(model: model)
            } header: { Text("Configuración inicial") }
        }
    }

    @ViewBuilder private func row<A: View>(_ ok: Bool, _ title: String, @ViewBuilder action: () -> A) -> some View {
        Label(title, systemImage: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .primary)
        if !ok { action() }
    }
}

/// The model backend: the ChatGPT plan sign-in (Debug) or the API-key endpoint, which is set in Avanzado.
private struct ModelSetupRow: View {
    @ObservedObject var model: AgentAppModel

    var body: some View {
        let ok = model.modelProblem == nil
        Label(model.usesChatGPTPlan ? "Modelo: plan de ChatGPT" : "Modelo: endpoint con tu clave API",
              systemImage: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .primary)
        if !ok {
            #if DEBUG
            ChatGPTSetup(model: model, account: model.chatGPT)
            #else
            Text("Configura la URL, el modelo y tu clave en Avanzado › 5.").font(.caption)
            #endif
        }
    }
}

#if DEBUG
private struct ChatGPTSetup: View {
    @ObservedObject var model: AgentAppModel
    @ObservedObject var account: ChatGPTAccount

    var body: some View {
        if !model.useChatGPTPlan {
            Text("Configura tu clave API en Avanzado › 5, o usa el plan de ChatGPT:").font(.caption)
        }
        if let c = account.credential, c.signedIn, c.planEnabled {
            if !model.useChatGPTPlan { Button("Usar el plan de ChatGPT") { model.useChatGPTPlan = true } }
            if model.chatGPTModelID.isEmpty {
                Button("Cargar modelos del plan") { model.loadChatGPTModels() }
                if !model.chatGPTStatus.isEmpty { Text(model.chatGPTStatus).font(.caption) }
            }
        } else if let c = account.credential, c.signedIn {
            Button("Iniciar sesión de nuevo y permitir el uso del plan") { Task { await account.signIn(consent: true) } }
                .disabled(account.busy)
        } else {
            Button("Continuar con ChatGPT") { Task { await account.signIn() } }.disabled(account.busy)
        }
        if let e = account.error { Text(e).font(.caption).foregroundStyle(.red) }
    }
}
#endif

/// Readiness and progress, in plain words; real blockers are listed, never hidden.
private struct StatusSection: View {
    @ObservedObject var flow: StartCoordinator
    @ObservedObject var model: AgentAppModel

    var body: some View {
        Section("Estado") {
            switch flow.phase {
            case .idle: Text("Listo para iniciar.").foregroundStyle(.secondary)
            case .preparing(let s): Label(Self.name(s), systemImage: "hourglass")
            case .running: Label("Trabajando… (el progreso se ve en la Isla Dinámica, que no mantiene la app activa)", systemImage: "play.circle")
            case .stopping: Label("Deteniendo cuando termine el paso en curso…", systemImage: "stop.circle")
            case .stopped: Label("Detenido.", systemImage: "stop.circle")
            case .finished(let o): Label(o ?? "Terminado.", systemImage: "flag.checkered")
            case .failed(let why): Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            case .blocked(let list):
                ForEach(list, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            }
            if !flow.done.isEmpty {
                Text(flow.done.map(Self.done).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Text("Toques y escritura: WDA directo (POST /wda/tap en el centro del elemento, /wda/keys en el campo con foco). Un fallo o resultado incierto detiene la tarea, sin reintentos.")
                .font(.caption).foregroundStyle(.secondary)
            Text(BuildStamp.line(bundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                                 executableDate: (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                                 libVersion: UniRunner.version,
                                 storedSourceConfig: UserDefaults.standard.string(forKey: WDASourcePreset.defaultsKey),
                                 openSessionConfig: model.session?.sourceConfig))
                .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let a = model.agent { RunSummary(agent: a) }
        }
    }

    static func name(_ s: StartCoordinator.Step) -> String {
        switch s {
        case .tunnel: return "Conectando la VPN local…"
        case .session: return "Abriendo la sesión WDA (15–90 s)…"
        case .observe: return "Mirando la app objetivo…"
        case .task: return "Iniciando la tarea…"
        }
    }

    static func done(_ s: StartCoordinator.Step) -> String {
        switch s {
        case .tunnel: return "VPN ✓"
        case .session: return "WDA ✓"
        case .observe: return "App vista ✓"
        case .task: return "Tarea ✓"
        }
    }
}

private struct RunSummary: View {
    @ObservedObject var agent: TaskAgent
    var body: some View {
        ForEach(agent.events.suffix(3)) { e in
            Text("\(e.kind.rawValue): \(e.text)").font(.caption2.monospaced()).lineLimit(3)
                .foregroundStyle(e.kind == .error || e.kind == .blocked ? .red : .secondary)
        }
    }
}
