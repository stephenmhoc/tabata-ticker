import AVFoundation
import Observation
import Sentry
import SwiftUI
import UIKit

@MainActor
@Observable
final class WorkoutViewModel {
    private(set) var state: TabataState
    private(set) var now: Date
    private(set) var presetCatalog: TabataPresetCatalog

    @ObservationIgnored
    private var engine: TabataEngine
    private let presetStore: TabataPresetStore
    private let stateStore: TabataStateStore
    private let settingsStore: TabataSettingsStore
    private let connectivity = PhoneConnectivity()
    private let cuePerformer = PhoneCuePerformer()
    private let liveActivityController = TabataLiveActivityController()
    @ObservationIgnored
    private var lastCountdownCue: CountdownCue?
    @ObservationIgnored
    private var didActivate = false
    @ObservationIgnored
    private var tickTask: Task<Void, Never>?

    private static var currentInstance: WorkoutViewModel?

    // Live Activity buttons run their intent in this process without the SwiftUI environment, so the
    // running view model is reachable here. It is created on demand, which covers a button press
    // that launches the app in the background: the workout it acts on is restored from disk.
    static func shared() -> WorkoutViewModel {
        if let currentInstance {
            return currentInstance
        }

        let workout = WorkoutViewModel()
        currentInstance = workout
        return workout
    }

    init(defaults: UserDefaults = .standard) {
        let presetStore = TabataPresetStore(defaults: defaults)
        self.presetStore = presetStore
        let stateStore = TabataStateStore(defaults: defaults)
        self.stateStore = stateStore
        let settingsStore = TabataSettingsStore(defaults: defaults)
        self.settingsStore = settingsStore
        let presetCatalog = presetStore.loadCatalog()
        self.presetCatalog = presetCatalog

        let settings = settingsStore.load()
        let now = Date()
        var initialState = stateStore.restore(now: now) ?? .idle(config: presetCatalog.selectedPreset.config)
        initialState.settings = settings

        state = initialState
        self.now = now
        engine = TabataEngine(state: initialState)
    }

    var presets: [TabataPreset] {
        presetCatalog.presets
    }

    var selectedPreset: TabataPreset {
        presetCatalog.selectedPreset
    }

    var canCreatePreset: Bool {
        presetCatalog.canCreatePreset
    }

    var canManageCustomPresets: Bool {
        !state.isRunning && !state.isWorkoutPhase
    }

    func activate() {
        guard !didActivate else {
            return
        }

        didActivate = true
        connectivity.onCommand = { [weak self] command in
            self?.handle(command)
        }
        // Activation finishes after this returns, and nothing can be sent until it has.
        connectivity.onReady = { [weak self] in
            self?.publishState()
        }
        connectivity.activate()
        publishState()
        syncRunningState()
        TabataShortcuts.updateAppShortcutParameters()
    }

    // Swiping a Live Activity away ends it, and iOS only allows a new one while the app is in front,
    // so this is the first chance to put it back during a workout.
    func refreshLiveActivity() {
        liveActivityController.sync(state: state, now: Date())
    }

    func tick(now: Date = Date()) {
        let oldState = state
        self.now = now
        state = engine.tick(now: now)

        if let cue = TabataCuePolicy.transitionCue(from: oldState, to: state) {
            if state.settings.soundsEnabled {
                cuePerformer.playTransition(cue)
            }
            // Counts this second as cued, so a short phase never plays two sounds at once.
            lastCountdownCue = TabataCuePolicy.countdownCue(in: state, now: now)
        }

        if state.settings.soundsEnabled, let cue = TabataCuePolicy.countdownCue(in: state, now: now), cue != lastCountdownCue {
            cuePerformer.playCountdown()
            lastCountdownCue = cue
        }

        syncRunningState()

        if oldState != state {
            publishState()
        }
    }

    func toggleRunning() {
        let now = Date()
        self.now = now
        engine.toggleRunning(now: now)
        state = engine.state
        lastCountdownCue = TabataCuePolicy.countdownCue(in: state, now: now)
        syncRunningState()
        publishState()
    }

    func reset() {
        resetToSelectedPreset()
    }

    func setSoundsEnabled(_ enabled: Bool) {
        updateSettings { $0.soundsEnabled = enabled }
    }

    func selectPreset(id: String) {
        guard let preset = presetCatalog.presets.first(where: { $0.id == id }) else {
            return
        }

        selectPreset(preset)
    }

    func selectPreset(_ preset: TabataPreset) {
        guard state.phase == .idle, presetCatalog.selectPreset(id: preset.id) else {
            return
        }

        presetStore.save(presetCatalog)
        resetToSelectedPreset()
    }

    @discardableResult
    func createPreset(config: TabataConfig, name: String?) -> Bool {
        guard canManageCustomPresets, presetCatalog.addUserPreset(config: config, name: name) != nil else {
            return false
        }

        presetStore.save(presetCatalog)
        TabataShortcuts.updateAppShortcutParameters()
        resetToSelectedPreset()
        return true
    }

