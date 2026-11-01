import Foundation

enum TabataPhase: String, Codable, Equatable, Sendable {
    case idle
    case countdown
    case work
    case rest
    case complete
}

struct TabataConfig: Codable, Equatable, Sendable {
    var rounds: Int
    var workDuration: TimeInterval
    var restDuration: TimeInterval

    static let classic = TabataConfig(rounds: 8, workDuration: 20, restDuration: 10)

    static let workSecondsRange = 5...300
    static let restSecondsRange = 5...300
    static let roundsRange = 1...30

    static func preset(workSeconds: Int, restSeconds: Int, rounds: Int) -> TabataConfig {
        TabataConfig(
            rounds: rounds,
            workDuration: TimeInterval(workSeconds),
            restDuration: TimeInterval(restSeconds)
        )
    }

    // Stored presets are only as trustworthy as the defaults they came from, and a zero-second phase
    // would leave the engine spinning through rounds, so every config is pulled back into range.
    var clamped: TabataConfig {
        TabataConfig.preset(
            workSeconds: Self.clamp(workSeconds, to: Self.workSecondsRange),
            restSeconds: Self.clamp(restSeconds, to: Self.restSecondsRange),
            rounds: Self.clamp(rounds, to: Self.roundsRange)
        )
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    var workSeconds: Int {
        Int(workDuration.rounded())
    }

    var restSeconds: Int {
        Int(restDuration.rounded())
    }

    var presetName: String {
        "\(workSeconds)/\(restSeconds)/\(rounds)"
    }

    // The last round has no rest after it: the workout ends as soon as the final work phase does.
    var totalDuration: TimeInterval {
        TimeInterval(rounds) * workDuration + TimeInterval(max(0, rounds - 1)) * restDuration
    }

    var roundsText: String {
        "\(rounds) \(rounds == 1 ? "round" : "rounds")"
    }
}

enum TabataClock {
    static func text(seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // A phase under a minute drops the "0:", so the digits can fill the screen.
    static func compactText(seconds: Int) -> String {
        seconds < 60 ? "\(seconds)" : text(seconds: seconds)
    }
}

struct TabataPreset: Codable, Equatable, Identifiable, Sendable {
    static let defaultID = "classic"
    static let classic = TabataPreset(id: defaultID, config: .classic, isDefault: true)
    static let maxNameLength = 24

    var id: String
    var config: TabataConfig
    var isDefault: Bool
    var customName: String?

    init(id: String, config: TabataConfig, isDefault: Bool, customName: String? = nil) {
        self.id = id
        self.config = config
        self.isDefault = isDefault
        self.customName = Self.sanitizedName(customName)
    }

    // Unnamed presets keep showing the work/rest/rounds shorthand, which is what every preset showed
    // before naming existed.
    var name: String {
        customName ?? config.presetName
    }

    var timingText: String {
        config.presetName
    }

    var hasCustomName: Bool {
        customName != nil
    }

    static func sanitizedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        return String(trimmed.prefix(maxNameLength))
    }
}

struct TabataPresetCatalog: Equatable, Sendable {
    static let maxPresetCount = 4

    private(set) var presets: [TabataPreset]
    private(set) var selectedID: String

    init(customPresets: [TabataPreset] = [], selectedID: String? = nil) {
        let userPresets = Self.cleanUserPresets(customPresets)
        presets = [TabataPreset.classic] + userPresets

        if let selectedID, presets.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        } else {
            self.selectedID = TabataPreset.defaultID
        }
    }

    var selectedPreset: TabataPreset {
        presets.first { $0.id == selectedID } ?? .classic
    }

    var userPresets: [TabataPreset] {
        presets.filter { !$0.isDefault }
    }

    var canCreatePreset: Bool {
        presets.count < Self.maxPresetCount
    }

    @discardableResult
    mutating func selectPreset(id: String) -> Bool {
        guard presets.contains(where: { $0.id == id }) else {
            return false
        }

        selectedID = id
        return true
    }

