import SwiftUI
import UnifiedAgentCore

@main
struct UnifiedAgentApp: App {
    var body: some Scene {
        WindowGroup { MainScreen() }
    }
}

/// "Avanzado": the former single screen (diagnostics, one-shot probe/observe, raw output, runner/target ids,
/// WDA session, model). The one-shot observe launches a second runner, which kills the
/// persistent session (WDA_SESSION_DIAGNOSIS.md), so it is disabled while that session is open or a start runs.
struct AdvancedView: View {
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var agent: AgentAppModel
    let flowBusy: Bool
    @Binding var hasPairing: Bool
    @Binding var runnerBundleID: String
    @Binding var targetBundleID: String
    @Binding var heartbeat: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var importing = false
    @State private var busy = false
    @State private var status = ""
    @State private var observation = ""

    private var oneShotBlocked: Bool { agent.session != nil || agent.sessionBusy || flowBusy }

    var body: some View {
        NavigationStack {
            Form {
                Section("Last failure (kept after session drop/close)") {
                    if let f = agent.lastFailure {
                        Text(f.text).font(.footnote.monospaced()).textSelection(.enabled)
                        Button("Clear last failure", role: .destructive) { agent.clearLastFailure() }
                    } else {
                        Text(agent.lastFailureNote.isEmpty ? "none" : agent.lastFailureNote).font(.footnote)
                    }
                }
                Section("1. Loopback tunnel (in-app packet tunnel)") {
                    LabeledContent("Status", value: tunnel.statusText)
                    if !tunnel.installed {
                        Button("Install VPN configuration…") { Task { await tunnel.install() } }
                    } else {
                        Button("Start tunnel") { tunnel.start() }
                            .disabled(tunnel.status == .connected || tunnel.status == .connecting)
                        Button("Stop tunnel") { tunnel.stop() }
                            .disabled(tunnel.status != .connected)
                        Button("Remove configuration", role: .destructive) { Task { await tunnel.remove() } }
                    }
                    if !tunnel.lastError.isEmpty { Text(tunnel.lastError).font(.footnote).foregroundStyle(.red) }
                }
                Section("2. Pairing record") {
                    Text(hasPairing ? "Imported (private storage)" : "Not imported")
                    Button("Import via Files…") { importing = true }
                    if hasPairing {
                        Button("Delete imported record", role: .destructive) {
                            try? PairingStore.delete()
                            hasPairing = PairingStore.isPresent
                        }
                    }
                }
                Section("3. Developer services + one-shot observation (diagnostic)") {
                    TextField("WDA runner bundle id (…xctrunner)", text: $runnerBundleID)
                    TextField("Target app bundle id", text: $targetBundleID)
                    LabeledContent("Device IP (tunnel peer)", value: PacketTunnelKeys.defaultPeer)
                    Toggle("Hold heartbeat (experiment)", isOn: $heartbeat)
                    Button("Probe lockdown through tunnel") { run(observe: false) }
                    Button("One-shot observe (own runner launch)") { run(observe: true) }
                        .disabled(runnerBundleID.isEmpty || targetBundleID.isEmpty || oneShotBlocked)
                    if oneShotBlocked {
                        Text("Disabled while the persistent WDA session is open or Iniciar is running: a second runner launch ends that session.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Developer Disk Image mounting is not implemented here; the signed WDA runner is a separate install.")
                        .font(.caption)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!hasPairing || busy)
                SourcePresetSection(openSessionConfig: agent.session?.sourceConfig)
                AgentSections(model: agent, runner: runnerBundleID, target: targetBundleID, heartbeat: heartbeat,
                              hasPairing: hasPairing, flowBusy: flowBusy)
                if busy { ProgressView() }
                if !status.isEmpty { Section("One-shot status") { Text(status).font(.footnote.monospaced()) } }
                if !observation.isEmpty { Section("One-shot observation") { Text(observation).font(.caption2.monospaced()) } }
                Section { Text(UniRunner.version).font(.caption2) }
            }
            .navigationTitle("Avanzado")
            .toolbar { Button("Cerrar") { dismiss() } }
            .onChange(of: agent.session != nil) { _, open in
                // A one-shot result is not the state of the persistent session.
                if open { status = ""; observation = "" }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .xml, .data]) { result in
                do {
                    try PairingStore.importCopy(from: result.get())
                    status = "Pairing record imported."
                } catch {
                    status = "Import failed: \(error.localizedDescription)"
                }
                hasPairing = PairingStore.isPresent
            }
        }
    }

