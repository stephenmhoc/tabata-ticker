import AVFoundation
import Observation
import SwiftUI
import WatchKit

@MainActor
@Observable
final class WatchWorkoutViewModel {
    private(set) var state: TabataState
    private(set) var now: Date
    private(set) var catalog = TabataPresetCatalog()

    @ObservationIgnored
    private var engine: TabataEngine
    private let settingsStore: TabataSettingsStore
    private let connectivity = WatchConnectivity()
    private let cuePerformer = WatchCuePerformer()
    private let runtimeSessionController = WatchRuntimeSessionController()
    @ObservationIgnored
    private var lastCountdownCue: CountdownCue?
    @ObservationIgnored
    private var didActivate = false
    @ObservationIgnored
    private var tickTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        let settingsStore = TabataSettingsStore(defaults: defaults)
        self.settingsStore = settingsStore

        let initialState = TabataState.idle(settings: settingsStore.load())
        state = initialState
        now = Date()
        engine = TabataEngine(state: initialState)
    }

    func activate() {
        guard !didActivate else {
            return
        }

        didActivate = true
        connectivity.onState = { [weak self] state in
            self?.receive(state)
        }
        connectivity.onCatalog = { [weak self] catalog in
            self?.catalog = catalog
        }
        connectivity.activate()
    }

    var presets: [TabataPreset] {
        catalog.presets
    }

    var selectedPreset: TabataPreset {
        catalog.selectedPreset
    }

    var canSelectPreset: Bool {
        state.phase == .idle && catalog.presets.count > 1
    }

    // The phone owns the catalog, so the selection is echoed back with the new state; showing it
    // immediately keeps the watch from looking unresponsive while that round trip happens.
    func selectPreset(_ preset: TabataPreset) {
        guard state.phase == .idle, catalog.selectPreset(id: preset.id) else {
            return
        }

        // Start may be tapped before the phone answers, so the timer has to match the label now.
        engine = TabataEngine(state: .idle(config: preset.config, settings: state.settings))
        state = engine.state
        connectivity.send(WatchCommandPayload(command: .selectPreset, soundsEnabled: nil, presetID: preset.id))
    }

    func tick(now: Date = Date()) {
        let oldState = state
        self.now = now
        state = engine.tick(now: now)

        playTransitionCue(from: oldState)

        if let cue = TabataCuePolicy.countdownCue(in: state, now: now), cue != lastCountdownCue {
            cuePerformer.playCountdown(soundsEnabled: state.settings.soundsEnabled, hapticsEnabled: state.settings.hapticsEnabled)
            lastCountdownCue = cue
        }

        syncRunningState()
    }

    func toggleRunning() {
        let command = nextRunningCommand
        now = Date()
        engine.toggleRunning(now: now)
        state = engine.state
        // The second a pause landed in has already been cued.
        lastCountdownCue = TabataCuePolicy.countdownCue(in: state, now: now)
        syncRunningState()
        connectivity.send(WatchCommandPayload(command: command, soundsEnabled: nil))
    }

    func reset() {
        now = Date()
        engine.reset()
        state = engine.state
        lastCountdownCue = nil
        syncRunningState()
        connectivity.send(WatchCommandPayload(command: .reset, soundsEnabled: nil))
    }

    func setSoundsEnabled(_ enabled: Bool) {
        now = Date()
        engine.updateSettings { $0.soundsEnabled = enabled }
        state = engine.state
        settingsStore.save(state.settings)
        lastCountdownCue = nil
        syncRunningState()
        connectivity.send(WatchCommandPayload(command: .setSoundsEnabled, soundsEnabled: enabled))
    }

    // The phone's update can beat the next local tick to a phase boundary, so a transition is cued
    // here as well as in tick. Whichever sees it first moves the state on, so it only plays once.
    // Only a running timer cues: state cached from an old workout must not buzz at launch.
    private func receive(_ newState: TabataState) {
        let oldState = state
        now = Date()
        settingsStore.save(newState.settings)
        engine = TabataEngine(state: newState)
        state = engine.tick(now: now)

        if oldState.isRunning {
            playTransitionCue(from: oldState)
        }

        syncRunningState()
    }

    private func playTransitionCue(from oldState: TabataState) {
        guard let cue = TabataCuePolicy.transitionCue(from: oldState, to: state) else {
            return
        }

        cuePerformer.playTransition(cue, soundsEnabled: state.settings.soundsEnabled, hapticsEnabled: state.settings.hapticsEnabled)
        // Counts this second as cued, so a short phase never plays two cues at once.
        lastCountdownCue = TabataCuePolicy.countdownCue(in: state, now: now)
    }

    // A runtime session can only start while the app is frontmost, so one that could not start
    // earlier gets its chance when the user raises their wrist.
    func sceneBecameActive() {
        runtimeSessionController.setRunning(state.isRunning)
    }

    private var nextRunningCommand: WatchCommand {
        if state.phase == .idle || state.phase == .complete {
            return .start
        }

        return state.isRunning ? .pause : .resume
    }

    private func syncRunningState() {
        if state.isRunning {
            startTicking()
        } else {
            stopTicking()
        }

        runtimeSessionController.setRunning(state.isRunning)
    }

    private func startTicking() {
        guard tickTask == nil else {
            return
        }

        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.state.isRunning else {
                    return
                }

                self.tick(now: Date())
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}

