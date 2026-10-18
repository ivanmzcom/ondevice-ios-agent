import XCTest
@testable import UnifiedAgentCore

// Spotlight fallback for a launch from Inicio when the icon is not on the visible Home page: Search tap -> the name
// typed once -> the model picks a result -> one tap -> the launched app verified. Visible icon path unchanged; no tap
// on an ambiguous/empty result; nothing replayed after an error or cancellation.

private let sb = SpringBoard.bundleID
private let spot = "com.apple.Spotlight"
private let wa = "net.whatsapp.WhatsApp"

private func node(_ type: String, _ label: String, y: Double, h: Double = 80) -> String {
    "<\(type) type=\"\(type)\" name=\"\(label)\" label=\"\(label)\" enabled=\"true\" visible=\"true\" x=\"100\" y=\"\(y)\" width=\"190\" height=\"\(h)\"/>"
}
private func app(_ name: String, _ nodes: [String]) -> String {
    "<XCUIElementTypeApplication type=\"XCUIElementTypeApplication\" name=\"\(name)\" label=\"\(name)\" enabled=\"true\" visible=\"true\" x=\"0\" y=\"0\" width=\"390\" height=\"844\">"
        + nodes.joined() + "</XCUIElementTypeApplication>"
}
private let keyboard = "<XCUIElementTypeKeyboard type=\"XCUIElementTypeKeyboard\" enabled=\"true\" visible=\"true\" x=\"0\" y=\"600\" width=\"390\" height=\"240\"/>"
private let searchPill = node("XCUIElementTypeButton", "Buscar", y: 520, h: 30)
private let homeWithWA = app("SpringBoard", [node("XCUIElementTypeIcon", "WhatsApp", y: 200), node("XCUIElementTypeIcon", "Ajustes", y: 400), searchPill])
private let homeNoWA = app("SpringBoard", [node("XCUIElementTypeIcon", "Ajustes", y: 400), searchPill])
private let homeNoPill = app("SpringBoard", [node("XCUIElementTypeIcon", "Ajustes", y: 400)])
private let spotEmpty = app("Spotlight", [node("XCUIElementTypeSearchField", "Buscar", y: 60, h: 40), keyboard])
private let spotResults = app("Spotlight", [node("XCUIElementTypeSearchField", "WhatsApp", y: 60, h: 40),
                                            node("XCUIElementTypeStaticText", "Mejor resultado", y: 110, h: 20),
                                            node("XCUIElementTypeIcon", "WhatsApp", y: 140),
                                            node("XCUIElementTypeCell", "Buscar en la web", y: 300), keyboard])
private let spotNoResults = app("Spotlight", [node("XCUIElementTypeSearchField", "WhatsApp", y: 60, h: 40),
                                              node("XCUIElementTypeCell", "Buscar en la web", y: 300), keyboard])
private let waChats = app("WhatsApp", [node("XCUIElementTypeCell", "Ana", y: 200)])

private func observation(_ bundle: String, _ x: String) -> WDAObservation {
    WDAObservation(bundleID: bundle, windowSize: WDASize(width: 390, height: 844), elements: try! WDASource.elements(x),
                   sourceDigest: WDASource.digest(x) + UUID().uuidString, capturedAt: Date())
}

/// Scripted phone: the foreground app and its screen; taps/typing advance a script.
private final class Phone: WDAForegroundSource, WDANavigationSink, WDAObservationProvider, WDATapSink, WDATextSink {
    var foreground = sb
    var screens: [String: String]
    var calls: [String] = []
    var typed: [String] = []
    var onTap: [(Phone) -> Void] = []
    var onType: (Phone) -> Void = { _ in }
    var tapErrors: [Error?] = []
    var typeError: Error?
    init(_ screens: [String: String]) { self.screens = screens }
    var mutations: [String] { calls.filter { $0.hasPrefix("tap") || $0 == "pressHome" || $0.hasPrefix("activate(") || $0 == "type" } }

    func activeApp() async throws -> String { calls.append("activeApp"); return foreground }
    func observeForeground(expected: String?) async throws -> WDAObservation {
        calls.append("observeForeground(\(expected ?? "nil"))")
        if let expected, expected != foreground {
            throw ObservationDecodeError(message: "foreground_mismatch: expected \(expected), foreground is \(foreground)")
        }
        return observation(foreground, screens[foreground] ?? app("x", []))
    }
    func observe(targetBundleID: String) async throws -> WDAObservation { calls.append("activate+observe"); return observation(targetBundleID, "") }
    func pressHome() async throws { calls.append("pressHome"); foreground = sb }
    func activate(bundleID: String) async throws { calls.append("activate(\(bundleID))") }
    func tap(at point: WDAPoint, window: WDASize) async throws {
        calls.append(String(format: "tap(%.0f,%.0f)", point.x, point.y))
        if !tapErrors.isEmpty, let e = tapErrors.removeFirst() { throw e }
        if !onTap.isEmpty { onTap.removeFirst()(self) }
    }
    func typeText(_ text: String) async throws {
        calls.append("type"); typed.append(text)
        if let typeError { throw typeError }
        onType(self)
    }
}

