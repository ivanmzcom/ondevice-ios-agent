import Foundation

/// Technical limits of the WDA tap and typing gates.
public struct GatePolicy: Equatable, Sendable {
    /// A tap or typing request is only allowed on an observation at most this old (seconds).
    public var maxObservationAge: TimeInterval = 2.0
    public init() {}
}

/// Orientations WDA reports that the tap and typing gates accept; any other value (empty, FACEUP, …) is refused.
public enum WDAOrientation {
    public static let known: Set<String> = ["PORTRAIT", "LANDSCAPE", "UIA_DEVICE_ORIENTATION_LANDSCAPERIGHT",
                                            "UIA_DEVICE_ORIENTATION_PORTRAIT_UPSIDEDOWN"]
}

public enum CoordinateTransform {
    /// WDA point (window points) -> screen fraction; nil for an empty window.
    public static func fraction(_ p: WDAPoint, in window: WDASize) -> WDAPoint? {
        guard window.width > 0, window.height > 0 else { return nil }
        return WDAPoint(x: p.x / window.width, y: p.y / window.height)
    }
}

/// How a step proves it worked, on a fresh observation taken after the tap or typing request.
public enum Expectation: Equatable, Sendable {
    /// This element exists (e.g. the next screen's title).
    case elementPresent(TargetSelector)
    /// The source tree differs from the one the target was picked on.
    case sourceChanged
}

/// Post-action verification shared by the WDA tap, typing and cross-app steps.
public enum StepVerification {
    public enum Result: Equatable, Sendable {
        case verified
        case notVerified(String)
    }

    /// Verified only on an observation newer than the action, of `bundleID`, in the foreground, that meets `expect`.
    public static func verify(_ after: WDAObservation, expect: Expectation, before: WDAObservation, bundleID: String,
                              actedAt: Date) -> Result {
        guard after.capturedAt > actedAt else { return .notVerified("observation is older than the click") }
        guard after.bundleID == bundleID else { return .notVerified("observation is of \(after.bundleID)") }
        guard after.foreground else { return .notVerified("\(bundleID) is not in the foreground") }
        switch expect {
        case .sourceChanged:
            return after.sourceDigest != before.sourceDigest ? .verified : .notVerified("screen did not change")
        case .elementPresent(let s):
            return after.elements.contains(where: s.matches) ? .verified : .notVerified("expected element not found")
        }
    }
}
