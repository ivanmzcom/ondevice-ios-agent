import Foundation

// Direct WDA tap backend, the app's only input path. WDA observes AND taps: one
// `POST /session/{id}/wda/tap {"x","y"}` (WebDriverAgent v16.15.3 `FBElementCommands.m` `handleTap:`, no element:
// the session's active app, coordinate offset from its (0, 0) = window points) at the centre of an element picked
// from a fresh source tree. A failed or uncertain tap is never retried by another route, never replayed and never
// reopens the session.

/// How one tap failed, by whether it may have reached the screen.
public enum WDATapError: Error, Equatable, LocalizedError {
    /// Nothing was written to WDA.
    case notSent(String)
    /// WDA refused before tapping (HTTP 4xx, including an unknown session).
    case rejected(String)
    /// Written, but no clear answer: it may have landed. Stop; never replay.
    case uncertain(String)

    public var errorDescription: String? {
        switch self {
        case .notSent(let m): return "WDA tap not sent: \(m)"
        case .rejected(let m): return "WDA refused the tap: \(m)"
        case .uncertain(let m): return "WDA tap result uncertain: \(m)"
        }
    }
}

/// Sends exactly one direct WDA tap. Implementations never retry and never use another route or device.
public protocol WDATapSink: AnyObject {
    func tap(at point: WDAPoint, window: WDASize) async throws
}

/// Why a WDA tap is not allowed now. Every reason is reported.
public enum WDATapBlock: Equatable, Sendable {
    case observationStale
    case observationAppMismatch(expected: String, got: String)
    case appNotForeground
    case targetFromOtherObservation
    case unknownOrientation(String)
    /// The centre is not strictly inside the observed window: refused, never clamped.
    case outOfBounds
    /// Typing: no visible keyboard in the bound app's fresh observation, so nothing has keyboard focus.
    case noKeyboard
    /// Typing: the text itself cannot be typed in one request (empty, too long, newline/control characters).
    case untypableText(String)
}

public struct WDATapBlocked: Error, Equatable, Sendable { public var reasons: [WDATapBlock] }

/// One tap at `point` (window points of `window`, as observed in `orientation`).
public struct WDATapPlan: Equatable, Sendable {
    public var point: WDAPoint
    public var window: WDASize
    public var orientation: String
    public var summary: String {
        String(format: "POST /session/{id}/wda/tap {\"x\":%.1f,\"y\":%.1f} (window %.0fx%.0f %@)", point.x, point.y,
               window.width, window.height, orientation)
    }
}

public enum WDATapGate {
    /// Allowed only on a fresh foreground observation of the expected app that the target was picked from, with a
    /// known orientation and a centre strictly inside the window. Technical checks only: what to tap is decided by
    /// the user's task and the model (and its provider's policies), not by app or word lists here.
    public static func evaluate(target: SelectedTarget, observation obs: WDAObservation, expectedBundleID: String,
                                now: Date, policy: GatePolicy = GatePolicy()) -> Result<WDATapPlan, WDATapBlocked> {
        var blocks: [WDATapBlock] = []
        if obs.bundleID != expectedBundleID || target.bundleID != expectedBundleID {
            blocks.append(.observationAppMismatch(expected: expectedBundleID, got: obs.bundleID))
        }
        if !obs.foreground { blocks.append(.appNotForeground) }
        let age = now.timeIntervalSince(obs.capturedAt)
        if age > policy.maxObservationAge || age < -1 { blocks.append(.observationStale) }
        if target.sourceDigest != obs.sourceDigest || target.windowSize != obs.windowSize {
            blocks.append(.targetFromOtherObservation)
        }
        if !WDAOrientation.known.contains(obs.orientation) { blocks.append(.unknownOrientation(obs.orientation)) }
        let p = target.element.frame.center
        let w = obs.windowSize
        if !(p.x.isFinite && p.y.isFinite && w.width > 0 && w.height > 0 && 0 < p.x && p.x < w.width && 0 < p.y && p.y < w.height) {
            blocks.append(.outOfBounds)
        }
        guard blocks.isEmpty else { return .failure(WDATapBlocked(reasons: blocks)) }
        return .success(WDATapPlan(point: p, window: w, orientation: obs.orientation))
    }
}

