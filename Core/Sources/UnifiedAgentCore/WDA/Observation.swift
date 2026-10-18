import Foundation

/// WDA geometry is in points of the target's window (origin top-left), never mouse units.
public struct WDAPoint: Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { (self.x, self.y) = (x, y) }
}

public struct WDASize: Equatable, Sendable, Codable {
    public var width: Double, height: Double
    public init(width: Double, height: Double) { (self.width, self.height) = (width, height) }
}

public struct WDARect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }
    public var center: WDAPoint { WDAPoint(x: x + width / 2, y: y + height / 2) }
    public func contains(_ p: WDAPoint) -> Bool { x <= p.x && p.x <= x + width && y <= p.y && p.y <= y + height }
}

/// One node of the WDA source tree (`/source`, XML).
public struct UIElementSnapshot: Equatable, Sendable {
    public var type: String  // XCUIElementTypeButton, …
    public var identifier: String?  // `name` in WDA XML
    public var label: String?
    public var value: String?
    public var frame: WDARect
    public var enabled: Bool
    public var visible: Bool

    public init(type: String, identifier: String? = nil, label: String? = nil, value: String? = nil, frame: WDARect,
                enabled: Bool = true, visible: Bool = true) {
        self.type = type; self.identifier = identifier; self.label = label; self.value = value
        self.frame = frame; self.enabled = enabled; self.visible = visible
    }
}

/// One state-preserving, app-bound WDA observation (the unified app's `uni_observe`).
public struct WDAObservation: Equatable, Sendable {
    /// XCUIApplicationState.runningForeground
    public static let runningForeground = 4

    public var bundleID: String
    public var appStateBefore: Int
    public var appStateAfter: Int
    public var windowSize: WDASize
    public var orientation: String
    public var elements: [UIElementSnapshot]
    /// Identifies this source tree: a target picked on one observation is only valid for that observation.
    public var sourceDigest: String
    public var capturedAt: Date
    /// Set only for observations read through the compact observer (runner identity, counts, timings).
    public var provenance: WDACompactProvenance? = nil

    public init(bundleID: String, appStateBefore: Int = runningForeground, appStateAfter: Int = runningForeground,
                windowSize: WDASize, orientation: String = "PORTRAIT", elements: [UIElementSnapshot],
                sourceDigest: String, capturedAt: Date) {
        self.bundleID = bundleID; self.appStateBefore = appStateBefore; self.appStateAfter = appStateAfter
        self.windowSize = windowSize; self.orientation = orientation; self.elements = elements
        self.sourceDigest = sourceDigest; self.capturedAt = capturedAt
    }

    /// Foreground both before and after the source was read (the app did not change under us).
    public var foreground: Bool { appStateBefore == Self.runningForeground && appStateAfter == Self.runningForeground }
}

/// Supplies observations; the unified app implements it over its WDA runner (see `fromUnifiedObserveJSON`).
/// It must not relaunch or reset the target (no `bundleId` session), or post-action verification means nothing.
public protocol WDAObservationProvider: AnyObject {
    func observe(targetBundleID: String) async throws -> WDAObservation
}

public struct ObservationDecodeError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

extension WDAObservation {
    /// Decode the JSON `uni_observe` returns (unified-ffi, `OBSERVATION_SCHEMA`): target_bundle_id,
    /// app_state_before/after, window_size {width, height}, orientation, source_xml, source_unix_ms.
    /// The screenshot is ignored: targets come from the source tree, not pixels.
    /// The tree is `source_xml` or, from the compact observer, `source_compact` (`WDACompactSource`). With `observer`
    /// given, the other kind is refused: the observer the operator chose is never replaced silently.
    public static func fromUnifiedObserveJSON(_ data: Data, observer: WDAObserver? = nil) throws -> WDAObservation {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ObservationDecodeError(message: "observation is not a JSON object")
        }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        guard let bundle = o["target_bundle_id"] as? String else { throw ObservationDecodeError(message: "no target_bundle_id") }
        guard let before = num(o["app_state_before"]), let after = num(o["app_state_after"]) else {
            throw ObservationDecodeError(message: "no app state")
        }
        var win = o["window_size"] as? [String: Any]
        if let inner = win?["value"] as? [String: Any] { win = inner }  // a raw WDA reply
        guard let w = num(win?["width"]), let h = num(win?["height"]), w > 0, h > 0 else {
            throw ObservationDecodeError(message: "no window_size")
        }
        guard let ms = num(o["source_unix_ms"]) else { throw ObservationDecodeError(message: "no source_unix_ms") }
        var orientation = (o["orientation"] as? String) ?? ""
        if let inner = o["orientation"] as? [String: Any], let v = inner["value"] as? String { orientation = v }
        switch (o["source_xml"], o["source_compact"]) {
        case (nil, let compact as [String: Any]):
            guard observer != .xml else { throw ObservationDecodeError(message: "compact source, but the XML observer was chosen") }
            let pid = num(o["foreground_pid"]).map { Int($0) }
            let d = try WDACompactSource.decode(compact, expectedBundleID: bundle, expectedPID: pid,
                                                window: WDASize(width: w, height: h), orientation: orientation)
            var obs = WDAObservation(bundleID: bundle, appStateBefore: Int(before), appStateAfter: Int(after),
                                     windowSize: WDASize(width: w, height: h), orientation: orientation,
                                     elements: d.elements, sourceDigest: d.digest,
                                     capturedAt: Date(timeIntervalSince1970: ms / 1000))
            obs.provenance = d.provenance
            return obs
        case (_?, _?):
            throw ObservationDecodeError(message: "both source_xml and source_compact")
        case (nil, _?):
            throw ObservationDecodeError(message: "source_compact is not an object")
        default:
            break
        }
        guard let xml = o["source_xml"] as? String else { throw ObservationDecodeError(message: "no source_xml") }
        guard observer != .compact else {
            throw ObservationDecodeError(message: "XML source, but the compact observer was chosen (no fallback)")
        }
        return WDAObservation(bundleID: bundle, appStateBefore: Int(before), appStateAfter: Int(after),
                              windowSize: WDASize(width: w, height: h), orientation: orientation,
                              elements: try WDASource.elements(xml), sourceDigest: WDASource.digest(xml),
                              capturedAt: Date(timeIntervalSince1970: ms / 1000))
    }
}

/// WDA `/source` XML: every node with a `type` attribute and a frame.
public enum WDASource {
    public static func elements(_ xml: String) throws -> [UIElementSnapshot] {
        let parser = XMLParser(data: Data(xml.utf8))
        let collector = Collector()
        parser.delegate = collector
        guard parser.parse() else {
            throw ObservationDecodeError(message: "source_xml: \(parser.parserError?.localizedDescription ?? "parse error")")
        }
        return collector.found
    }

    /// FNV-1a 64 of the XML: stable across runs (Swift's Hasher is seeded per process).
    public static func digest(_ xml: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in xml.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var found: [UIElementSnapshot] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String]) {
            guard let type = a["type"], let x = a["x"].flatMap(Double.init), let y = a["y"].flatMap(Double.init),
                  let w = a["width"].flatMap(Double.init), let h = a["height"].flatMap(Double.init) else { return }
            found.append(UIElementSnapshot(type: type, identifier: a["name"], label: a["label"], value: a["value"],
                                           frame: WDARect(x: x, y: y, width: w, height: h),
                                           enabled: a["enabled"] != "false", visible: a["visible"] == "true"))
        }
    }
}
