import ActivityKit
import Foundation

@MainActor
final class TabataLiveActivityController {
    private var activity: Activity<TabataLiveActivityAttributes>?
    private var didReportRequestFailure = false
    private var lastOperation: Task<Void, Never>?

    // Starts at the countdown rather than the first work phase: iOS only allows the request while
    // the app is in front, and the phone has usually been locked by the time the countdown ends.
    func sync(state: TabataState, now: Date) {
        if state.phase == .complete {
            finish(state: state, now: now)
            return
        }

        guard state.phase == .countdown || state.isWorkoutPhase else {
            end()
            return
        }

        let contentState = TabataLiveActivityAttributes.ContentState(state: state, now: now)
        // Each phase's update comes from the app, so if one is overdue the app is no longer running
        // and the timer on screen can't be trusted.
        let content = ActivityContent(
            state: contentState,
            staleDate: contentState.isRunning ? contentState.endsAt.addingTimeInterval(Self.staleGrace) : nil,
            relevanceScore: contentState.isRunning ? 1 : 0.5
        )

        let liveActivity = activity ?? Activity<TabataLiveActivityAttributes>.activities.first { $0.activityState == .active }
        if let existingActivity = liveActivity {
            activity = existingActivity
            let activityID = existingActivity.id
            enqueue {
                guard let activity = Activity<TabataLiveActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
                    return
                }

                await activity.update(content)
            }
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        // A finished workout's card may still be lingering when the next one starts.
        end()

        do {
            activity = try Activity.request(
                attributes: TabataLiveActivityAttributes(workoutName: "Tabata"),
                content: content,
                pushType: nil
            )
        } catch {
            activity = nil

            // Requesting again on the next phase change is what lets an activity appear once the app
            // reaches the foreground, so only the first failure of an attempt is worth reporting.
            if !didReportRequestFailure {
                didReportRequestFailure = true
                TabataDiagnostics.report("Starting the Live Activity failed", error: error)
            }
        }
    }

    func end() {
        let activityIDs = Activity<TabataLiveActivityAttributes>.activities.map(\.id)
        activity = nil
        didReportRequestFailure = false

        guard !activityIDs.isEmpty else {
            return
        }

        enqueue {
            for activity in Activity<TabataLiveActivityAttributes>.activities where activityIDs.contains(activity.id) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // The card stays up for a minute showing what was done, so the workout doesn't just vanish.
    private func finish(state: TabataState, now: Date) {
        guard let activityID = activity?.id else {
            return
        }

        let content = ActivityContent(
            state: TabataLiveActivityAttributes.ContentState(state: state, now: now),
            staleDate: nil
        )
        let dismissal = now.addingTimeInterval(Self.finishedLinger)
        activity = nil
        didReportRequestFailure = false

        enqueue {
            guard let activity = Activity<TabataLiveActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
                return
            }

            await activity.end(content, dismissalPolicy: .after(dismissal))
        }
    }

    // ActivityKit calls are async, and a pause and resume in quick succession must land in order.
    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = lastOperation
        lastOperation = Task.detached {
            await previous?.value
            await operation()
        }
    }

    private static let staleGrace: TimeInterval = 5
    private static let finishedLinger: TimeInterval = 60
}

private extension TabataLiveActivityAttributes.ContentState {
    init(state: TabataState, now: Date) {
        let presentation = TabataPresentation(state: state)
        let tint = presentation.background.start
        let phaseDuration = max(1, state.phaseDuration)

        title = presentation.title
        roundText = state.isWorkoutPhase ? "Round \(state.round)/\(state.config.rounds)" : presentation.phoneRoundText
        nextText = presentation.nextText
        summaryText = state.phase == .complete ? presentation.phoneRoundText : nil
        isRunning = state.isRunning
        phaseIconName = Self.iconName(for: state)

        // The exact phase boundaries, not a rounded remaining count, because the system renders the
        // countdown from these dates. A paused phase is frozen by pointing pausedAt at this moment.
        if state.isRunning, let phaseStartedAt = state.phaseStartedAt {
            startsAt = phaseStartedAt
            endsAt = phaseStartedAt.addingTimeInterval(phaseDuration)
            pausedAt = nil
        } else {
            let phaseEnd = now.addingTimeInterval(state.remaining(at: now))
            startsAt = phaseEnd.addingTimeInterval(-phaseDuration)
            endsAt = phaseEnd
            pausedAt = now
        }

        workoutEndsAt = now.addingTimeInterval(Self.workoutRemainingDuration(for: state, now: now))
        tintRed = tint.red
        tintGreen = tint.green
        tintBlue = tint.blue
    }

    private static func iconName(for state: TabataState) -> String {
        guard state.isRunning else {
            return state.phase == .complete ? "checkmark" : "pause.fill"
        }

        switch state.phase {
        case .work:
            return "bolt.fill"
        case .rest:
            return "wind"
        case .idle, .countdown, .complete:
            return "timer"
        }
    }

    private static func workoutRemainingDuration(for state: TabataState, now: Date) -> TimeInterval {
        if state.phase == .countdown {
            return state.remaining(at: now) + state.config.totalDuration
        }

        guard state.isRunning, state.isWorkoutPhase else {
            return state.remaining(at: now)
        }

        let phaseRemaining = state.remaining(at: now)
        let fullFutureRoundDuration = state.config.workDuration + state.config.restDuration

        switch state.phase {
        case .work:
            return phaseRemaining
                + TimeInterval(max(0, state.config.rounds - state.round)) * fullFutureRoundDuration
        case .rest:
            return phaseRemaining
                + TimeInterval(max(0, state.config.rounds - state.round)) * state.config.workDuration
                + TimeInterval(max(0, state.config.rounds - state.round - 1)) * state.config.restDuration
        case .idle, .countdown, .complete:
            return 0
        }
    }
}
