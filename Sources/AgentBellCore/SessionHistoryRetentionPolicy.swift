import Foundation

public enum SessionHistoryRetentionPolicy {
    public static let defaultRetention: TimeInterval = 30 * 60
    public static let minimumRetention: TimeInterval = 60
    public static let maximumRetention: TimeInterval = 7 * 24 * 60 * 60

    public static func clampedRetention(
        _ value: TimeInterval
    ) -> TimeInterval {
        min(maximumRetention, max(minimumRetention, value))
    }

    public static func expiredSessions(
        from sessions: [SessionSummary],
        at date: Date = Date(),
        retention: TimeInterval
    ) -> [SessionSummary] {
        let interval = clampedRetention(retention)
        return sessions.filter { session in
            guard isEligibleForAutomaticRemoval(session) else {
                return false
            }
            return date.timeIntervalSince(session.updatedAt) >= interval
        }
    }

    private static func isEligibleForAutomaticRemoval(
        _ session: SessionSummary
    ) -> Bool {
        if session.isTest {
            return true
        }
        return switch session.state {
        case .finished, .failed, .ended:
            true
        case .started, .working, .attention:
            false
        }
    }
}