    mutating func addUserPreset(config: TabataConfig, name: String? = nil, id: String = UUID().uuidString) -> TabataPreset? {
        guard canCreatePreset else {
            return nil
        }

        let preset = TabataPreset(id: id, config: config.clamped, isDefault: false, customName: name)
        presets.append(preset)
        selectedID = preset.id
        return preset
    }

    @discardableResult
    mutating func updateUserPreset(id: String, config: TabataConfig, name: String? = nil) -> Bool {
        guard let index = presets.firstIndex(where: { $0.id == id && !$0.isDefault }) else {
            return false
        }

        presets[index].config = config.clamped
        presets[index].customName = TabataPreset.sanitizedName(name)
        return true
    }

    @discardableResult
    mutating func deleteUserPreset(id: String) -> Bool {
        guard let index = presets.firstIndex(where: { $0.id == id && !$0.isDefault }) else {
            return false
        }

        presets.remove(at: index)
        if selectedID == id {
            selectedID = TabataPreset.defaultID
        }
        return true
    }

    private static func cleanUserPresets(_ presets: [TabataPreset]) -> [TabataPreset] {
        var cleaned: [TabataPreset] = []

        for preset in presets where !preset.isDefault && preset.id != TabataPreset.defaultID {
            guard cleaned.count < maxPresetCount - 1 else {
                continue
            }

            cleaned.append(
                TabataPreset(
                    id: preset.id,
                    config: preset.config.clamped,
                    isDefault: false,
                    customName: preset.customName
                )
            )
        }

        return cleaned
    }
}

struct TabataSettings: Codable, Equatable, Sendable {
    var soundsEnabled: Bool
    var hapticsEnabled: Bool
    var startCountdownEnabled: Bool

    static let standard = TabataSettings(soundsEnabled: true, hapticsEnabled: true, startCountdownEnabled: true)
}

struct TabataSettingsStore {
    private static let soundsEnabledKey = "soundsEnabled"
    private static let hapticsEnabledKey = "hapticsEnabled"
    private static let startCountdownEnabledKey = "startCountdownEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> TabataSettings {
        var settings = TabataSettings.standard

        if defaults.object(forKey: Self.soundsEnabledKey) != nil {
            settings.soundsEnabled = defaults.bool(forKey: Self.soundsEnabledKey)
        }
        if defaults.object(forKey: Self.hapticsEnabledKey) != nil {
            settings.hapticsEnabled = defaults.bool(forKey: Self.hapticsEnabledKey)
        }
        if defaults.object(forKey: Self.startCountdownEnabledKey) != nil {
            settings.startCountdownEnabled = defaults.bool(forKey: Self.startCountdownEnabledKey)
        }

        return settings
    }

    func save(_ settings: TabataSettings) {
        defaults.set(settings.soundsEnabled, forKey: Self.soundsEnabledKey)
        defaults.set(settings.hapticsEnabled, forKey: Self.hapticsEnabledKey)
        defaults.set(settings.startCountdownEnabled, forKey: Self.startCountdownEnabledKey)
    }
}

// Shared code is built for the watch and for tests as well as the iPhone app, so it reports failures
// through this seam instead of depending on a crash reporter directly. The iPhone app points it at
// Sentry during launch, before anything else can report, which is why the unchecked access is safe.
enum TabataDiagnostics {
    nonisolated(unsafe) private static var reporter: (@Sendable (String, (any Error)?) -> Void)?

    static func setReporter(_ reporter: @escaping @Sendable (String, (any Error)?) -> Void) {
        Self.reporter = reporter
    }

    static func report(_ context: String, error: (any Error)? = nil) {
        reporter?(context, error)
    }
}