/// Answers the Spotlight choice by finding the listed line with `pick`'s exact quoted label (or a fixed reply).
@MainActor private final class Model: ChatModel {
    let model = "fake"
    var prompts: [String] = []
    var pick: String?
    var pickType = "Icon"
    var reply: String?
    var error: Error?
    var then: [String] = []
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        prompts.append(text)
        if let error { throw error }
        if text.contains("Spotlight search results") {
            if let reply { return ChatResult(text: reply, firstToken: nil, total: 0) }
            let line = text.split(separator: "\n").first { $0.contains("\"\(pick ?? "")\"") && $0.first?.isNumber == true && $0.contains(pickType) }
            let n = line.map { String($0.prefix { $0.isNumber }) } ?? "99"
            return ChatResult(text: "THINK: the app result\nDO: tap \(n)", firstToken: nil, total: 0)
        }
        return ChatResult(text: then.isEmpty ? "THINK: x\nDO: done ok" : then.removeFirst(), firstToken: nil, total: 0)
    }
}

/// Search tap opens the overlay on `host` (keyboard up); typing shows `results`; the next tap launches WhatsApp.
private func spotlightPhone(host: String = spot, results: String = spotResults, home: String = homeNoWA) -> Phone {
    let p = Phone([sb: home, wa: waChats])
    p.onTap = [
        { p in p.foreground = host; p.screens[host] = spotEmpty },
        { p in p.foreground = wa },
    ]
    p.onType = { p in p.screens[host] = results }
    return p
}

@MainActor final class SpotlightTests: XCTestCase {
    private let fast = SettlePolicy(attempts: 3, delayNanos: 0)

    private func agent(_ p: Phone, _ m: Model, typing: Bool = true) -> TaskAgent {
        let a = TaskAgent(provider: p, model: m, tapper: p, policy: GatePolicy())
        a.crossApp = CrossAppConfig(driver: p, settle: fast)
        if typing { a.wdaText = p }
        return a
    }

    func testVisibleIconFastPathUnchanged() async {
        let p = Phone([sb: homeWithWA]); p.onTap = [{ p in p.foreground = wa }]
        let m = Model()
        let out = await agent(p, m).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
        XCTAssertTrue(out.hasPrefix("done: WhatsApp abierta"), out)
        XCTAssertEqual(p.mutations, ["pressHome", "tap(195,240)"])
        XCTAssertTrue(p.typed.isEmpty)
        XCTAssertTrue(m.prompts.isEmpty, "no model call on the icon path")
    }

    func testMissingIconSearchesSpotlightOnceAndModelPicksApp() async {
        for host in [spot, sb] {
            let p = spotlightPhone(host: host)
            let m = Model(); m.pick = "WhatsApp"
            let out = await agent(p, m).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
            XCTAssertTrue(out.hasPrefix("done: WhatsApp abierta en primer plano (\(wa))"), "\(host): \(out)")
            XCTAssertEqual(p.mutations, ["pressHome", "tap(195,535)", "type", "tap(195,180)"], host)
            XCTAssertEqual(p.typed, ["WhatsApp"])
            XCTAssertEqual(m.prompts.count, 1)
            XCTAssertTrue(m.prompts[0].contains("Buscar en la web") && m.prompts[0].contains("Mejor resultado"), "model sees the results")
            XCTAssertFalse(p.calls.contains("observeForeground(\(wa))"), "launch-only: WhatsApp not read")
        }
    }

    func testOpenThenContinuesInVerifiedForegroundApp() async {
        let p = spotlightPhone()
        let m = Model(); m.pick = "WhatsApp"; m.then = ["THINK: done\nDO: done chats visible"]
        let out = await agent(p, m).run(task: "Abre WhatsApp y dime los chats", bundleID: sb, mode: .live)
        XCTAssertEqual(out, "done: chats visible")
        XCTAssertTrue(p.calls.contains("observeForeground(\(wa))"), "first look is bound to the verified app")
        XCTAssertEqual(p.mutations.count, 4)
    }

    func testAmbiguousOrWrongPickIsNotTapped() async {
        for reply in ["THINK: two apps match\nDO: fail ambiguous", "web", "THINK: x\nDO: wait"] {
            let p = spotlightPhone()
            let m = Model()
            // "web": the model picks the "Buscar en la web" row; Core refuses it (label does not name the app).
            if reply == "web" { m.pick = "Buscar en la web"; m.pickType = "Cell" } else { m.reply = reply }
            let out = await agent(p, m).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
            XCTAssertEqual(p.mutations, ["pressHome", "tap(195,535)", "type"], reply)
            XCTAssertFalse(out.hasPrefix("done"), out)
        }
    }

