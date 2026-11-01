import XCTest

#if canImport(TabataCore)
@testable import TabataCore
#endif

final class TabataCoreTests: XCTestCase {
    func testClassicWorkoutStartsWithCountdownByDefault() {
        let now = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        engine.start(now: now)

        XCTAssertEqual(engine.state.phase, .countdown)
        XCTAssertEqual(engine.state.round, 0)
        XCTAssertEqual(engine.state.remaining(at: now), 5)
    }

    func testCountdownTransitionsToWork() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        engine.start(now: start)
        let state = engine.tick(now: start.addingTimeInterval(5))

        XCTAssertEqual(state.phase, .work)
        XCTAssertEqual(state.round, 1)
        XCTAssertEqual(state.remaining(at: start.addingTimeInterval(5)), 20)
    }

    func testDisabledStartCountdownStartsWithWork() {
        let now = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        engine.updateSettings { $0.startCountdownEnabled = false }
        engine.start(now: now)

        XCTAssertEqual(engine.state.phase, .work)
        XCTAssertEqual(engine.state.round, 1)
        XCTAssertEqual(engine.state.remaining(at: now), 20)
    }

    func testTransitionsFromWorkToRest() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)
        let state = engine.tick(now: start.addingTimeInterval(20))

        XCTAssertEqual(state.phase, .rest)
        XCTAssertEqual(state.round, 1)
        XCTAssertEqual(state.remaining(at: start.addingTimeInterval(20)), 10)
    }

    func testTransitionsFromRestToNextRound() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)
        let state = engine.tick(now: start.addingTimeInterval(30))

        XCTAssertEqual(state.phase, .work)
        XCTAssertEqual(state.round, 2)
        XCTAssertEqual(state.remaining(at: start.addingTimeInterval(30)), 20)
    }

    func testCompletesAfterEightRounds() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)
        let state = engine.tick(now: start.addingTimeInterval(230))

        XCTAssertEqual(state.phase, .complete)
        XCTAssertEqual(state.round, 8)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.remaining(at: start.addingTimeInterval(230)), 0)
    }

    func testFinalWorkRoundSkipsRestAndCompletes() {
        let start = Date(timeIntervalSince1970: 100)
        let config = TabataConfig(rounds: 2, workDuration: 20, restDuration: 10)
        var engine = TabataEngine(state: .idle(config: config))

        startWorkout(&engine, now: start)
        let state = engine.tick(now: start.addingTimeInterval(50))

        XCTAssertEqual(state.phase, .complete)
        XCTAssertEqual(state.round, 2)
    }

    func testPauseAndResumePreserveRemainingTime() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)
        engine.pause(now: start.addingTimeInterval(7))

        XCTAssertFalse(engine.state.isRunning)
        XCTAssertEqual(engine.state.remaining(at: start.addingTimeInterval(50)), 13)

        engine.resume(now: start.addingTimeInterval(100))

        XCTAssertTrue(engine.state.isRunning)
        XCTAssertEqual(engine.state.remaining(at: start.addingTimeInterval(105)), 8)
    }

    func testToggleRunningStartsPausesResumesAndRestartsCompleteWorkout() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()
        engine.updateSettings { $0.startCountdownEnabled = false }

        engine.toggleRunning(now: start)

        XCTAssertEqual(engine.state.phase, .work)
        XCTAssertTrue(engine.state.isRunning)

        engine.toggleRunning(now: start.addingTimeInterval(3))

        XCTAssertFalse(engine.state.isRunning)
        XCTAssertEqual(engine.state.remaining(at: start.addingTimeInterval(100)), 17)

        engine.toggleRunning(now: start.addingTimeInterval(30))

        XCTAssertTrue(engine.state.isRunning)
        XCTAssertEqual(engine.state.remaining(at: start.addingTimeInterval(30)), 17)

        _ = engine.tick(now: start.addingTimeInterval(270))

        XCTAssertEqual(engine.state.phase, .complete)

        engine.toggleRunning(now: start.addingTimeInterval(300))

        XCTAssertEqual(engine.state.phase, .work)
        XCTAssertEqual(engine.state.round, 1)
        XCTAssertTrue(engine.state.isRunning)
    }

    func testLongTimeJumpLandsInCorrectPhase() {
        let start = Date(timeIntervalSince1970: 100)
        let config = TabataConfig(rounds: 3, workDuration: 20, restDuration: 10)
        var engine = TabataEngine(state: .idle(config: config))

        startWorkout(&engine, now: start)
        let state = engine.tick(now: start.addingTimeInterval(65))

        XCTAssertEqual(state.phase, .work)
        XCTAssertEqual(state.round, 3)
        XCTAssertEqual(state.remaining(at: start.addingTimeInterval(65)), 15)
    }

    func testCountdownCuePolicy() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)

        XCTAssertNil(TabataCuePolicy.countdownCue(in: engine.state, now: start.addingTimeInterval(14)))
        XCTAssertEqual(TabataCuePolicy.countdownCue(in: engine.state, now: start.addingTimeInterval(15))?.second, 5)
        XCTAssertEqual(TabataCuePolicy.countdownCue(in: engine.state, now: start.addingTimeInterval(19.2))?.second, 1)

        let restState = engine.tick(now: start.addingTimeInterval(20))

        XCTAssertNil(TabataCuePolicy.countdownCue(in: restState, now: start.addingTimeInterval(26)))
        XCTAssertEqual(TabataCuePolicy.countdownCue(in: restState, now: start.addingTimeInterval(27))?.second, 3)
    }

    func testTransitionCuePolicySuppressesStartAndUnchangedState() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()
        let idleState = engine.state

        startWorkout(&engine, now: start)
        let workState = engine.state

        XCTAssertFalse(TabataCuePolicy.needsTransitionCue(from: idleState, to: workState))
        XCTAssertFalse(TabataCuePolicy.needsTransitionCue(from: workState, to: workState))

        let restState = engine.tick(now: start.addingTimeInterval(20))

        XCTAssertTrue(TabataCuePolicy.needsTransitionCue(from: workState, to: restState))

        var mutedRestState = restState
        mutedRestState.settings.soundsEnabled = false
        mutedRestState.settings.hapticsEnabled = false

        XCTAssertFalse(TabataCuePolicy.needsTransitionCue(from: workState, to: mutedRestState))
    }

    func testCueSettingsSuppressCuesWhenBothAreOff() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)
        engine.updateSettings { $0.soundsEnabled = false }
        engine.updateSettings { $0.hapticsEnabled = false }

        XCTAssertNil(TabataCuePolicy.countdownCue(in: engine.state, now: start.addingTimeInterval(15)))
        XCTAssertFalse(TabataCuePolicy.needsTransitionCue(from: engine.state, to: engine.tick(now: start.addingTimeInterval(20))))
    }

    func testHapticOnlyCuesStillRun() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)
        engine.updateSettings { $0.soundsEnabled = false }

        XCTAssertEqual(TabataCuePolicy.countdownCue(in: engine.state, now: start.addingTimeInterval(15))?.second, 5)
    }

    func testResetPreservesCueSettings() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        engine.updateSettings { $0.soundsEnabled = false }
        engine.updateSettings { $0.hapticsEnabled = false }
        engine.updateSettings { $0.startCountdownEnabled = false }
        startWorkout(&engine, now: start)
        engine.reset()

        XCTAssertFalse(engine.state.settings.soundsEnabled)
        XCTAssertFalse(engine.state.settings.hapticsEnabled)
        XCTAssertFalse(engine.state.settings.startCountdownEnabled)
        XCTAssertEqual(engine.state.phase, .idle)
    }

    func testPresetNameUsesWorkRestAndRounds() {
        let config = TabataConfig.preset(workSeconds: 45, restSeconds: 15, rounds: 6)

        XCTAssertEqual(config.presetName, "45/15/6")
    }

    func testPresetCatalogDefaultsToClassicAndSelectedPreset() {
        let custom = TabataPreset(
            id: "custom",
            config: TabataConfig.preset(workSeconds: 40, restSeconds: 20, rounds: 5),
            isDefault: false
        )
        let catalog = TabataPresetCatalog(customPresets: [custom], selectedID: "custom")

        XCTAssertEqual(catalog.presets.map(\.name), ["20/10/8", "40/20/5"])
        XCTAssertEqual(catalog.selectedPreset, custom)
    }

    func testPresetNameFallsBackToItsTimings() {
        var catalog = TabataPresetCatalog()
        catalog.addUserPreset(config: TabataConfig.preset(workSeconds: 45, restSeconds: 15, rounds: 6), id: "custom")

        XCTAssertEqual(catalog.selectedPreset.name, "45/15/6")
        XCTAssertFalse(catalog.selectedPreset.hasCustomName)

        catalog.updateUserPreset(id: "custom", config: catalog.selectedPreset.config, name: "  Sprints  ")

        XCTAssertEqual(catalog.selectedPreset.name, "Sprints")
        XCTAssertEqual(catalog.selectedPreset.timingText, "45/15/6")
        XCTAssertTrue(catalog.selectedPreset.hasCustomName)
    }

    func testBlankNamesAreDroppedAndLongOnesAreCapped() {
        var catalog = TabataPresetCatalog()
        catalog.addUserPreset(config: .classic, name: "   ", id: "blank")

        XCTAssertFalse(catalog.selectedPreset.hasCustomName)

        catalog.updateUserPreset(id: "blank", config: .classic, name: String(repeating: "a", count: 100))

        XCTAssertEqual(catalog.selectedPreset.name.count, TabataPreset.maxNameLength)
    }

    func testPresetsSavedBeforeNamingStillDecode() {
        let stored = """
        {"id":"custom","config":{"rounds":6,"workDuration":45,"restDuration":15},"isDefault":false}
        """

        let decoded = try? JSONDecoder().decode(TabataPreset.self, from: Data(stored.utf8))

        XCTAssertEqual(decoded?.name, "45/15/6")
        XCTAssertNil(decoded?.customName)
    }

    func testStoredPresetsOutsideTheEditorRangesAreClamped() {
        let broken = TabataPreset(
            id: "broken",
            config: TabataConfig(rounds: 0, workDuration: 0, restDuration: 9_000),
            isDefault: false
        )
        let catalog = TabataPresetCatalog(customPresets: [broken], selectedID: "broken")

        XCTAssertEqual(catalog.selectedPreset.config.workSeconds, TabataConfig.workSecondsRange.lowerBound)
        XCTAssertEqual(catalog.selectedPreset.config.restSeconds, TabataConfig.restSecondsRange.upperBound)
        XCTAssertEqual(catalog.selectedPreset.config.rounds, TabataConfig.roundsRange.lowerBound)
    }

    func testCreatedAndEditedPresetsAreClamped() {
        var catalog = TabataPresetCatalog()
        catalog.addUserPreset(config: TabataConfig(rounds: 99, workDuration: 1, restDuration: 10), id: "custom")

        XCTAssertEqual(catalog.selectedPreset.config.rounds, TabataConfig.roundsRange.upperBound)
        XCTAssertEqual(catalog.selectedPreset.config.workSeconds, TabataConfig.workSecondsRange.lowerBound)

        catalog.updateUserPreset(id: "custom", config: TabataConfig(rounds: 4, workDuration: 4_000, restDuration: 10))

        XCTAssertEqual(catalog.selectedPreset.config.workSeconds, TabataConfig.workSecondsRange.upperBound)
    }

    func testPresetCatalogProtectsDefaultPreset() {
        var catalog = TabataPresetCatalog()

        XCTAssertFalse(catalog.deleteUserPreset(id: TabataPreset.defaultID))
        XCTAssertFalse(catalog.updateUserPreset(id: TabataPreset.defaultID, config: TabataConfig.preset(workSeconds: 30, restSeconds: 15, rounds: 4)))
        XCTAssertEqual(catalog.selectedPreset, .classic)
    }

    func testPresetCatalogAllowsDuplicatesAndCapsAtFourTotalPresets() {
        var catalog = TabataPresetCatalog()

        XCTAssertNotNil(catalog.addUserPreset(config: TabataConfig.preset(workSeconds: 30, restSeconds: 15, rounds: 4), id: "one"))
        XCTAssertNotNil(catalog.addUserPreset(config: TabataConfig.preset(workSeconds: 30, restSeconds: 15, rounds: 4), id: "duplicate"))
        XCTAssertNotNil(catalog.addUserPreset(config: TabataConfig.preset(workSeconds: 45, restSeconds: 15, rounds: 5), id: "two"))
        XCTAssertNil(catalog.addUserPreset(config: TabataConfig.preset(workSeconds: 60, restSeconds: 30, rounds: 6), id: "three"))

        XCTAssertEqual(catalog.presets.count, 4)
        XCTAssertEqual(catalog.userPresets.map(\.name), ["30/15/4", "30/15/4", "45/15/5"])
        XCTAssertFalse(catalog.canCreatePreset)
    }

    func testInterruptedWorkoutRestoresAtItsCurrentPhase() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)
        let saved = engine.state
        let restored = TabataStateStore.restorable(saved, savedAt: start, now: start.addingTimeInterval(35))

        XCTAssertEqual(restored?.phase, .work)
        XCTAssertEqual(restored?.round, 2)
        XCTAssertEqual(restored?.remaining(at: start.addingTimeInterval(35)), 15)
    }

    func testPausedWorkoutRestoresWithRemainingTimeIntact() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)
        engine.pause(now: start.addingTimeInterval(8))
        let restored = TabataStateStore.restorable(engine.state, savedAt: start.addingTimeInterval(8), now: start.addingTimeInterval(600))

        XCTAssertEqual(restored?.phase, .work)
        XCTAssertFalse(restored?.isRunning ?? true)
        XCTAssertEqual(restored?.remaining(at: start.addingTimeInterval(600)), 12)
    }

    func testWorkoutThatFinishedWhileAwayDoesNotRestore() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)

        XCTAssertNil(TabataStateStore.restorable(engine.state, savedAt: start, now: start.addingTimeInterval(400)))
    }

    func testStaleAndIdleStatesDoNotRestore() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)
        let stale = start.addingTimeInterval(TabataStateStore.maxRestoreAge + 1)

        XCTAssertNil(TabataStateStore.restorable(engine.state, savedAt: start, now: stale))
        XCTAssertNil(TabataStateStore.restorable(.idle(), savedAt: start, now: start.addingTimeInterval(5)))
    }

    func testStatePayloadRoundTrips() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        startWorkout(&engine, now: start)
        engine.pause(now: start.addingTimeInterval(7))

        let decoded = TabataState.fromPayloadDictionary(engine.state.payloadDictionary())

        XCTAssertEqual(decoded, engine.state)
    }

    func testStatePayloadDefaultsMissingStartCountdownSettingOn() {
        var dictionary = TabataState.idle().payloadDictionary()
        dictionary.removeValue(forKey: "startCountdownEnabled")

        let decoded = TabataState.fromPayloadDictionary(dictionary)

        XCTAssertEqual(decoded?.settings.startCountdownEnabled, true)
    }

    func testSettingsStayFlatInThePayloadForOlderWatchBuilds() {
        var state = TabataState.idle()
        state.settings.soundsEnabled = false
        let payload = state.payloadDictionary()

        XCTAssertEqual(payload["soundsEnabled"] as? Bool, false)
        XCTAssertEqual(payload["hapticsEnabled"] as? Bool, true)
        XCTAssertEqual(payload["startCountdownEnabled"] as? Bool, true)
        XCTAssertNil(payload["settings"])
        XCTAssertEqual(TabataState.fromPayloadDictionary(payload), state)
    }

    func testStatePayloadCarriesPresetCatalogToTheWatch() {
        var catalog = TabataPresetCatalog()
        catalog.addUserPreset(config: TabataConfig.preset(workSeconds: 45, restSeconds: 15, rounds: 6), id: "custom")
        let payload = TabataState.idle().payloadDictionary(catalog: catalog)

        let decoded = TabataState.catalogFromPayloadDictionary(payload)

        XCTAssertEqual(decoded?.presets.map(\.name), ["20/10/8", "45/15/6"])
        XCTAssertEqual(decoded?.selectedID, "custom")
        XCTAssertEqual(TabataState.fromPayloadDictionary(payload), TabataState.idle())
    }

    func testStateStillDecodesWhenThePhoneSendsNoCatalog() {
        let payload = TabataState.idle().payloadDictionary()

        XCTAssertNotNil(TabataState.fromPayloadDictionary(payload))
        XCTAssertNil(TabataState.catalogFromPayloadDictionary(payload))
    }

    func testSelectPresetCommandRoundTrips() {
        let payload = WatchCommandPayload(command: .selectPreset, presetID: "custom")
        let decoded = WatchCommandPayload.fromPayloadDictionary(payload.payloadDictionary())

        XCTAssertEqual(decoded?.command, .selectPreset)
        XCTAssertEqual(decoded?.presetID, "custom")
        XCTAssertNil(decoded?.soundsEnabled)
    }

    func testWatchCommandPayloadRoundTripsForFallbackDelivery() {
        let payload = WatchCommandPayload(command: .pause, soundsEnabled: nil)
        let decoded = WatchCommandPayload.fromPayloadDictionary(payload.payloadDictionary())

        XCTAssertEqual(decoded?.command, .pause)
        XCTAssertNil(decoded?.soundsEnabled)
    }

    func testInvalidPayloadsReturnNil() {
        XCTAssertNil(TabataState.fromPayloadDictionary(["phase": "bogus"]))
        XCTAssertNil(WatchCommandPayload.fromPayloadDictionary(["command": "bogus"]))
        XCTAssertNil(WatchCommandPayload.fromPayloadDictionary(["command": Date()]))
    }

    func testPresentationForIdleRunningPausedAndCompleteStates() {
        let start = Date(timeIntervalSince1970: 100)
        var engine = TabataEngine()

        let idle = TabataPresentation(state: engine.state)

        XCTAssertEqual(idle.title, "TABATA")
        XCTAssertEqual(idle.phoneRoundText, "8 rounds")
        XCTAssertEqual(idle.watchRoundText, "8 rounds")
        XCTAssertEqual(idle.primaryButtonTitle, "Start")
        XCTAssertEqual(idle.primaryAction, .toggleRunning)
        XCTAssertTrue(idle.isPrimaryButtonProminent)
        XCTAssertFalse(idle.showsReset)

        engine.start(now: start)
        let countdown = TabataPresentation(state: engine.state)

        XCTAssertEqual(countdown.title, "READY")
        XCTAssertEqual(countdown.phoneRoundText, "Get ready")
        XCTAssertEqual(countdown.primaryButtonTitle, "Cancel")
        XCTAssertEqual(countdown.primaryAction, .reset)

        engine.reset()
        engine.updateSettings { $0.startCountdownEnabled = false }

        startWorkout(&engine, now: start)
        let work = TabataPresentation(state: engine.state)

        XCTAssertEqual(work.title, "WORK")
        XCTAssertEqual(work.phoneRoundText, "Round 1 of 8")
        XCTAssertEqual(work.watchRoundText, "1 / 8")
        XCTAssertEqual(work.primaryButtonTitle, "Pause")
        XCTAssertFalse(work.isPrimaryButtonProminent)

        engine.pause(now: start.addingTimeInterval(5))
        let paused = TabataPresentation(state: engine.state)

        XCTAssertEqual(paused.title, "PAUSED")
        XCTAssertEqual(paused.primaryButtonTitle, "Resume")
        XCTAssertTrue(paused.isPrimaryButtonProminent)
        XCTAssertTrue(paused.showsReset)

        engine.resume(now: start.addingTimeInterval(10))
        let complete = TabataPresentation(state: engine.tick(now: start.addingTimeInterval(260)))

        XCTAssertEqual(complete.title, "DONE")
        XCTAssertEqual(complete.phoneRoundText, "8 rounds · 3:50")
        XCTAssertEqual(complete.primaryButtonTitle, "Again")
        XCTAssertEqual(complete.primaryAction, .toggleRunning)
        XCTAssertTrue(complete.showsReset)
        XCTAssertEqual(complete.resetButtonTitle, "Home")
    }

    func testPresentationUsesSelectedConfigForIdleRounds() {
        let state = TabataState.idle(config: TabataConfig.preset(workSeconds: 45, restSeconds: 15, rounds: 6))
        let presentation = TabataPresentation(state: state)

        XCTAssertEqual(presentation.phoneRoundText, "6 rounds")
        XCTAssertEqual(presentation.watchRoundText, "6 rounds")
    }

    private func startWorkout(_ engine: inout TabataEngine, now: Date) {
        engine.updateSettings { $0.startCountdownEnabled = false }
        engine.start(now: now)
    }

    func testPausingAfterMissedTicksPausesThePhaseItIsReallyIn() {
        let start = Date(timeIntervalSince1970: 1_000)
        var engine = TabataEngine(state: .idle(settings: TabataSettings(soundsEnabled: true, hapticsEnabled: true, startCountdownEnabled: false)))
        engine.start(now: start)

        engine.pause(now: start.addingTimeInterval(25))

        XCTAssertEqual(engine.state.phase, .rest)
        XCTAssertFalse(engine.state.isRunning)
        XCTAssertEqual(engine.state.remaining(at: start.addingTimeInterval(99)), 5, accuracy: 0.001)
    }

    func testTogglingAfterTheWorkoutEndedDoesNotStartAnother() {
        let start = Date(timeIntervalSince1970: 1_000)
        var engine = TabataEngine(state: .idle(config: .preset(workSeconds: 5, restSeconds: 5, rounds: 1), settings: TabataSettings(soundsEnabled: true, hapticsEnabled: true, startCountdownEnabled: false)))
        engine.start(now: start)

        engine.pause(now: start.addingTimeInterval(60))

        XCTAssertEqual(engine.state.phase, .complete)
    }

    func testEachTransitionHasItsOwnCue() {
        let start = Date(timeIntervalSince1970: 1_000)
        var engine = TabataEngine(state: .idle(config: .preset(workSeconds: 5, restSeconds: 5, rounds: 2), settings: TabataSettings(soundsEnabled: true, hapticsEnabled: true, startCountdownEnabled: false)))
        engine.start(now: start)
        let work = engine.state
        let rest = engine.tick(now: start.addingTimeInterval(5))
        let secondWork = engine.tick(now: start.addingTimeInterval(10))
        let complete = engine.tick(now: start.addingTimeInterval(15))

        XCTAssertEqual(TabataCuePolicy.transitionCue(from: work, to: rest), .rest)
        XCTAssertEqual(TabataCuePolicy.transitionCue(from: rest, to: secondWork), .work)
        XCTAssertEqual(TabataCuePolicy.transitionCue(from: secondWork, to: complete), .finish)
        XCTAssertNil(TabataCuePolicy.transitionCue(from: work, to: .idle()))
    }

    func testStaleWatchCommandsAreNotFresh() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(WatchCommandPayload(command: .start, issuedAt: now.addingTimeInterval(-5)).isFresh(at: now))
        XCTAssertFalse(WatchCommandPayload(command: .start, issuedAt: now.addingTimeInterval(-60)).isFresh(at: now))
        XCTAssertTrue(WatchCommandPayload(command: .start, issuedAt: nil).isFresh(at: now))
    }

    func testPayloadCarriesItsRevision() {
        let dictionary = TabataState.idle().payloadDictionary(catalog: TabataPresetCatalog(), revision: 42)

        XCTAssertEqual(TabataState.revisionFromPayloadDictionary(dictionary), 42)
        XCTAssertNotNil(TabataState.fromPayloadDictionary(dictionary))
    }

    func testTotalDurationSkipsTheFinalRest() {
        XCTAssertEqual(TabataConfig.classic.totalDuration, 230)
        XCTAssertEqual(TabataConfig.preset(workSeconds: 30, restSeconds: 10, rounds: 1).totalDuration, 30)
    }

    func testSingleRoundIsSingular() {
        let presentation = TabataPresentation(state: .idle(config: .preset(workSeconds: 20, restSeconds: 10, rounds: 1)))

        XCTAssertEqual(presentation.phoneRoundText, "1 round")
    }

    func testCompletedRoundsAndPhaseFraction() {
        let start = Date(timeIntervalSince1970: 1_000)
        var engine = TabataEngine(state: .idle(settings: TabataSettings(soundsEnabled: true, hapticsEnabled: true, startCountdownEnabled: false)))
        engine.start(now: start)

        XCTAssertEqual(engine.state.completedRounds, 0)
        XCTAssertEqual(engine.state.phaseFraction(at: start.addingTimeInterval(5)), 0.75, accuracy: 0.001)
        XCTAssertEqual(engine.tick(now: start.addingTimeInterval(21)).completedRounds, 1)
    }

    func testClockDropsTheMinutesUnderAMinute() {
        XCTAssertEqual(TabataClock.compactText(seconds: 20), "20")
        XCTAssertEqual(TabataClock.compactText(seconds: 75), "1:15")
    }

    func testToneDataIsAWaveOfTheRightLength() {
        let data = TabataTone.waveData(TabataTone.tick)

        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(data.count, 44 + 2 * Int(0.09 * 22_050))
    }
}