struct TabataPresetStore {
    private static let customPresetsKey = "tabataPreset.customPresets"
    private static let selectedPresetIDKey = "tabataPreset.selectedPresetID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadCatalog() -> TabataPresetCatalog {
        TabataPresetCatalog(
            customPresets: loadUserPresets(),
            selectedID: defaults.string(forKey: Self.selectedPresetIDKey)
        )
    }

    func save(_ catalog: TabataPresetCatalog) {
        do {
            defaults.set(try JSONEncoder().encode(catalog.userPresets), forKey: Self.customPresetsKey)
        } catch {
            TabataDiagnostics.report("Saving custom presets failed", error: error)
        }

        defaults.set(catalog.selectedID, forKey: Self.selectedPresetIDKey)
    }

    private func loadUserPresets() -> [TabataPreset] {
        guard let data = defaults.data(forKey: Self.customPresetsKey) else {
            return []
        }

        do {
            return try JSONDecoder().decode([TabataPreset].self, from: data)
        } catch {
            TabataDiagnostics.report("Stored custom presets could not be read", error: error)
            return []
        }
    }
}

struct TabataStateStore {
    static let maxRestoreAge: TimeInterval = 6 * 60 * 60

    private static let stateKey = "tabataState.active"
    private static let savedAtKey = "tabataState.activeSavedAt"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ state: TabataState, at date: Date) {
        guard Self.isUnfinished(state) else {
            clear()
            return
        }

        do {
            defaults.set(try JSONEncoder().encode(state), forKey: Self.stateKey)
            defaults.set(date.timeIntervalSince1970, forKey: Self.savedAtKey)
        } catch {
            TabataDiagnostics.report("Saving the active workout failed", error: error)
        }
    }

    func clear() {
        defaults.removeObject(forKey: Self.stateKey)
        defaults.removeObject(forKey: Self.savedAtKey)
    }

    func restore(now: Date) -> TabataState? {
        guard let data = defaults.data(forKey: Self.stateKey) else {
            return nil
        }

        do {
            let state = try JSONDecoder().decode(TabataState.self, from: data)
            return Self.restorable(state, savedAt: Date(timeIntervalSince1970: defaults.double(forKey: Self.savedAtKey)), now: now)
        } catch {
            TabataDiagnostics.report("Stored workout could not be read", error: error)
            clear()
            return nil
        }
    }

    // A workout only comes back if it was interrupted recently and is still under way, so reopening
    // the app hours later starts fresh instead of resuming something the user has long since left.
    static func restorable(_ state: TabataState, savedAt: Date, now: Date) -> TabataState? {
        guard isUnfinished(state) else {
            return nil
        }

        let age = now.timeIntervalSince(savedAt)
        guard age >= 0, age < maxRestoreAge else {
            return nil
        }

        var engine = TabataEngine(state: state)
        let advanced = engine.tick(now: now)
        return isUnfinished(advanced) ? advanced : nil
    }

    private static func isUnfinished(_ state: TabataState) -> Bool {
        state.phase == .countdown || state.isWorkoutPhase
    }
}

struct TabataState: Codable, Equatable, Sendable {
    static let startCountdownDuration: TimeInterval = 5

    var config: TabataConfig
    var phase: TabataPhase
    var round: Int
    var phaseStartedAt: Date?
    var phaseDuration: TimeInterval
    var isRunning: Bool
    var pausedRemaining: TimeInterval?
    var settings: TabataSettings

    static func idle(config: TabataConfig = .classic, settings: TabataSettings = .standard) -> TabataState {
        TabataState(
            config: config,
            phase: .idle,
            round: 0,
            phaseStartedAt: nil,
            phaseDuration: config.workDuration,
            isRunning: false,
            pausedRemaining: config.workDuration,
            settings: settings
        )
    }

    var isWorkoutPhase: Bool {
        phase == .work || phase == .rest
    }

    func remaining(at now: Date) -> TimeInterval {
        if !isRunning {
            return max(0, pausedRemaining ?? phaseDuration)
        }

        guard let phaseStartedAt else {
            return max(0, phaseDuration)
        }

        return max(0, phaseDuration - now.timeIntervalSince(phaseStartedAt))
    }

