// When a live folder refreshes (docs/bookmarks.md, Live folders ▸ Refreshing; live folder rule 6), as a pure function of the folder's state, its configuration, the trigger, the moment, and Low Power Mode, so tests drive every rule without timers.
import Foundation

public enum LiveFolderTrigger: Sendable {
    case refreshNow
    /// The check every 5 minutes.
    case timer
    /// Arch became active, or a window showed the folder's space.
    case activation
}

public enum LiveFolderSchedule {
    /// How often the service checks for due folders.
    public static let checkInterval: TimeInterval = 5 * 60
    /// The least time between a GitHub folder's attempts that activation starts.
    public static let activationGap: TimeInterval = 5 * 60
    /// The longest interval a feed's own interval gives.
    public static let longestFeedInterval: TimeInterval = 24 * 3_600
    /// The longest wait that failures give.
    public static let longestBackoff: TimeInterval = 6 * 3_600

    /// Whether `trigger` refreshes the folder at `now`. Refresh Now always does; the timer does once the next attempt is due; activation does for a GitHub folder whose next attempt is due, or, while it has not failed, once the activation gap has passed since its last attempt and any time the source named.
    public static func shouldRefresh(_ trigger: LiveFolderTrigger, configuration: LiveFolderConfiguration, state: LiveFolderState, now: Date, lowPowerMode: Bool) -> Bool {
        let due = nextAttempt(configuration: configuration, state: state, lowPowerMode: lowPowerMode)
        switch trigger {
        case .refreshNow:
            return true
        case .timer:
            return now >= due
        case .activation:
            guard configuration.source.isGitHub else { return false }
            if now >= due { return true }
            guard state.failureCount == 0, let last = state.lastAttempt else { return false }
            let gap = activationGap * (lowPowerMode ? 2 : 1)
            return now >= max(last.addingTimeInterval(gap), state.earliestNextAttempt ?? .distantPast)
        }
    }

    /// When the timer next refreshes the folder: at once before its first attempt, else its wait after the last attempt, and not before the time the source named.
    public static func nextAttempt(configuration: LiveFolderConfiguration, state: LiveFolderState, lowPowerMode: Bool) -> Date {
        guard let last = state.lastAttempt else { return .distantPast }
        let next = last.addingTimeInterval(wait(configuration: configuration, state: state, lowPowerMode: lowPowerMode))
        return max(next, state.earliestNextAttempt ?? .distantPast)
    }

    /// The wait after an attempt: the interval, which a feed's own interval lengthens up to 24 hours; doubled for each failure in a row up to 6 hours, though never below the interval; and doubled again in Low Power Mode.
    public static func wait(configuration: LiveFolderConfiguration, state: LiveFolderState, lowPowerMode: Bool) -> TimeInterval {
        var interval = configuration.refreshInterval
        if !configuration.source.isGitHub, let feedInterval = state.feedInterval {
            interval = max(interval, min(feedInterval, longestFeedInterval))
        }
        if state.failureCount > 0 {
            let doubled = interval * pow(2, Double(min(state.failureCount, 16)))
            interval = max(interval, min(doubled, longestBackoff))
        }
        return lowPowerMode ? interval * 2 : interval
    }
}