    @discardableResult
    func updatePreset(id: String, config: TabataConfig, name: String?) -> Bool {
        let wasSelected = presetCatalog.selectedID == id
        guard canManageCustomPresets, presetCatalog.updateUserPreset(id: id, config: config, name: name) else {
            return false
        }

        presetStore.save(presetCatalog)
        TabataShortcuts.updateAppShortcutParameters()
        if wasSelected, state.phase == .idle || state.phase == .complete {
            resetToSelectedPreset()
        } else {
            publishState()
        }
        return true
    }

    @discardableResult
    func deletePreset(id: String) -> Bool {
        let wasSelected = presetCatalog.selectedID == id
        guard canManageCustomPresets, presetCatalog.deleteUserPreset(id: id) else {
            return false
        }

        presetStore.save(presetCatalog)
        TabataShortcuts.updateAppShortcutParameters()
        if wasSelected, state.phase == .idle || state.phase == .complete {
            resetToSelectedPreset()
        } else {
            publishState()
        }
        return true
    }

    func setHapticsEnabled(_ enabled: Bool) {
        updateSettings { $0.hapticsEnabled = enabled }
    }

    func setStartCountdownEnabled(_ enabled: Bool) {
        updateSettings { $0.startCountdownEnabled = enabled }
    }

    private func updateSettings(_ change: (inout TabataSettings) -> Void) {
        now = Date()
        engine.updateSettings(change)
        state = engine.state
        settingsStore.save(state.settings)
        lastCountdownCue = nil
        publishState()
    }

    private func handle(_ payload: WatchCommandPayload) {
        guard payload.isFresh(at: Date()) else {
            // The watch acted on this alone, so it needs telling what is really happening.
            publishState()
            return
        }

        switch payload.command {
        case .start:
            start()
        case .pause:
            pause()
        case .resume:
            resume()
        case .reset:
            reset()
        case .setSoundsEnabled:
            setSoundsEnabled(payload.soundsEnabled ?? state.settings.soundsEnabled)
        case .selectPreset:
            guard let presetID = payload.presetID else {
                return
            }

            selectPreset(id: presetID)
        }
    }

    private func publishState() {
        connectivity.send(state, catalog: presetCatalog)
        stateStore.save(state, at: now)
        liveActivityController.sync(state: state, now: now)
        recordStateForCrashReports()
    }

    // Set ahead of time because a crash or hang leaves no chance to ask what the workout was doing.
    private func recordStateForCrashReports() {
        let breadcrumb = Breadcrumb(level: .info, category: "workout")
        breadcrumb.message = "\(state.phase.rawValue), round \(state.round), \(state.isRunning ? "running" : "stopped")"
        SentrySDK.addBreadcrumb(breadcrumb)

        SentrySDK.configureScope { [state] scope in
            scope.setTag(value: state.phase.rawValue, key: "workout.phase")
            scope.setContext(value: [
                "phase": state.phase.rawValue,
                "round": state.round,
                "rounds": state.config.rounds,
                "workDuration": state.config.workDuration,
                "restDuration": state.config.restDuration,
                "isRunning": state.isRunning,
                "soundsEnabled": state.settings.soundsEnabled,
                "hapticsEnabled": state.settings.hapticsEnabled
            ], key: "workout")
        }
    }

    private func resetToSelectedPreset() {
        now = Date()

        let selectedState = TabataState.idle(config: selectedPreset.config, settings: state.settings)
        engine = TabataEngine(state: selectedState)
        state = selectedState
        lastCountdownCue = nil
        syncRunningState()
        publishState()
    }

    // The timer belongs to the view model rather than the view so a workout keeps running, cueing,
    // and updating its Live Activity while the app is in the background.
    private func syncRunningState() {
        if state.isRunning {
            startTicking()
        } else {
            stopTicking()
        }

        cuePerformer.setWorkoutAudioActive(state.isRunning)
        UIApplication.shared.isIdleTimerDisabled = state.isRunning
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
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    func start() {
        guard state.phase == .idle || state.phase == .complete else {
            return
        }

        now = Date()
        engine.start(now: now)
        state = engine.state
        lastCountdownCue = nil
        syncRunningState()
        publishState()
    }

    func pause() {
        guard state.isWorkoutPhase, state.isRunning else {
            return
        }

        now = Date()
        engine.pause(now: now)
        state = engine.state
        lastCountdownCue = nil
        syncRunningState()
        publishState()
    }

    func resume() {
        guard state.isWorkoutPhase, !state.isRunning else {
            return
        }

        now = Date()
        engine.resume(now: now)
        state = engine.state
        // The second a pause landed in has already been cued.
        lastCountdownCue = TabataCuePolicy.countdownCue(in: state, now: now)
        syncRunningState()
        publishState()
    }
}

// AVAudioSession calls block, sometimes for seconds, so all of this runs on its own serial queue. A
// slow session can delay a beep, but it can't freeze the timer on screen. Everything stored here is
// only touched on that queue, which is what makes the unchecked Sendable safe.
private final class PhoneCuePerformer: @unchecked Sendable {
    private static let duckReleaseDelay: TimeInterval = 1.5