    // How much of the current phase is left, from 1 down to 0. Idle and finished screens stay full.
    func phaseFraction(at now: Date) -> Double {
        guard phase == .countdown || isWorkoutPhase, phaseDuration > 0 else {
            return 1
        }

        return min(1, remaining(at: now) / phaseDuration)
    }

    var completedRounds: Int {
        switch phase {
        case .idle, .countdown:
            0
        case .work:
            max(0, round - 1)
        case .rest:
            round
        case .complete:
            config.rounds
        }
    }
}

extension TabataState {
    private enum CodingKeys: String, CodingKey {
        case config
        case phase
        case round
        case phaseStartedAt
        case phaseDuration
        case isRunning
        case pausedRemaining
        case soundsEnabled
        case hapticsEnabled
        case startCountdownEnabled
    }

    // Settings are grouped in memory but stay flat on the wire, so a watch build that predates the
    // grouping still decodes a payload from a phone that has it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        config = try container.decode(TabataConfig.self, forKey: .config)
        phase = try container.decode(TabataPhase.self, forKey: .phase)
        round = try container.decode(Int.self, forKey: .round)
        phaseStartedAt = try container.decodeIfPresent(Date.self, forKey: .phaseStartedAt)
        phaseDuration = try container.decode(TimeInterval.self, forKey: .phaseDuration)
        isRunning = try container.decode(Bool.self, forKey: .isRunning)
        pausedRemaining = try container.decodeIfPresent(TimeInterval.self, forKey: .pausedRemaining)
        settings = TabataSettings(
            soundsEnabled: try container.decode(Bool.self, forKey: .soundsEnabled),
            hapticsEnabled: try container.decode(Bool.self, forKey: .hapticsEnabled),
            startCountdownEnabled: try container.decodeIfPresent(Bool.self, forKey: .startCountdownEnabled) ?? true
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(config, forKey: .config)
        try container.encode(phase, forKey: .phase)
        try container.encode(round, forKey: .round)
        try container.encodeIfPresent(phaseStartedAt, forKey: .phaseStartedAt)
        try container.encode(phaseDuration, forKey: .phaseDuration)
        try container.encode(isRunning, forKey: .isRunning)
        try container.encodeIfPresent(pausedRemaining, forKey: .pausedRemaining)
        try container.encode(settings.soundsEnabled, forKey: .soundsEnabled)
        try container.encode(settings.hapticsEnabled, forKey: .hapticsEnabled)
        try container.encode(settings.startCountdownEnabled, forKey: .startCountdownEnabled)
    }
}

struct TabataColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
}

struct TabataGradient: Equatable, Sendable {
    var start: TabataColor
    var end: TabataColor
}

enum TabataPrimaryAction: Equatable, Sendable {
    case toggleRunning
    case reset
}

struct TabataPresentation: Equatable, Sendable {
    var title: String
    var phoneRoundText: String
    var watchRoundText: String
    var background: TabataGradient
    var primaryButtonTitle: String
    var primaryAction: TabataPrimaryAction
    var isPrimaryButtonProminent: Bool
    var showsReset: Bool
    var resetButtonTitle: String
    var nextText: String?
    var spokenPhase: String?