public enum WDATapStepOutcome: Equatable, Sendable {
    case observationFailed(String)
    case selectionFailed(SelectionError)
    case blocked([WDATapBlock])
    case tapNotSent(String)
    case tapRejected(String)
    /// The tap may have landed. Not replayed, no fallback, no session change.
    case tapUncertain(String)
    case verified
    case notVerified(String)
    case alreadyConsumed
}

public struct WDATapStepReport: Equatable, Sendable {
    public var outcome: WDATapStepOutcome
    public var before: WDAObservation?
    public var target: SelectedTarget?
    public var plan: WDATapPlan?
    /// Tap requests handed to the sink (0 or 1).
    public var taps = 0
    public var after: WDAObservation?
    /// The pre-action check used: a full fresh observation (default) or the targeted revalidation.
    public var preAct: WDAPreActPath = .full("full fresh observation")
    public var revalidation: WDATargetRevalidationInfo? = nil
}

/// One navigation tap over WDA: fresh observe -> select -> gate -> one tap at the element centre (window points)
/// -> fresh observation to verify. Single use; anything that could recover (a new session, a new observation)
/// happens only before the tap.
@MainActor public final class WDATapNavigationStep {
    public let bundleID: String
    let provider: WDAObservationProvider
    let tapper: WDATapSink
    let policy: GatePolicy
    let clock: () -> Date
    private(set) var consumed = false

    public init(bundleID: String, provider: WDAObservationProvider, tapper: WDATapSink, policy: GatePolicy = GatePolicy(),
                clock: @escaping () -> Date = Date.init) {
        self.bundleID = bundleID; self.provider = provider; self.tapper = tapper; self.policy = policy; self.clock = clock
    }

    public func run(tap selector: TargetSelector, expect: Expectation) async -> WDATapStepReport {
        await run(expect: expect) { TargetSelection.select(selector, in: $0) }
    }

    /// The element the model chose, re-resolved on the fresh observation (`TargetSelection.resolve`).
    public func run(tap ref: TargetRef, expect: Expectation) async -> WDATapStepReport {
        await run(expect: expect) { TargetSelection.resolve(ref, in: $0) }
    }

    private func run(expect: Expectation, resolve: (WDAObservation) -> Result<SelectedTarget, SelectionError>) async -> WDATapStepReport {
        var report = WDATapStepReport(outcome: .alreadyConsumed)
        guard !consumed else { return report }

        let before: WDAObservation
        do { before = try await provider.observe(targetBundleID: bundleID) } catch {
            report.outcome = .observationFailed(error.localizedDescription)
            return report
        }
        report.before = before
        let target: SelectedTarget
        switch resolve(before) {
        case .failure(let e): report.outcome = .selectionFailed(e); return report
        case .success(let t): target = t
        }
        report.target = target
        let plan: WDATapPlan
        switch WDATapGate.evaluate(target: target, observation: before, expectedBundleID: bundleID, now: clock(), policy: policy) {
        case .failure(let b): report.outcome = .blocked(b.reasons); return report
        case .success(let p): plan = p
        }
        report.plan = plan

        // from here on WDA may have been touched: never again for this step
        consumed = true
        report.taps = 1
        do {
            try await tapper.tap(at: plan.point, window: plan.window)
        } catch WDATapError.notSent(let m) {
            report.outcome = .tapNotSent(m); return report
        } catch WDATapError.rejected(let m) {
            report.outcome = .tapRejected(m); return report
        } catch {
            report.outcome = .tapUncertain(error.localizedDescription); return report
        }
        let acted = clock()

        let after: WDAObservation
        do { after = try await provider.observe(targetBundleID: bundleID) } catch {
            report.outcome = .notVerified("no observation after the tap: \(error.localizedDescription)")
            return report
        }
        report.after = after
        if after.windowSize != before.windowSize || after.orientation != before.orientation {
            report.outcome = .notVerified("window size / orientation changed after the tap")
            return report
        }
        switch StepVerification.verify(after, expect: expect, before: before, bundleID: bundleID, actedAt: acted) {
        case .verified: report.outcome = .verified
        case .notVerified(let why): report.outcome = .notVerified(why)
        }
        return report
    }
}

// MARK: Direct WDA typing