    func testNoResultsWaitsReadOnlyThenNoBlindTap() async {
        let p = spotlightPhone(results: spotNoResults)
        let m = Model(); m.pick = "WhatsApp"
        let out = await agent(p, m).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
        XCTAssertEqual(p.mutations, ["pressHome", "tap(195,535)", "type"])
        XCTAssertEqual(p.typed.count, 1)
        XCTAssertTrue(out.contains("nada tocado"), out)
    }

    func testErrorsAndCancellationAreNotReplayed() async {
        // Search tap uncertain: nothing typed, no second tap.
        var p = spotlightPhone(); p.tapErrors = [WDATapError.uncertain("timeout")]
        var out = await agent(p, Model()).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
        XCTAssertEqual(p.mutations, ["pressHome", "tap(195,535)"]); XCTAssertTrue(out.contains("no se repite"), out)
        // Typing uncertain: not retyped, nothing tapped.
        p = spotlightPhone(); p.typeError = WDATapError.uncertain("timeout")
        out = await agent(p, Model()).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
        XCTAssertEqual(p.mutations, ["pressHome", "tap(195,535)", "type"]); XCTAssertTrue(out.contains("no se reescribe"), out)
        // Model error / cancellation during the choice: no result tap.
        for e: Error in [CancellationError(), URLError(.timedOut)] {
            p = spotlightPhone()
            let m = Model(); m.error = e
            out = await agent(p, m).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
            XCTAssertEqual(p.mutations, ["pressHome", "tap(195,535)", "type"]); XCTAssertTrue(out.contains("nada tocado"), out)
        }
        // Result tap uncertain: not replayed.
        p = spotlightPhone(); p.tapErrors = [nil, WDATapError.uncertain("timeout")]
        let m = Model(); m.pick = "WhatsApp"
        out = await agent(p, m).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
        XCTAssertEqual(p.mutations.count, 4); XCTAssertTrue(out.contains("no se repite"), out)
    }

    func testForegroundAfterResultTapIsVerified() async {
        // Result tap leaves Spotlight in front: not a launch, no retap.
        let p = spotlightPhone(); p.onTap[1] = { _ in }
        let m = Model(); m.pick = "WhatsApp"
        var out = await agent(p, m).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
        XCTAssertEqual(p.mutations.count, 4); XCTAssertFalse(out.hasPrefix("done"), out)
        // A known app name that opens another bundle: refused.
        let q = spotlightPhone(); q.onTap[1] = { p in p.foreground = "com.example.Other" }
        out = await agent(q, m).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
        XCTAssertTrue(out.contains("no \(wa)"), out)
        // An app outside KnownApps: no list needed; the model's labelled pick and the real foreground decide.
        let r = Phone([sb: homeNoWA]); r.onTap = [{ p in p.foreground = spot; p.screens[spot] = spotEmpty }, { p in p.foreground = "com.example.Lumen" }]
        r.onType = { p in p.screens[spot] = spotResults.replacingOccurrences(of: "\"WhatsApp\"", with: "\"Lumen\"") }
        let n = Model(); n.pick = "Lumen"
        out = await agent(r, n).run(task: "Abrir Lumen", bundleID: sb, mode: .live)
        XCTAssertTrue(out.hasPrefix("done: Lumen abierta en primer plano (com.example.Lumen)"), out)
        XCTAssertEqual(r.typed, ["Lumen"])
    }

    func testNoSearchButtonNoTypingOrDryRunSendNothingExtra() async {
        let p = spotlightPhone(home: homeNoPill)
        var out = await agent(p, Model()).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
        XCTAssertEqual(p.mutations, ["pressHome"]); XCTAssertTrue(out.contains("Buscar"), out)
        let q = spotlightPhone()
        out = await agent(q, Model(), typing: false).run(task: "Abrir WhatsApp", bundleID: sb, mode: .live)
        XCTAssertEqual(q.mutations, ["pressHome"]); XCTAssertTrue(out.contains("no veo el icono"), out)
        let r = spotlightPhone()
        out = await agent(r, Model()).run(task: "Abrir WhatsApp", bundleID: sb, mode: .dryRun)
        XCTAssertEqual(r.mutations, []); XCTAssertTrue(out.contains("Spotlight"), out)
    }

    func testSpringBoardToSpotlightTapInAgentLoopRebindsNotMismatch() async {
        // The model itself taps Search in the generic loop: SpringBoard -> Spotlight host is a rebind, not a stop.
        let p = Phone([sb: homeNoWA]); p.onTap = [{ p in p.foreground = spot; p.screens[spot] = spotEmpty }]
        let m = Model(); m.then = ["THINK: search\nDO: tap 1", "THINK: ok\nDO: done in spotlight"]
        let out = await agent(p, m).run(task: "busca algo", bundleID: sb, mode: .live)
        XCTAssertEqual(out, "done: in spotlight", "\(m.prompts.first ?? "")")
        XCTAssertTrue(p.calls.contains("observeForeground(\(spot))"))
    }
}