    init(state: TabataState) {
        let isPaused = state.isWorkoutPhase && !state.isRunning
        let config = state.config

        showsReset = isPaused || state.phase == .complete
        resetButtonTitle = state.phase == .complete ? "Home" : "Reset"
        isPrimaryButtonProminent = state.phase == .idle || state.phase == .complete || isPaused

        if state.phase == .complete {
            primaryButtonTitle = "Again"
            primaryAction = .toggleRunning
        } else if state.phase == .countdown {
            primaryButtonTitle = "Cancel"
            primaryAction = .reset
        } else if state.phase == .idle {
            primaryButtonTitle = "Start"
            primaryAction = .toggleRunning
        } else {
            primaryButtonTitle = state.isRunning ? "Pause" : "Resume"
            primaryAction = .toggleRunning
        }

        switch state.phase {
        case .idle:
            // The clock on the home screen is the whole workout, which nothing else would say.
            phoneRoundText = "Total time · \(config.roundsText)"
            watchRoundText = "Total · \(config.roundsText)"
        case .countdown:
            phoneRoundText = "Get ready"
            watchRoundText = "Get ready"
        case .complete:
            let summary = "\(config.roundsText) · \(TabataClock.text(seconds: Int(config.totalDuration.rounded())))"
            phoneRoundText = summary
            watchRoundText = summary
        case .work, .rest:
            phoneRoundText = "Round \(state.round) of \(state.config.rounds)"
            watchRoundText = "\(state.round) / \(state.config.rounds)"
        }

        switch state.phase {
        case .countdown:
            nextText = "First up: Work \(config.workSeconds)s"
            spokenPhase = "Get ready"
        case .work:
            nextText = state.round < config.rounds ? "Next: Rest \(config.restSeconds)s" : "Final round"
            spokenPhase = "Work, round \(state.round) of \(config.rounds)"
        case .rest:
            nextText = "Next: Work \(config.workSeconds)s"
            spokenPhase = "Rest, round \(state.round) of \(config.rounds)"
        case .complete:
            nextText = nil
            spokenPhase = "Workout complete"
        case .idle:
            nextText = nil
            spokenPhase = nil
        }

        if isPaused {
            title = "PAUSED"
            background = .paused
        } else {
            switch state.phase {
            case .idle:
                title = "TABATA"
                background = .idle
            case .countdown:
                title = "READY"
                background = .countdown
            case .work:
                title = "WORK"
                background = .work
            case .rest:
                title = "REST"
                background = .rest
            case .complete:
                title = "DONE"
                background = .complete
            }
        }
    }
}

private extension TabataGradient {
    static let idle = TabataGradient(
        start: TabataColor(red: 0.03, green: 0.52, blue: 0.50),
        end: TabataColor(red: 0.18, green: 0.24, blue: 0.72)
    )
    static let work = TabataGradient(
        start: TabataColor(red: 0.90, green: 0.30, blue: 0.06),
        end: TabataColor(red: 0.72, green: 0.14, blue: 0.04)
    )
    static let countdown = TabataGradient(
        start: TabataColor(red: 0.12, green: 0.60, blue: 0.70),
        end: TabataColor(red: 0.22, green: 0.26, blue: 0.76)
    )
    static let rest = TabataGradient(
        start: TabataColor(red: 0.00, green: 0.48, blue: 0.95),
        end: TabataColor(red: 0.04, green: 0.24, blue: 0.78)
    )
    static let complete = TabataGradient(
        start: TabataColor(red: 0.08, green: 0.64, blue: 0.40),
        end: TabataColor(red: 0.04, green: 0.38, blue: 0.29)
    )
    static let paused = TabataGradient(
        start: TabataColor(red: 0.24, green: 0.24, blue: 0.27),
        end: TabataColor(red: 0.10, green: 0.11, blue: 0.13)
    )
}

struct TabataEngine {
    private(set) var state: TabataState

    init(state: TabataState = .idle()) {
        self.state = state
    }

    mutating func start(now: Date) {
        guard state.phase == .idle || state.phase == .complete else {
            resume(now: now)
            return
        }

        if state.settings.startCountdownEnabled {
            startCountdown(now: now)
            return
        }

        startWork(now: now)
    }

    // Phases are entered by moving the state forward rather than rebuilding it, so the config and
    // the settings carry across on their own.
    private mutating func startCountdown(now: Date) {
        enterPhase(.countdown, round: 0, duration: TabataState.startCountdownDuration, now: now)
    }

