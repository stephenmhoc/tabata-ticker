import ActivityKit
import Foundation

struct TabataLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var title: String
        var roundText: String
        var nextText: String?
        var summaryText: String?
        var isRunning: Bool
        var phaseIconName: String
        var startsAt: Date
        var endsAt: Date
        var pausedAt: Date?
        var workoutEndsAt: Date
        var tintRed: Double
        var tintGreen: Double
        var tintBlue: Double
    }

    var workoutName: String
}

extension TabataLiveActivityAttributes.ContentState {
    // A Live Activity is only redrawn when the app sends new content, so the countdown has to be
    // handed to the system as a range for it to animate on its own between phase changes.
    var timerRange: ClosedRange<Date> {
        startsAt...max(startsAt.addingTimeInterval(1), endsAt)
    }

    // Only used while paused; a running phase gets a progress view driven by the same range.
    var pausedFraction: Double {
        let range = timerRange
        let duration = range.upperBound.timeIntervalSince(range.lowerBound)

        guard duration > 0, let pausedAt else {
            return 0
        }

        return min(1, max(0, pausedAt.timeIntervalSince(range.lowerBound) / duration))
    }
}
