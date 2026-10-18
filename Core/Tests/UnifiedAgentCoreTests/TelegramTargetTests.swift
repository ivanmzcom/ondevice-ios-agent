import XCTest
@testable import UnifiedAgentCore

/// Synthetic Telegram-like search screen (no real data). The result row is modelled as an untyped `Other` with a
/// label: a plausible source for the "found but not tappable" screenshot, not an observed node type.
final class TelegramTargetTests: XCTestCase {
    let win = WDASize(width: 390, height: 844)
    let now = Date(timeIntervalSince1970: 1_000)
    func el(_ type: String, _ label: String?, _ f: WDARect, id: String? = nil, enabled: Bool = true,
            visible: Bool = true) -> UIElementSnapshot {
        UIElementSnapshot(type: "XCUIElementType" + type, identifier: id, label: label, frame: f, enabled: enabled, visible: visible)
    }
    func obs(_ extra: [UIElementSnapshot], digest: String = "d1") -> WDAObservation {
        WDAObservation(bundleID: "ph.telegra.Telegraph", windowSize: win,
                       elements: [el("Application", "Telegram", WDARect(x: 0, y: 0, width: 390, height: 844)),
                                  el("SearchField", "Search", WDARect(x: 10, y: 60, width: 370, height: 36))] + extra,
                       sourceDigest: digest, capturedAt: now)
    }
    let row = WDARect(x: 0, y: 200, width: 390, height: 60)
    let keyboard = WDARect(x: 0, y: 500, width: 390, height: 344)

    func testOtherResultRowIsCoordinateTargetNotControl() {
        let o = obs([el("Other", "Test Contact", row), el("Button", "Cancel", WDARect(x: 320, y: 60, width: 60, height: 36))])
        let items = ElementPrompt.list(o).items
        let r = items.first { $0.element.label == "Test Contact" }!
        XCTAssertEqual(r.kind, .coordinate); XCTAssertTrue(r.tappable)
        XCTAssertEqual(items.first { $0.element.label == "Cancel" }!.kind, .control)
        XCTAssertEqual(items.first { $0.element.label == "Telegram" }!.kind, .none, "the app container is not a target")
        let text = ElementPrompt.render(task: "open the chat", observation: o, list: ElementPrompt.list(o), history: [])
        XCTAssertTrue(text.contains(" c Other \"Test Contact\""), text)
        XCTAssertTrue(text.contains(" t Btn \"Cancel\""), text)
        XCTAssertTrue(ElementPrompt.system.contains("marked t or c"))
    }

    func testSelectionUsesOriginalFrameAndGatePlansItsCentre() throws {
        let o = obs([el("Other", "Test Contact", row)])
        let t = try TargetSelection.select(TargetSelector(label: "Test Contact"), in: o).get()
        XCTAssertEqual(t.element.frame, row)
        XCTAssertEqual(t.center.x, 0.5, accuracy: 1e-9); XCTAssertEqual(t.center.y, 230 / 844, accuracy: 1e-9)
        let plan = try WDATapGate.evaluate(target: t, observation: o, expectedBundleID: "ph.telegra.Telegraph", now: now).get()
        XCTAssertEqual(plan.point, WDAPoint(x: 195, y: 230))
        // fresh-snapshot identity still enforced: a target from another source tree is refused
        guard case .failure(let b) = WDATapGate.evaluate(target: t, observation: obs([el("Other", "Test Contact", row)], digest: "d2"),
                                                         expectedBundleID: "ph.telegra.Telegraph", now: now) else { return XCTFail() }
        XCTAssertTrue(b.reasons.contains(.targetFromOtherObservation))
    }

    func testTextInsideRowKeepsExistingTextSelection() throws {
        let text = WDARect(x: 70, y: 210, width: 200, height: 20)
        let o = obs([el("Other", "Test Contact", row), el("StaticText", "Test Contact", text)])
        let t = try TargetSelection.select(TargetSelector(label: "Test Contact"), in: o).get()
        XCTAssertEqual(t.element.type, "XCUIElementTypeStaticText", "typed match wins; Other only when nothing typed matches")
        XCTAssertTrue(row.contains(t.element.frame.center))
        XCTAssertEqual(ElementPrompt.list(o).items.filter { $0.element.label == "Test Contact" }.map(\.kind), [.coordinate])
    }

    func testDuplicateLabelsAmbiguousUnlessContextDiffers() {
        let a = WDARect(x: 0, y: 200, width: 390, height: 60), b = WDARect(x: 0, y: 270, width: 390, height: 60)
        let o = obs([el("Other", "Test Contact", a), el("Other", "Test Contact", b)])
        XCTAssertEqual(TargetSelection.select(TargetSelector(label: "Test Contact"), in: o), .failure(.ambiguous(2)))
        let o2 = obs([el("Other", "Test Contact", a, id: "chat-1"), el("Other", "Test Contact", b, id: "chat-2")])
        XCTAssertEqual(try TargetSelection.select(TargetSelector(identifier: "chat-2", label: "Test Contact"), in: o2).get().element.frame, b)
    }

    func testHiddenDisabledOffscreenKeyboardAndHugeRejected() {
        let o = obs([
            el("Other", "Hidden", row, visible: false),
            el("Other", "Disabled", row, enabled: false),
            el("Other", "Offscreen", WDARect(x: 0, y: 900, width: 390, height: 60)),
            el("Keyboard", nil, keyboard),
            el("Other", "Suggestion", WDARect(x: 10, y: 510, width: 100, height: 40)),
            el("StaticText", "KeyText", WDARect(x: 120, y: 510, width: 100, height: 40)),
            el("Other", "Results", WDARect(x: 0, y: 100, width: 390, height: 700)),
            el("Other", nil, WDARect(x: 0, y: 300, width: 390, height: 60), id: "unlabelled"),
        ])
        let items = ElementPrompt.list(o).items
        for l in ["Hidden", "Disabled", "Offscreen", "Suggestion", "KeyText", "Results"] {
            XCTAssertFalse(items.contains { $0.element.label == l && $0.tappable }, l)
        }
        XCTAssertFalse(items.contains { $0.element.identifier == "unlabelled" && $0.tappable })
        func sel(_ l: String) -> Result<SelectedTarget, SelectionError> { TargetSelection.select(TargetSelector(label: l), in: o) }
        XCTAssertEqual(sel("Hidden"), .failure(.notVisible))
        XCTAssertEqual(sel("Disabled"), .failure(.disabled))
        guard case .failure = sel("Offscreen") else { return XCTFail("offscreen selected") }
        guard case .failure(.notTargetable) = sel("Suggestion") else { return XCTFail("keyboard Other selected") }
        guard case .failure(.notTargetable) = sel("KeyText") else { return XCTFail("keyboard text selected") }
        guard case .failure(.notTargetable) = sel("Results") else { return XCTFail("container selected") }
        guard case .failure(.notTargetable) = TargetSelection.select(TargetSelector(identifier: "unlabelled"), in: o) else {
            return XCTFail("unlabelled Other selected")
        }
    }
}
