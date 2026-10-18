import Foundation
#if os(iOS)
import AVFoundation
#endif

// EXPERIMENTAL, opt-in (Main screen toggle): while an authorized task runs, a playback audio session that mixes with
// other audio loops locally generated silence, so iOS may keep this app running while the target app is in front.
// Not guaranteed: iOS can still interrupt or suspend the app. No microphone, no recording, no network audio. The
// Live Activity does not grant execution time; only this session (while it plays) and the background task do.

/// What the audio session reports while silence plays (from AVAudioSession notifications; fixed codes only).
public enum BackgroundAudioSignal: Equatable, Sendable {
    case interruptionBegan(reason: Int)
    case interruptionEnded
    case routeChanged(reason: Int, stillPlaying: Bool)
    case mediaServicesReset
}

/// The audio session + silent player (`SilentAudioOutput` on iOS, a fake in tests).
@MainActor public protocol BackgroundAudioOutput: AnyObject {
    /// Activates a `.playback` session with `.mixWithOthers` and loops silence. On a throw nothing must keep playing.
    func start(onSignal: @escaping @MainActor (BackgroundAudioSignal) -> Void) throws
    /// Stops the player, removes observers, deactivates the session (notifying others). Safe to repeat.
    func stop()
}

/// Task-scoped lifecycle: `begin` before the task leaves the app, `end` on every way out (completion, error, user
/// Stop, background expiration, start failure). Interruption, a route change that stopped playback, a media-services
/// reset or the time cap mean the app can no longer count on running: playback stops and `onLost` asks to stop the
/// task. Nothing is restarted, resumed or replayed automatically.
@MainActor public final class BackgroundAudioKeeper {
    public enum State: Equatable, Sendable { case off, active, lost(String) }
    public typealias Schedule = (UInt64, @escaping @MainActor () -> Void) -> Void

    public private(set) var state: State = .off
    /// Called on every state change (the app mirrors it into its UI).
    public var onChange: ((State) -> Void)?
    /// Upper bound on one run's silence (default 10 minutes); reaching it counts as lost.
    public var maxNanoseconds: UInt64 = 10 * 60 * 1_000_000_000

    let output: BackgroundAudioOutput
    let monotonic: () -> UInt64
    let schedule: Schedule
    private var onLost: ((String) -> Void)?
    private var started: UInt64 = 0
    private var generation = 0

    public init(output: BackgroundAudioOutput,
                monotonic: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                schedule: @escaping Schedule = { delay, body in
                    Task { @MainActor in try? await Task.sleep(nanoseconds: delay); body() }
                }) {
        self.output = output; self.monotonic = monotonic; self.schedule = schedule
    }

    public var isActive: Bool { state == .active }

    /// Starts silence for one run; true when it plays. Already active: true, nothing new is started.
    @discardableResult
    public func begin(onLost: @escaping (String) -> Void) -> Bool {
        if state == .active { return true }
        generation += 1
        let gen = generation
        do {
            try output.start { [weak self] s in self?.handle(s, generation: gen) }
        } catch {
            output.stop()
            set(.off)
            AgentDiag.event("audio.start", [("ok", .bool(false)), ("err", .token(AgentDiag.errorClass(error)))])
            return false
        }
        self.onLost = onLost
        started = monotonic()
        set(.active)
        AgentDiag.event("audio.start", [("ok", .bool(true)), ("mix_with_others", .bool(true)), ("max_ms", .ms(Double(maxNanoseconds) / 1e6))])
        schedule(maxNanoseconds) { [weak self] in
            guard let self, self.generation == gen, self.state == .active else { return }
            self.lose("time_cap")
        }
        return true
    }

    /// Ends the run's silence (idempotent; a lost state is cleared too). `cause` is a fixed token.
    public func end(_ cause: String) {
        generation += 1
        onLost = nil
        guard state != .off else { return }
        let wasActive = state == .active
        if wasActive { output.stop() }
        set(.off)
        if wasActive { AgentDiag.event("audio.stop", [("cause", .token(cause)), ("ms", .ms(runtimeMs))]) }
    }

    private var runtimeMs: Double { let n = monotonic(); return n >= started ? Double(n - started) / 1e6 : 0 }

    func handle(_ s: BackgroundAudioSignal, generation gen: Int) {
        let current = gen == generation && state == .active
        switch s {
        case .interruptionBegan(let r):
            AgentDiag.event("audio.interruption", [("began", .bool(true)), ("reason", .int(r)), ("active", .bool(current))])
            if current { lose("interrupted") }
        case .interruptionEnded:
            // Never resumes on its own: the task was already stopped when the interruption began.
            AgentDiag.event("audio.interruption", [("began", .bool(false)), ("resumed", .bool(false)), ("active", .bool(current))])
        case .routeChanged(let r, let playing):
            AgentDiag.event("audio.route", [("reason", .int(r)), ("playing", .bool(playing)), ("active", .bool(current))])
            if current && !playing { lose("route_stopped_playback") }
        case .mediaServicesReset:
            AgentDiag.event("audio.media_reset", [("active", .bool(current))])
            if current { lose("media_services_reset") }
        }
    }

    private func lose(_ why: String) {
        generation += 1
        output.stop()
        set(.lost(why))
        AgentDiag.event("audio.stop", [("cause", .token(why)), ("ms", .ms(runtimeMs))])
        let cb = onLost
        onLost = nil
        cb?(why)
    }

    private func set(_ s: State) { state = s; onChange?(s) }

    /// A short mono 16-bit PCM WAV of zero samples (generated here; no bundled or downloaded audio).
    public nonisolated static func silenceWAV(sampleRate: Int = 8000, seconds: Int = 1) -> Data {
        let samples = sampleRate * seconds, dataBytes = samples * 2
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        d.append(Data(count: dataBytes))
        return d
    }
}

#if os(iOS)
public enum BackgroundAudioError: Error, AgentDiagClassified {
    case playerRefused
    public var diagClass: String { "audio.player_refused" }
}

/// `AVAudioSession` `.playback` + `.mixWithOthers` (other apps' audio keeps playing, no ducking) and one looping
/// `AVAudioPlayer` of `silenceWAV()` at volume 0. No record category, no input, no network.
@MainActor public final class SilentAudioOutput: BackgroundAudioOutput {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var activated = false

    public init() {}

    public func start(onSignal: @escaping @MainActor (BackgroundAudioSignal) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        activated = true
        let p = try AVAudioPlayer(data: BackgroundAudioKeeper.silenceWAV(), fileTypeHint: AVFileType.wav.rawValue)
        p.numberOfLoops = -1
        p.volume = 0
        guard p.prepareToPlay(), p.play() else { throw BackgroundAudioError.playerRefused }
        player = p
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { n in
                let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                let reason = Int(n.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt ?? 0)
                MainActor.assumeIsolated { onSignal(type == .ended ? .interruptionEnded : .interruptionBegan(reason: reason)) }
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] n in
                let reason = Int(n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0)
                MainActor.assumeIsolated { onSignal(.routeChanged(reason: reason, stillPlaying: self?.player?.isPlaying == true)) }
            },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { _ in
                MainActor.assumeIsolated { onSignal(.mediaServicesReset) }
            },
        ]
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        player?.stop()
        player = nil
        if activated {
            activated = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}
#endif