/// Sends exactly one direct WDA typing request (`POST /session/{id}/wda/keys`) into the focused field.
/// `WDATapError` semantics; only a refusal before anything was typed is `.rejected`, everything after the write
/// that is not a clear success is `.uncertain`. Never retried.
public protocol WDATextSink: AnyObject {
    func typeText(_ text: String) async throws
}

public enum WDATextGate {
    public static let maxCharacters = 500

    /// nil when `text` can be typed in one request. Newline/return and other control characters are refused: a
    /// typed return can submit or send, so submitting is always a separate, explicit tap.
    public static func textProblem(_ text: String) -> String? {
        if text.isEmpty { return "empty text" }
        if text.count > maxCharacters { return "longer than \(maxCharacters) characters" }
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0)
            || $0.properties.generalCategory == .lineSeparator || $0.properties.generalCategory == .paragraphSeparator }) {
            return "newline/return or control character; submit with a separate tap"
        }
        return nil
    }

    /// Allowed only on a fresh foreground observation of the expected app, with a known orientation and a visible
    /// keyboard (something has focus), for text that can be typed in one request.
    public static func evaluate(text: String, observation obs: WDAObservation, expectedBundleID: String, now: Date,
                                policy: GatePolicy = GatePolicy()) -> WDATapBlocked? {
        var blocks: [WDATapBlock] = []
        if obs.bundleID != expectedBundleID { blocks.append(.observationAppMismatch(expected: expectedBundleID, got: obs.bundleID)) }
        if !obs.foreground { blocks.append(.appNotForeground) }
        let age = now.timeIntervalSince(obs.capturedAt)
        if age > policy.maxObservationAge || age < -1 { blocks.append(.observationStale) }
        if !WDAOrientation.known.contains(obs.orientation) { blocks.append(.unknownOrientation(obs.orientation)) }
        if !obs.elements.contains(where: { $0.type == "XCUIElementTypeKeyboard" && $0.visible }) { blocks.append(.noKeyboard) }
        if let why = textProblem(text) { blocks.append(.untypableText(why)) }
        return blocks.isEmpty ? nil : WDATapBlocked(reasons: blocks)
    }
}

/// One typing step: fresh observation of the bound app -> gate (keyboard visible) -> one `/wda/keys` -> fresh
/// observation of the same app to verify the screen changed. Single use; never retyped, no fallback.
@MainActor public final class WDATypeStep {
    public let bundleID: String
    let observe: () async throws -> WDAObservation
    let sink: WDATextSink
    let policy: GatePolicy
    let clock: () -> Date
    private(set) var consumed = false

    public init(bundleID: String, observe: @escaping () async throws -> WDAObservation, sink: WDATextSink,
                policy: GatePolicy = GatePolicy(), clock: @escaping () -> Date = Date.init) {
        self.bundleID = bundleID; self.observe = observe; self.sink = sink; self.policy = policy; self.clock = clock
    }

    public func run(text: String) async -> WDATapStepReport {
        var report = WDATapStepReport(outcome: .alreadyConsumed)
        guard !consumed else { return report }
        let before: WDAObservation
        do { before = try await observe() } catch {
            report.outcome = .observationFailed(error.localizedDescription); return report
        }
        report.before = before
        if let b = WDATextGate.evaluate(text: text, observation: before, expectedBundleID: bundleID, now: clock(), policy: policy) {
            report.outcome = .blocked(b.reasons); return report
        }
        consumed = true
        report.taps = 1
        do { try await sink.typeText(text) } catch WDATapError.notSent(let m) {
            report.outcome = .tapNotSent(m); return report
        } catch WDATapError.rejected(let m) {
            report.outcome = .tapRejected(m); return report
        } catch {
            report.outcome = .tapUncertain(error.localizedDescription); return report
        }
        let acted = clock()
        let after: WDAObservation
        do { after = try await observe() } catch {
            report.outcome = .notVerified("no observation after typing: \(error.localizedDescription)"); return report
        }
        report.after = after
        if after.bundleID != bundleID || after.windowSize != before.windowSize || after.orientation != before.orientation {
            report.outcome = .notVerified("app, window size or orientation changed after typing"); return report
        }
        switch StepVerification.verify(after, expect: .sourceChanged, before: before, bundleID: bundleID, actedAt: acted) {
        case .verified: report.outcome = .verified
        case .notVerified(let why): report.outcome = .notVerified(why)
        }
        return report
    }
}