private final class WatchRuntimeSessionController: NSObject, WKExtendedRuntimeSessionDelegate {
    private var session: WKExtendedRuntimeSession?
    private var restartWorkItem: DispatchWorkItem?
    private var wantsSession = false

    func setRunning(_ isRunning: Bool) {
        wantsSession = isRunning

        if isRunning {
            start()
        } else {
            restartWorkItem?.cancel()
            restartWorkItem = nil
            stop()
        }
    }

    private func start() {
        // Every path here is on the main thread, including the delayed restart below.
        let isActive = MainActor.assumeIsolated { WKApplication.shared().applicationState == .active }
        guard session == nil, isActive else {
            return
        }

        restartWorkItem?.cancel()
        restartWorkItem = nil
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        self.session = session
        session.start()
    }

    private func stop() {
        session?.invalidate()
        session = nil
    }

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        guard session === extendedRuntimeSession else {
            return
        }

        session = nil
        if wantsSession {
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        restartWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.wantsSession, self.session == nil else {
                return
            }

            self.start()
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }
}

private final class WatchCuePerformer {
    private let countdownPlayer: AVAudioPlayer?
    private let workPlayer: AVAudioPlayer?
    private let restPlayer: AVAudioPlayer?
    private let finishPlayer: AVAudioPlayer?

    init() {
        // The category has to be in place before anything touches the audio hardware: the default
        // .soloAmbient category stops whatever the user is already listening to.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])

        countdownPlayer = Self.makePlayer(TabataTone.tick)
        workPlayer = Self.makePlayer(TabataTone.work)
        restPlayer = Self.makePlayer(TabataTone.rest)
        finishPlayer = Self.makePlayer(TabataTone.finish)
    }

    func playCountdown(soundsEnabled: Bool, hapticsEnabled: Bool) {
        if soundsEnabled {
            play(countdownPlayer)
        }
        if hapticsEnabled {
            WKInterfaceDevice.current().play(.directionUp)
        }
    }

    // WORK, REST and the finish each feel different, so the wrist alone says what comes next.
    func playTransition(_ cue: TabataTransitionCue, soundsEnabled: Bool, hapticsEnabled: Bool) {
        let player: AVAudioPlayer?
        let haptic: WKHapticType

        switch cue {
        case .work:
            player = workPlayer
            haptic = .start
        case .rest:
            player = restPlayer
            haptic = .stop
        case .finish:
            player = finishPlayer
            haptic = .success
        }

        if soundsEnabled {
            play(player)
        }
        if hapticsEnabled {
            WKInterfaceDevice.current().play(haptic)
        }
    }

    private static func makePlayer(_ notes: [TabataTone.Note]) -> AVAudioPlayer? {
        let player = try? AVAudioPlayer(data: TabataTone.waveData(notes))
        player?.prepareToPlay()
        return player
    }

    private func play(_ player: AVAudioPlayer?) {
        player?.currentTime = 0
        player?.play()
    }
}