    private mutating func startWork(now: Date) {
        enterPhase(.work, round: 1, duration: state.config.workDuration, now: now)
    }

    private mutating func enterPhase(_ phase: TabataPhase, round: Int, duration: TimeInterval, now: Date) {
        state.phase = phase
        state.round = round
        state.phaseStartedAt = now
        state.phaseDuration = duration
        state.isRunning = true
        state.pausedRemaining = nil
    }

    mutating func pause(now: Date) {
        advance(now: now)

        guard state.isWorkoutPhase, state.isRunning else {
            return
        }

        state.pausedRemaining = state.remaining(at: now)
        state.isRunning = false
    }

    mutating func resume(now: Date) {
        guard state.isWorkoutPhase, !state.isRunning else {
            return
        }

        let remaining = state.remaining(at: now)
        state.phaseStartedAt = now.addingTimeInterval(-(state.phaseDuration - remaining))
        state.pausedRemaining = nil
        state.isRunning = true
    }

    mutating func toggleRunning(now: Date) {
        advance(now: now)

        if state.phase == .idle || state.phase == .complete {
            start(now: now)
        } else if state.isRunning {
            pause(now: now)
        } else {
            resume(now: now)
        }
    }

    mutating func reset() {
        state = .idle(config: state.config, settings: state.settings)
    }

    mutating func updateSettings(_ change: (inout TabataSettings) -> Void) {
        change(&state.settings)
    }

    mutating func tick(now: Date) -> TabataState {
        advance(now: now)
        return state
    }

    private mutating func advance(now: Date) {
        guard state.isRunning, state.phase == .countdown || state.isWorkoutPhase else {
            return
        }

        while state.isRunning, state.phase == .countdown || state.isWorkoutPhase {
            guard let startedAt = state.phaseStartedAt else {
                return
            }

            let elapsed = now.timeIntervalSince(startedAt)
            guard elapsed >= state.phaseDuration else {
                return
            }

            let nextStartedAt = startedAt.addingTimeInterval(state.phaseDuration)

            switch state.phase {
            case .countdown:
                state.phase = .work
                state.round = 1
                state.phaseStartedAt = nextStartedAt
                state.phaseDuration = state.config.workDuration
            case .work where state.round < state.config.rounds:
                state.phase = .rest
                state.phaseStartedAt = nextStartedAt
                state.phaseDuration = state.config.restDuration
            case .work:
                state.phase = .complete
                state.phaseStartedAt = nil
                state.phaseDuration = 0
                state.isRunning = false
                state.pausedRemaining = 0
            case .rest where state.round < state.config.rounds:
                state.round += 1
                state.phase = .work
                state.phaseStartedAt = nextStartedAt
                state.phaseDuration = state.config.workDuration
            case .rest:
                state.phase = .complete
                state.phaseStartedAt = nil
                state.phaseDuration = 0
                state.isRunning = false
                state.pausedRemaining = 0
            case .idle, .complete:
                return
            }
        }
    }
}

struct CountdownCue: Hashable, Sendable {
    var phase: TabataPhase
    var round: Int
    var second: Int
}

enum TabataCuePolicy {
    static func countdownCue(in state: TabataState, now: Date) -> CountdownCue? {
        guard (state.settings.soundsEnabled || state.settings.hapticsEnabled), state.isRunning, state.phase == .countdown || state.isWorkoutPhase else {
            return nil
        }

        let second = Int(ceil(state.remaining(at: now)))
        let threshold: Int
        switch state.phase {
        case .countdown, .work:
            threshold = 5
        case .rest:
            threshold = 3
        case .idle, .complete:
            return nil
        }

        guard (1...threshold).contains(second) else {
            return nil
        }

        return CountdownCue(phase: state.phase, round: state.round, second: second)
    }

