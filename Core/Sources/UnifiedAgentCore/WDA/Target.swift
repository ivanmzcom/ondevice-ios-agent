import Foundation

/// Which element to tap, by exact accessibility identifier and/or label. Any element a single tap at its centre
/// really operates can be chosen (buttons, cells, links, icons, switches, text fields to focus them). Elements a
/// centre tap does not operate (sliders, pickers, steppers need gestures; keyboard keys go through typing; an
/// alert container is not a control) are refused: a technical limit, not a judgement about what they do.
public struct TargetSelector: Equatable, Sendable {
    public var identifier: String?
    public var label: String?

    public init(identifier: String? = nil, label: String? = nil) { (self.identifier, self.label) = (identifier, label) }

    public static let navigationTypes: Set<String> = [
        "XCUIElementTypeCell", "XCUIElementTypeButton", "XCUIElementTypeLink", "XCUIElementTypeStaticText",
        // SpringBoard app icons: a tap launches the app; only CrossAppTapStep lets the bound app change after it.
        "XCUIElementTypeIcon",
        // one tap flips a switch or focuses a field (text then goes through the separate typing action)
        "XCUIElementTypeSwitch", "XCUIElementTypeToggle", "XCUIElementTypeTextField", "XCUIElementTypeSecureTextField",
        "XCUIElementTypeTextView", "XCUIElementTypeSearchField",
    ]
    /// Not operable by one centre tap (see above). Segmented controls are containers: their segments are buttons.
    public static let forbiddenTypes: Set<String> = [
        "XCUIElementTypeSlider", "XCUIElementTypeStepper", "XCUIElementTypePicker", "XCUIElementTypePickerWheel",
        "XCUIElementTypeSegmentedControl", "XCUIElementTypeKey", "XCUIElementTypeKeyboard", "XCUIElementTypeAlert",
    ]

    /// No control type, but a one-tap target by position when bounded (see `TargetKind.coordinate`). Only used when
    /// no control or text matches the selector, so it never changes which element an existing selector picks.
    public static let coordinateOnlyTypes: Set<String> = ["XCUIElementTypeOther"]
    /// A coordinate target larger than this share of the window is a container or backdrop, not one result.
    public static let maxCoordinateAreaFraction = 0.35

    /// What one centre tap on `e` (in `obs`) is known to do. Technical, not semantic: no app or word lists.
    public static func kind(of e: UIElementSnapshot, in obs: WDAObservation) -> TargetKind {
        guard e.enabled, e.visible, !forbiddenTypes.contains(e.type) else { return .none }
        if navigationTypes.contains(e.type), e.type != "XCUIElementTypeStaticText" { return .control }
        guard e.type == "XCUIElementTypeStaticText" || coordinateOnlyTypes.contains(e.type) else { return .none }
        guard let l = e.label, !l.isEmpty,
              coordinateBounded(e, in: obs, limitArea: e.type != "XCUIElementTypeStaticText") else { return .none }
        return .coordinate
    }

    /// Strictly inside the window, a bounded part of it (untyped rows only: long text stays listed as before), and not over a visible keyboard (keys and suggestions
    /// insert text: typing goes through the typing action only).
    static func coordinateBounded(_ e: UIElementSnapshot, in obs: WDAObservation, limitArea: Bool) -> Bool {
        let w = obs.windowSize, f = e.frame, c = f.center
        guard f.width > 0, f.height > 0, w.width > 0, w.height > 0, 0 < c.x, c.x < w.width, 0 < c.y, c.y < w.height,
              !limitArea || f.width * f.height <= maxCoordinateAreaFraction * w.width * w.height else { return false }
        return !obs.elements.contains { $0.type == "XCUIElementTypeKeyboard" && $0.visible && $0.frame.contains(c) }
    }

    func matches(_ e: UIElementSnapshot) -> Bool {
        guard identifier != nil || label != nil else { return false }
        if let identifier, e.identifier != identifier { return false }
        if let label, e.label != label { return false }
        return true
    }
}

/// `control`: a type one centre tap operates (button, cell, link, switch, field, icon). `coordinate`: no control
/// type (text, an untyped `Other` row such as a Telegram search result) but visible, enabled, labelled and bounded,
/// so a tap at its observed frame centre lands on what the model saw; whether that does anything is verified on the
/// next fresh observation. Neither is a claim about what the element means.
public enum TargetKind: Equatable, Sendable { case none, control, coordinate }

public enum SelectionError: Error, Equatable {
    case emptySelector
    case notFound
    case ambiguous(Int)
    case forbiddenType(String)
    case disabled
    case notVisible
    /// Centre outside the usable screen band (upstream ProbeFit.usable: 2%…98%).
    case offscreen
    /// A coordinate-only match (no control type) that is unlabelled, too large, or over the keyboard.
    case notTargetable(String)
    /// The element chosen among same-label siblings cannot be shown to be the same one on the fresh observation.
    case targetChanged(String)
}

