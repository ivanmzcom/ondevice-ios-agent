import Foundation

// Bounded Spotlight fallback for a launch from Inicio when the requested app's icon is not on the visible Home page
// (SPOTLIGHT_REPORT.md). Only routes the runner already uses: one `/wda/tap` on SpringBoard's visible Search button,
// one `/wda/keys` with the app name, one `/wda/tap` on the result the model chose. Every observation in between is
// read-only and bound to the Spotlight overlay host; a written mutation is never replayed, and an uncertain, ambiguous
// or empty result stops the run without a tap. No app list: any app name is searched, and the model picks the result.

public enum SpotlightOverlay {
    /// Bundles `activeAppInfo` may report while Spotlight is up: SpringBoard itself, or the Spotlight app (iOS
    /// version dependent; unverified on the device, see the report). Moving between these is not an app change.
    public static let hostBundleIDs: Set<String> = [SpringBoard.bundleID, "com.apple.Spotlight"]
    static let searchLabels: Set<String> = ["search", "buscar", "spotlight"]

    /// SpringBoard's visible Search button (Home Screen "Search" pill): not an app icon, label or identifier says
    /// search. Exactly one, or none is used.
    static func searchButtons(_ obs: WDAObservation) -> [UIElementSnapshot] {
        obs.elements.filter { e in
            guard e.visible, e.type != "XCUIElementTypeIcon", e.type != "XCUIElementTypeKeyboard" else { return false }
            let names = [e.label, e.identifier].compactMap { $0.map(KnownApps.fold) }
            return names.contains { searchLabels.contains($0) || $0.hasPrefix("spotlight") }
        }
    }

    static func keyboardUp(_ obs: WDAObservation) -> Bool {
        obs.elements.contains { $0.type == "XCUIElementTypeKeyboard" && $0.visible }
    }

    /// The result label names the app: equal to it (case/accents ignored) or the name followed by more words
    /// ("WhatsApp, App"), or a known alias of it.
    static func labelNames(_ label: String?, _ name: String) -> Bool {
        guard let label else { return false }
        if KnownApps.label(label, names: name) { return true }
        let l = KnownApps.fold(label), n = KnownApps.fold(name)
        return !n.isEmpty && l.hasPrefix(n + " ")
    }
}

/// What the model answered for the Spotlight results: the listed element to tap, or why none fits.
public enum SpotlightChoice: Equatable, Sendable {
    case tap(Int)
    case none(String)
}

/// Shows the model the Spotlight result hierarchy (the same numbered list the agent uses) and returns its choice.
/// A thrown error (model failure, cancellation) stops the fallback without a tap.
public typealias SpotlightChooser = @MainActor (_ appName: String, _ observation: WDAObservation,
                                                _ list: ElementPrompt.CandidateList) async throws -> SpotlightChoice

@MainActor struct SpotlightFallback {
    let driver: WDACrossAppDriver
    let tapper: WDATapSink
    let text: WDATextSink
    let chooser: SpotlightChooser
    let policy: GatePolicy
    let settle: SettlePolicy
    let clock: () -> Date

    /// Polls read-only (`observeForeground(nil)`, never an input) until `done`; a foreground outside the overlay
    /// hosts ends the wait at once.
    func await_(_ done: (WDAObservation) -> Bool) async throws -> WDAObservation {
        var o = try await driver.observeForeground(expected: nil)
        var n = 1
        while !done(o) && SpotlightOverlay.hostBundleIDs.contains(o.bundleID) && n < max(1, settle.attempts) {
            if settle.delayNanos > 0 { try? await Task.sleep(nanoseconds: settle.delayNanos) }
            o = try await driver.observeForeground(expected: nil)
            n += 1
        }
        return o
    }

