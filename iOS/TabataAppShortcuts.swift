import AppIntents

// Siri and Shortcuts run these in the app process, launching it in the background when needed, so a
// workout can be started without unlocking the phone or leaving the exercise.
// Presets are exposed as entities so a shortcut or a spoken phrase can name one; leaving the
// parameter empty starts whichever preset is selected in the app.
struct TabataPresetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Preset")
    static let defaultQuery = TabataPresetQuery()

    var id: String
    var name: String
    var timingText: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(timingText)")
    }
}

struct TabataPresetQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TabataPresetEntity] {
        allPresets().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [TabataPresetEntity] {
        allPresets().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [TabataPresetEntity] {
        allPresets()
    }

    private func allPresets() -> [TabataPresetEntity] {
        TabataPresetStore().loadCatalog().presets.map { preset in
            TabataPresetEntity(id: preset.id, name: preset.name, timingText: preset.timingText)
        }
    }
}

// Starting from the background needs both conformances: iOS only allows a Live Activity request
// from a LiveActivityIntent, and only allows the keep-alive audio from an AudioPlaybackIntent.
struct StartWorkoutIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Start Workout"
    static let description = IntentDescription("Starts a workout, using the selected preset unless another is named.")
    static let openAppWhenRun = false

    @Parameter(title: "Preset")
    var preset: TabataPresetEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let presetID = preset?.id

        let startedName = await MainActor.run { () -> String? in
            let workout = WorkoutViewModel.shared()
            workout.activate()

            guard workout.state.phase == .idle || workout.state.phase == .complete else {
                return nil
            }

            if let presetID {
                // A finished workout has to return to idle before the catalog will switch presets.
                workout.reset()
                workout.selectPreset(id: presetID)
            }

            workout.start()
            return workout.selectedPreset.name
        }

        guard let startedName else {
            return .result(dialog: "A workout is already running.")
        }

        return .result(dialog: "Starting \(startedName).")
    }
}

struct PauseWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Workout"
    static let description = IntentDescription("Pauses the workout that is currently running.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let didPause = await MainActor.run { () -> Bool in
            let workout = WorkoutViewModel.shared()
            workout.activate()

            guard workout.state.isWorkoutPhase, workout.state.isRunning else {
                return false
            }

            workout.pause()
            return true
        }

        return .result(dialog: didPause ? "Workout paused." : "No workout is running.")
    }
}

struct ResumeWorkoutIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Workout"
    static let description = IntentDescription("Resumes a paused workout.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let didResume = await MainActor.run { () -> Bool in
            let workout = WorkoutViewModel.shared()
            workout.activate()

            guard workout.state.isWorkoutPhase, !workout.state.isRunning else {
                return false
            }

            workout.resume()
            return true
        }

        return .result(dialog: didResume ? "Workout resumed." : "No workout is paused.")
    }
}

struct TabataShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWorkoutIntent(),
            phrases: [
                "Start a workout with \(.applicationName)",
                "Start a Tabata with \(.applicationName)",
                "Start \(.applicationName)",
                "Start my \(\.$preset) workout with \(.applicationName)",
                "Start \(\.$preset) with \(.applicationName)"
            ],
            shortTitle: "Start Workout",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: PauseWorkoutIntent(),
            phrases: [
                "Pause my workout with \(.applicationName)",
                "Pause \(.applicationName)"
            ],
            shortTitle: "Pause Workout",
            systemImageName: "pause.fill"
        )

        AppShortcut(
            intent: ResumeWorkoutIntent(),
            phrases: [
                "Resume my workout with \(.applicationName)",
                "Resume \(.applicationName)"
            ],
            shortTitle: "Resume Workout",
            systemImageName: "playpause.fill"
        )

        AppShortcut(
            intent: EndWorkoutIntent(),
            phrases: [
                "End my workout with \(.applicationName)",
                "Stop my workout with \(.applicationName)"
            ],
            shortTitle: "End Workout",
            systemImageName: "xmark"
        )
    }
}