    private let queue = DispatchQueue(label: "com.merimerimeri.tabataticker.audio", qos: .userInitiated)
    private var players: Players?
    private var duckRelease: DispatchWorkItem?
    private var isDucking = false
    private var isWorkoutAudioActive = false
    private var didReportSessionFailure = false

    private struct Players {
        let countdown = PhoneCuePerformer.makePlayer(TabataTone.tick)
        let work = PhoneCuePerformer.makePlayer(TabataTone.work)
        let rest = PhoneCuePerformer.makePlayer(TabataTone.rest)
        let finish = PhoneCuePerformer.makePlayer(TabataTone.finish)
        let keepAlive: AVAudioPlayer? = {
            let player = PhoneCuePerformer.makePlayer(TabataTone.silence, amplitude: 0)
            player?.numberOfLoops = -1
            return player
        }()

        var isComplete: Bool {
            countdown != nil && work != nil && rest != nil && finish != nil && keepAlive != nil
        }
    }

    init() {
        queue.async { [self] in
            // The category has to be in place before anything touches the audio hardware: the default
            // .soloAmbient category stops whatever the user is already listening to.
            Self.configureSession()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

            let players = Players()
            self.players = players
            if !players.isComplete {
                TabataDiagnostics.report("Workout cue audio could not be prepared")
            }
        }

        // The tick alone cannot recover from these: without the keep-alive audio iOS may suspend the
        // app, and then the tick never comes.
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.ended.rawValue, let self else {
                return
            }

            self.queue.async {
                self.resumeKeepAlive()
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else {
                return
            }

            self.queue.async {
                self.rebuildAudio()
            }
        }
    }

    private static func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: categoryOptions(ducksOthers: false)
            )
        } catch {
            TabataDiagnostics.report("Configuring the audio session failed", error: error)
        }
    }

    private func resumeKeepAlive() {
        guard isWorkoutAudioActive else {
            return
        }

        activateSession()
        players?.keepAlive?.play()
    }

    // After a media services reset every existing player and the session's setup are dead.
    private func rebuildAudio() {
        Self.configureSession()
        players = Players()
        isDucking = false
        resumeKeepAlive()
    }

    // A running workout plays silence so iOS keeps the app alive with the screen off. This is called
    // on every tick as well as on state changes, so playback picks itself back up after an
    // interruption such as a phone call.
    func setWorkoutAudioActive(_ isActive: Bool) {
        queue.async { [self] in
            isWorkoutAudioActive = isActive

            guard isActive else {
                releaseSessionIfIdle()
                return
            }

            guard let keepAlivePlayer = players?.keepAlive, !keepAlivePlayer.isPlaying else {
                return
            }

            activateSession()
            keepAlivePlayer.play()
        }
    }

    func playCountdown() {
        queue.async { [self] in
            play(players?.countdown)
        }
    }

    func playTransition(_ cue: TabataTransitionCue) {
        queue.async { [self] in
            switch cue {
            case .work:
                play(players?.work)
            case .rest:
                play(players?.rest)
            case .finish:
                play(players?.finish)
            }
        }
    }

    private func play(_ player: AVAudioPlayer?) {
        guard let player else {
            return
        }

        duckRelease?.cancel()
        duckRelease = nil

        // A cue landing inside the delay keeps the current duck instead of retriggering it.
        if !isDucking {
            isDucking = true
            applyCategoryOptions(ducksOthers: true)
            activateSession()
        }

        player.currentTime = 0
        player.play()
        scheduleDuckRelease(after: player.duration + Self.duckReleaseDelay)
    }

    // Other audio stays ducked for as long as the option is set, so it is dropped once the cues stop.
    private func scheduleDuckRelease(after delay: TimeInterval) {
        let release = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.duckRelease = nil
            self.isDucking = false
            self.applyCategoryOptions(ducksOthers: false)
            self.releaseSessionIfIdle()
        }

        duckRelease = release
        queue.asyncAfter(deadline: .now() + delay, execute: release)
    }

    // The session is held until the last cue has finished, so ending a workout never clips its final beep.
    private func releaseSessionIfIdle() {
        guard !isWorkoutAudioActive, duckRelease == nil else {
            return
        }

        players?.keepAlive?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func applyCategoryOptions(ducksOthers: Bool) {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: Self.categoryOptions(ducksOthers: ducksOthers)
            )
        } catch {
            reportSessionFailureOnce("Adjusting the audio session failed", error: error)
        }
    }

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            reportSessionFailureOnce("Activating the audio session failed", error: error)
        }
    }

    // Both callers run on every tick of a workout, so only the first failure of a launch is reported.
    private func reportSessionFailureOnce(_ context: String, error: any Error) {
        guard !didReportSessionFailure else {
            return
        }

        didReportSessionFailure = true
        TabataDiagnostics.report(context, error: error)
    }

    private static func categoryOptions(ducksOthers: Bool) -> AVAudioSession.CategoryOptions {
        ducksOthers ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
    }

    private static func makePlayer(_ notes: [TabataTone.Note], amplitude: Double = 0.5) -> AVAudioPlayer? {
        let player = try? AVAudioPlayer(data: TabataTone.waveData(notes, amplitude: amplitude))
        player?.prepareToPlay()
        return player
    }
}