    static func needsTransitionCue(from oldState: TabataState, to newState: TabataState) -> Bool {
        guard newState.settings.soundsEnabled || newState.settings.hapticsEnabled else {
            return false
        }

        if oldState.phase == .idle, newState.phase == .work {
            return false
        }

        return oldState.phase != newState.phase || oldState.round != newState.round
    }

    static func transitionCue(from oldState: TabataState, to newState: TabataState) -> TabataTransitionCue? {
        guard needsTransitionCue(from: oldState, to: newState) else {
            return nil
        }

        switch newState.phase {
        case .work:
            return .work
        case .rest:
            return .rest
        case .complete:
            return .finish
        case .idle, .countdown:
            return nil
        }
    }
}

// Each moment has its own cue, so the workout can be followed without looking at a screen.
enum TabataTransitionCue: Sendable {
    case work
    case rest
    case finish
}

// Sounds are synthesized rather than bundled, and the phone and the watch play the same ones.
enum TabataTone {
    struct Note: Sendable {
        var frequency: Double
        var duration: Double
    }

    static let tick = [Note(frequency: 880, duration: 0.09)]
    static let work = [Note(frequency: 659, duration: 0.11), Note(frequency: 988, duration: 0.2)]
    static let rest = [Note(frequency: 784, duration: 0.11), Note(frequency: 523, duration: 0.2)]
    static let finish = [
        Note(frequency: 523, duration: 0.12),
        Note(frequency: 659, duration: 0.12),
        Note(frequency: 784, duration: 0.12),
        Note(frequency: 1047, duration: 0.42)
    ]
    static let silence = [Note(frequency: 0, duration: 1)]

    static func notes(for cue: TabataTransitionCue) -> [Note] {
        switch cue {
        case .work:
            work
        case .rest:
            rest
        case .finish:
            finish
        }
    }

    static func waveData(_ notes: [Note], amplitude: Double = 0.5) -> Data {
        let sampleRate = 22_050
        var samples: [Int16] = []

        for note in notes {
            let sampleCount = Int(note.duration * Double(sampleRate))
            for sampleIndex in 0..<sampleCount {
                let position = Double(sampleIndex) / Double(sampleRate)
                // A quick attack and a longer decay keep notes from clicking, and the octave gives a
                // small phone speaker something it can project in a noisy gym.
                let attack = min(1, Double(sampleIndex) / 110)
                let decay = min(1, Double(sampleCount - sampleIndex) / Double(sampleCount) * 3)
                let wave = sin(2 * .pi * note.frequency * position) * 0.8 + sin(4 * .pi * note.frequency * position) * 0.2
                samples.append(Int16(wave * Double(Int16.max) * amplitude * attack * decay))
            }
        }

        let byteCount = samples.count * MemoryLayout<Int16>.size
        var data = Data()
        append("RIFF", to: &data)
        append(UInt32(36 + byteCount).littleEndian, to: &data)
        append("WAVE", to: &data)
        append("fmt ", to: &data)
        append(UInt32(16).littleEndian, to: &data)
        append(UInt16(1).littleEndian, to: &data)
        append(UInt16(1).littleEndian, to: &data)
        append(UInt32(sampleRate).littleEndian, to: &data)
        append(UInt32(sampleRate * MemoryLayout<Int16>.size).littleEndian, to: &data)
        append(UInt16(MemoryLayout<Int16>.size).littleEndian, to: &data)
        append(UInt16(16).littleEndian, to: &data)
        append("data", to: &data)
        append(UInt32(byteCount).littleEndian, to: &data)
        samples.forEach { append($0.littleEndian, to: &data) }
        return data
    }