    /// From a fresh SpringBoard observation `home` with no icon for the app: Search -> type the name once -> the
    /// model picks a result -> one tap -> the launched bundle.
    func run(_ intent: LaunchIntent, home: WDAObservation, dryRun: Bool,
             log: (AgentEvent.Kind, String) -> Void) async -> CrossAppLauncher.Result {
        let name = intent.appName
        let buttons = SpotlightOverlay.searchButtons(home)
        guard buttons.count == 1, let button = buttons.first else {
            return .stopped("no veo el icono de \(name) en la página visible ni \(buttons.isEmpty ? "un" : "un único") botón Buscar de Spotlight; nada enviado")
        }
        let selector = TargetSelector(identifier: button.identifier, label: button.label)
        if dryRun {
            return .dryRun("no veo el icono de \(name); abriría Spotlight (tocar \"\(button.label ?? "Buscar")\"), escribiría \"\(name)\" una vez y el modelo elegiría el resultado. Nada enviado")
        }
        if Task.isCancelled { return .stopped("detenido por el usuario; nada enviado") }
        // 1. One tap on the Search button, on a fresh SpringBoard observation (gate unchanged).
        let fresh: WDAObservation
        do { fresh = try await driver.observeForeground(expected: SpringBoard.bundleID) } catch {
            return .failed("observación de Inicio fallida: \(error.localizedDescription)")
        }
        let plan: WDATapPlan
        switch TargetSelection.select(selector, in: fresh) {
        case .failure(let e): return .stopped("botón Buscar no utilizable: \(e); nada enviado")
        case .success(let t):
            switch WDATapGate.evaluate(target: t, observation: fresh, expectedBundleID: SpringBoard.bundleID, now: clock(), policy: policy) {
            case .failure(let b): return .stopped("puerta WDA cerrada, nada enviado: " + b.reasons.map { "\($0)" }.joined(separator: ", "))
            case .success(let p): plan = p
            }
        }
        if let why = await tapOnce(plan, what: "Buscar") { return .failed(why) }
        log(.act, "WDA tap Buscar (Spotlight): " + plan.summary)
        // 2. Wait read-only for the overlay with the keyboard up; bind to whichever host reports it.
        let overlay: WDAObservation
        do { overlay = try await await_(SpotlightOverlay.keyboardUp) } catch {
            return .failed("Spotlight no observable tras tocar Buscar: \(error.localizedDescription); no se repite")
        }
        guard SpotlightOverlay.hostBundleIDs.contains(overlay.bundleID) else {
            return .failed("tras tocar Buscar la app en primer plano es \(overlay.bundleID); se detiene")
        }
        guard SpotlightOverlay.keyboardUp(overlay) else {
            return .failed("Spotlight no mostró el teclado tras tocar Buscar; no se repite")
        }
        let host = overlay.bundleID
        log(.verify, "Spotlight abierto (\(host), teclado visible)")
        // 3. Type the app name once (WDATypeStep: gate, one /wda/keys, fresh verification of the same host).
        if Task.isCancelled { return .stopped("detenido por el usuario; Spotlight abierto, nada escrito") }
        let typeStep = WDATypeStep(bundleID: host, observe: { [driver] in try await driver.observeForeground(expected: host) },
                                   sink: text, policy: policy, clock: clock)
        let typed = await typeStep.run(text: name)
        if typed.taps > 0 { log(.act, "WDA keys (\(host)): POST /session/{id}/wda/keys, \(name.count) characters") }
        switch typed.outcome {
        case .verified: break
        case .blocked(let r): return .stopped("escritura en Spotlight rechazada, nada escrito: " + r.map { "\($0)" }.joined(separator: ", "))
        case .tapNotSent(let m): return .failed("escritura no enviada (\(m)); no se reintenta")
        case .tapRejected(let m): return .failed("WDA rechazó la escritura (\(m)); no se reintenta")
        case .tapUncertain(let m): return .failed("escritura incierta (\(m)); no se reescribe")
        case .notVerified(let m): return .failed("escritura sin confirmar: \(m); no se reescribe")
        case .observationFailed(let m): return .failed("observación de Spotlight fallida: \(m)")
        case .selectionFailed, .alreadyConsumed: return .failed("internal: unexpected typing outcome")
        }
        // 4. Results may still be filling in: read-only wait until some visible element names the app.
        let results: WDAObservation
        do {
            results = try await await_ { o in o.elements.contains { $0.visible && SpotlightOverlay.labelNames($0.label, name) } }
        } catch { return .failed("observación de resultados fallida: \(error.localizedDescription)") }
        guard results.bundleID == host else { return .failed("los resultados de Spotlight se leyeron en \(results.bundleID), no \(host); se detiene") }
        // 5. The model sees the result hierarchy and picks the app; Core checks the pick names the app.
        let list = ElementPrompt.list(results)
        let choice: SpotlightChoice
        do { choice = try await chooser(name, results, list) } catch {
            return .failed("elección del resultado fallida (\(error.localizedDescription)); Spotlight abierto, nada tocado")
        }
        if Task.isCancelled { return .stopped("detenido por el usuario; nada tocado en Spotlight") }
        let i: Int
        switch choice {
        case .none(let why): return .stopped("Spotlight no muestra \(name) sin ambigüedad (\(why)); nada tocado")
        case .tap(let n): i = n
        }
        let cands = list.items
        guard cands.indices.contains(i), cands[i].tappable, SpotlightOverlay.labelNames(cands[i].element.label, name),
              let ref = cands[i].sourceIndex.flatMap({ TargetRef(elementIndex: $0, in: results) }) else {
            return .stopped("el resultado elegido (#\(i)) no es un elemento tocable que nombre \(name); nada tocado")
        }
        log(.think, "Spotlight: el modelo eligió #\(i) \"\(cands[i].element.label ?? "")\"")
        // 6. One tap on the chosen result, re-resolved on a fresh observation of the host; a launch is allowed.
        let step = CrossAppTapStep(bound: host, driver: driver, tapper: tapper, policy: policy, settle: settle, clock: clock)
        step.launchAllowed = true
        let r = await step.run(tap: ref, expect: .sourceChanged)
        if let p = r.plan, r.taps > 0 { log(.act, "WDA tap resultado (\(host)): " + p.summary) }
        switch r.outcome {
        case .launched(let b) where !SpotlightOverlay.hostBundleIDs.contains(b):
            if let want = intent.bundleID, want != b { return .failed("se abrió \(b), no \(want); se detiene sin tocar nada más") }
            log(.verify, "primer plano: \(b) (activeAppInfo)")
            return .launched(b)
        case .launched(let b): return .failed("tras tocar el resultado sigue en primer plano \(b); no se repite")
        case .selectionFailed(let e): return .stopped("el resultado cambió antes de tocarlo (\(e)); nada tocado")
        case .blocked(let b): return .stopped("puerta WDA cerrada, nada enviado: " + b.map { "\($0)" }.joined(separator: ", "))
        case .observationFailed(let m): return .failed("observación fallida: \(m)")
        case .tapNotSent(let m): return .failed("toque no enviado (\(m)); no se reintenta")
        case .tapRejected(let m): return .failed("WDA rechazó el toque (\(m)); no se reintenta")
        case .tapUncertain(let m): return .failed("resultado del toque incierto (\(m)); no se repite")
        case .notVerified(let m): return .failed("toque enviado sin confirmar: \(m); no se repite")
        case .foregroundChanged(let b): return .failed("la app en primer plano cambió a \(b); se detiene")
        case .verified, .alreadyConsumed: return .failed("el resultado tocado no abrió ninguna app; no se repite")
        }
    }

    /// One tap, never retried; nil on success.
    private func tapOnce(_ plan: WDATapPlan, what: String) async -> String? {
        do { try await tapper.tap(at: plan.point, window: plan.window) } catch WDATapError.notSent(let m) {
            return "toque en \(what) no enviado (\(m)); no se reintenta"
        } catch WDATapError.rejected(let m) {
            return "WDA rechazó el toque en \(what) (\(m)); no se reintenta"
        } catch { return "resultado del toque en \(what) incierto (\(error.localizedDescription)); no se repite" }
        return nil
    }
}
