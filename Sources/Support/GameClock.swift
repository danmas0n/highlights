import Foundation

/// The clock a parent actually wants on the sideline: what time it is, how far into the half we
/// are, and when the half started. Not how long the app has been watching — that number was on
/// the screen for weeks and never once mattered.
///
/// Deliberately independent of the eye. You close the eye when your kid subs off, but the half
/// keeps running; tying the two together would make the clock lie the moment it was most needed.
/// It starts itself the first time the eye opens, so there's nothing to remember at kickoff, and
/// runs until you start the next half or reset it.
@MainActor
@Observable
final class GameClock {
    private(set) var period: Int
    private(set) var periodStartedAt: Date?

    private let defaults = UserDefaults.standard

    init() {
        period = max(defaults.integer(forKey: "gameclock.period"), 1)
        periodStartedAt = defaults.object(forKey: "gameclock.startedAt") as? Date
        // A half doesn't last four hours. Anything that old is yesterday's game.
        if let start = periodStartedAt, Date().timeIntervalSince(start) > 4 * 3600 {
            reset()
        }
    }

    var isRunning: Bool { periodStartedAt != nil }

    var elapsed: TimeInterval {
        periodStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// Begins the next period, or the first if none has run.
    func startNextPeriod() {
        period = isRunning ? period + 1 : max(period, 1)
        periodStartedAt = Date()
        persist()
    }

    /// Starts period 1 only if nothing is running — the automatic kickoff hook.
    func startIfIdle() {
        guard !isRunning else { return }
        period = 1
        periodStartedAt = Date()
        persist()
    }

    func reset() {
        period = 1
        periodStartedAt = nil
        persist()
    }

    var periodLabel: String {
        let suffix: String
        switch period {
        case 1: suffix = "st"
        case 2: suffix = "nd"
        case 3: suffix = "rd"
        default: suffix = "th"
        }
        return "\(period)\(suffix) half"
    }

    private func persist() {
        defaults.set(period, forKey: "gameclock.period")
        defaults.set(periodStartedAt, forKey: "gameclock.startedAt")
    }
}