    private static func append(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func append<T>(_ value: T, to data: inout Data) {
        var value = value
        withUnsafeBytes(of: &value) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

enum WatchCommand: String, Codable, Sendable {
    case start
    case pause
    case resume
    case reset
    case setSoundsEnabled
    case selectPreset
}

struct WatchCommandPayload: Codable, Sendable {
    var command: WatchCommand
    var soundsEnabled: Bool?
    var presetID: String?
    var issuedAt: Date?

    // Commands queue up while the phone is out of reach, and one replayed later would act on a
    // workout it was never meant for. A watch build that sends no timestamp is taken at its word.
    static let maxAge: TimeInterval = 10

    init(command: WatchCommand, soundsEnabled: Bool? = nil, presetID: String? = nil, issuedAt: Date? = Date()) {
        self.command = command
        self.soundsEnabled = soundsEnabled
        self.presetID = presetID
        self.issuedAt = issuedAt
    }

    func isFresh(at now: Date) -> Bool {
        guard let issuedAt else {
            return true
        }

        return now.timeIntervalSince(issuedAt) <= Self.maxAge
    }
}

extension TabataState {
    private enum SyncKey {
        static let presets = "syncPresets"
        static let selectedPresetID = "syncSelectedPresetID"
        static let revision = "syncRevision"
    }

    func payloadDictionary() -> [String: Any] {
        CodablePayload.dictionary(from: self)
    }

    // The catalog rides in the same dictionary as the state rather than replacing it, so a watch
    // build that only knows about the state keys keeps mirroring a newer phone.
    func payloadDictionary(catalog: TabataPresetCatalog, revision: TimeInterval = Date().timeIntervalSince1970) -> [String: Any] {
        var dictionary = payloadDictionary()
        dictionary[SyncKey.revision] = revision
        dictionary[SyncKey.presets] = CodablePayload.array(from: catalog.presets)
        dictionary[SyncKey.selectedPresetID] = catalog.selectedID
        return dictionary
    }

    static func fromPayloadDictionary(_ dictionary: [String: Any]) -> TabataState? {
        CodablePayload.value(TabataState.self, from: dictionary)
    }

    // Every publish goes out twice, as a message and as the application context, and the two can
    // arrive in either order, so the watch uses this to ignore anything older than it has seen.
    static func revisionFromPayloadDictionary(_ dictionary: [String: Any]) -> TimeInterval? {
        dictionary[SyncKey.revision] as? TimeInterval
    }

    static func catalogFromPayloadDictionary(_ dictionary: [String: Any]) -> TabataPresetCatalog? {
        guard
            let rawPresets = dictionary[SyncKey.presets] as? [Any],
            let selectedID = dictionary[SyncKey.selectedPresetID] as? String
        else {
            return nil
        }

        let presets = CodablePayload.values(TabataPreset.self, from: rawPresets)
        guard !presets.isEmpty else {
            return nil
        }

        return TabataPresetCatalog(customPresets: presets.filter { !$0.isDefault }, selectedID: selectedID)
    }
}

extension WatchCommandPayload {
    func payloadDictionary() -> [String: Any] {
        CodablePayload.dictionary(from: self)
    }

    static func fromPayloadDictionary(_ dictionary: [String: Any]) -> WatchCommandPayload? {
        CodablePayload.value(WatchCommandPayload.self, from: dictionary)
    }
}

private enum CodablePayload {
    static func dictionary<T: Encodable>(from value: T) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        guard
            let data = try? encoder.encode(value),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return [:]
        }

        return dictionary
    }

    static func array<T: Encodable>(from values: [T]) -> [[String: Any]] {
        values.map { dictionary(from: $0) }.filter { !$0.isEmpty }
    }

    static func values<T: Decodable>(_ type: T.Type, from array: [Any]) -> [T] {
        array.compactMap { element in
            guard let dictionary = element as? [String: Any] else {
                return nil
            }

            return value(type, from: dictionary)
        }
    }

    static func value<T: Decodable>(_ type: T.Type, from dictionary: [String: Any]) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        guard
            JSONSerialization.isValidJSONObject(dictionary),
            let data = try? JSONSerialization.data(withJSONObject: dictionary),
            let value = try? decoder.decode(type, from: data)
        else {
            return nil
        }

        return value
    }
}