    private func run(observe: Bool) {
        guard !(observe && oneShotBlocked) else { return }
        busy = true
        status = observe ? "Launching WDA runner (15–90 s)…" : "Probing…"
        observation = ""
        let runner = runnerBundleID, target = targetBundleID, hb = heartbeat
        let peer = PacketTunnelKeys.defaultPeer
        if tunnel.status != .connected { status += "\nwarning: in-app tunnel is \(tunnel.statusText)" }
        Task {
            defer { busy = false }
            guard let pairing = try? PairingStore.load() else { return status = "Could not read imported pairing record." }
            let r = observe
                ? await UniRunner.observe(pairing: pairing, deviceIP: peer, runner: runner, target: target, heartbeat: hb)
                : await UniRunner.probe(pairing: pairing, deviceIP: peer)
            switch r {
            case .success(let json): (status, observation) = Self.summarize(json)
            case .failure(let f): status = "FAILED (\(f.code)): \(f.json)"
            }
        }
    }

    /// Short summary only; the hierarchy and screenshot stay in memory.
    static func summarize(_ json: String) -> (String, String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return ("OK (unparsed)", "")
        }
        guard o["stage"] as? String == "observe" else { return ("OK: \(json)", "") }
        let xml = o["source_xml"] as? String ?? ""
        let png = o["screenshot_png_b64"] as? String ?? ""
        return ("OK: \(o["target_bundle_id"] ?? "?") foreground (state \(o["app_state_before"] ?? "?")→\(o["app_state_after"] ?? "?"))",
                "window \(o["window_size"] ?? "?"), \(o["orientation"] ?? "?")\nhierarchy \(xml.count) chars, screenshot \(png.count * 3 / 4) bytes\nheartbeat \(o["heartbeat"] ?? "off")")
    }
}

/// Preset for the WDA `/source` timeout levers, persisted under `WDASourcePreset.defaultsKey`. Applied when the WDA
/// session opens; changing it never opens, closes or starts anything.
struct SourcePresetSection: View {
    let openSessionConfig: String?
    @State private var stored = UserDefaults.standard.string(forKey: WDASourcePreset.defaultsKey)
    @State private var observer = UserDefaults.standard.string(forKey: WDAObserver.defaultsKey)

    private static func name(_ config: String?) -> String {
        WDASourcePreset.matching(stored: config)?.title ?? "Personalizada"
    }

    var body: some View {
        Section("Lectura de pantalla WDA (/source)") {
            Picker("Preset", selection: Binding(
                get: { WDASourcePreset.matching(stored: stored)?.rawValue ?? "custom" },
                set: { raw in
                    guard let p = WDASourcePreset(rawValue: raw) else { return }
                    UserDefaults.standard.set(p.configJSON, forKey: WDASourcePreset.defaultsKey)
                    stored = p.configJSON
                })) {
                ForEach(WDASourcePreset.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                if WDASourcePreset.matching(stored: stored) == nil { Text("Personalizada").tag("custom") }
            }
            Picker("Observador", selection: Binding(
                get: { WDAObserver.stored(observer) },
                set: { o in
                    UserDefaults.standard.set(o.rawValue, forKey: WDAObserver.defaultsKey)
                    observer = o.rawValue
                })) {
                ForEach(WDAObserver.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            if WDAObserver.stored(observer) == .compact {
                Text("Requiere el runner WDA con la ruta /hermes/observation. Si no está, la observación falla; no vuelve a XML.")
                    .font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("Elegida", value: Self.name(stored) + (stored == nil ? " (por defecto)" : ""))
            let next = WDAObserver.stored(observer).apply(to: WDASourcePreset.effectiveConfig(stored: stored))
            Text(next).font(.caption2.monospaced())
            if let open = openSessionConfig {
                LabeledContent("Sesión abierta", value: Self.name(open))
                if open != next {
                    Text("Cierra y vuelve a abrir la sesión WDA para aplicar este preset.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Se aplica al abrir la próxima sesión WDA.").font(.caption)
            }
        }
    }
}