/// The element the model chose by its number: the selector, plus the exact snapshot and position it had on the
/// observation the list was built from. On a fresh observation it resolves to that element or is refused:
/// - the selector alone was unambiguous on that observation: the selector decides, exactly as before;
/// - otherwise (same-label siblings): the element at the same position of a content-identical observation (same
///   digest), or, on a changed observation, only while every selector match is unchanged (same snapshots, frames and
///   order). A moved, added or vanished sibling is refused, never rebound by label or by a stale index.
public struct TargetRef: Equatable, Sendable {
    public var selector: TargetSelector
    public var element: UIElementSnapshot
    public var elementIndex: Int
    public var sourceDigest: String
    public var matches: [UIElementSnapshot]
    public var selectorUnique: Bool

    public init?(elementIndex i: Int, in obs: WDAObservation) {
        guard obs.elements.indices.contains(i) else { return nil }
        let e = obs.elements[i]
        selector = TargetSelector(identifier: e.identifier, label: e.label)
        element = e; elementIndex = i; sourceDigest = obs.sourceDigest
        matches = obs.elements.filter(selector.matches)
        if case .failure(.ambiguous) = TargetSelection.select(selector, in: obs) { selectorUnique = false } else { selectorUnique = true }
    }
}

/// A target on one observation, in screen fractions (0…1, origin top-left) of that observation's window.
public struct SelectedTarget: Equatable, Sendable {
    public var element: UIElementSnapshot
    public var center: WDAPoint  // fraction
    public var halfWidth: Double, halfHeight: Double  // fraction
    public var bundleID: String
    public var sourceDigest: String
    public var windowSize: WDASize
}

public enum TargetSelection {
    /// Deterministic: exactly one matching element, or a matching cell/button whose frame holds every other match
    /// (a cell and its own label); anything else is ambiguous rather than guessed.
    public static func select(_ selector: TargetSelector, in obs: WDAObservation) -> Result<SelectedTarget, SelectionError> {
        guard selector.identifier != nil || selector.label != nil else { return .failure(.emptySelector) }
        let all = obs.elements.filter(selector.matches)
        guard !all.isEmpty else { return .failure(.notFound) }
        if let bad = all.first(where: { TargetSelector.forbiddenTypes.contains($0.type) }) {
            return .failure(.forbiddenType(bad.type))
        }
        var matches = all.filter { TargetSelector.navigationTypes.contains($0.type) }
        // Coordinate-only rows count only when nothing typed matches: existing selectors pick exactly as before.
        let coordinateOnly = matches.isEmpty
        if coordinateOnly { matches = all.filter { TargetSelector.coordinateOnlyTypes.contains($0.type) } }
        guard !matches.isEmpty else { return .failure(.forbiddenType(all[0].type)) }
        let pick: UIElementSnapshot
        if matches.count == 1 {
            pick = matches[0]
        } else {
            let containers = matches.filter { m in
                m.type != "XCUIElementTypeStaticText" && matches.allSatisfy { m.frame.contains($0.frame.center) }
            }
            guard containers.count == 1 else { return .failure(.ambiguous(matches.count)) }
            pick = containers[0]
        }
        guard pick.visible else { return .failure(.notVisible) }
        guard pick.enabled else { return .failure(.disabled) }
        if pick.type == "XCUIElementTypeStaticText" || coordinateOnly {
            if coordinateOnly, pick.label?.isEmpty ?? true { return .failure(.notTargetable("no label")) }
            if TargetSelector.kind(of: pick, in: obs) != .coordinate {
                return .failure(.notTargetable("unbounded or over the keyboard"))
            }
        }
        return target(pick, in: obs)
    }

    /// `ref` on `obs` (see `TargetRef`). The exact pick gets the same checks a selected one does.
    public static func resolve(_ ref: TargetRef, in obs: WDAObservation) -> Result<SelectedTarget, SelectionError> {
        if ref.selectorUnique { return select(ref.selector, in: obs) }
        let samePlace = obs.sourceDigest == ref.sourceDigest && obs.elements.indices.contains(ref.elementIndex)
            && obs.elements[ref.elementIndex] == ref.element
        guard samePlace || obs.elements.filter(ref.selector.matches) == ref.matches else {
            return .failure(.targetChanged("same-label elements changed since the choice; not rebound by label"))
        }
        let pick = ref.element
        if TargetSelector.forbiddenTypes.contains(pick.type) { return .failure(.forbiddenType(pick.type)) }
        guard pick.visible else { return .failure(.notVisible) }
        guard pick.enabled else { return .failure(.disabled) }
        guard TargetSelector.kind(of: pick, in: obs) != .none else { return .failure(.notTargetable("not a tap target here")) }
        return target(pick, in: obs)
    }

    static func target(_ pick: UIElementSnapshot, in obs: WDAObservation) -> Result<SelectedTarget, SelectionError> {
        guard let c = CoordinateTransform.fraction(pick.frame.center, in: obs.windowSize),
              0.02 < c.x, c.x < 0.98, 0.02 < c.y, c.y < 0.98 else { return .failure(.offscreen) }
        return .success(SelectedTarget(element: pick, center: c, halfWidth: pick.frame.width / 2 / obs.windowSize.width,
                                       halfHeight: pick.frame.height / 2 / obs.windowSize.height, bundleID: obs.bundleID,
                                       sourceDigest: obs.sourceDigest, windowSize: obs.windowSize))
    }
}
