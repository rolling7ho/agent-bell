import Foundation

enum SessionTransitionPolicy {
    static func isActive(_ summary: SessionSummary) -> Bool {
        switch summary.state {
        case .started, .working, .attention:
            true
        case .finished, .failed, .ended:
            false
        }
    }

    static func shouldApply(
        _ event: AgentEvent,
        to existing: SessionSummary
    ) -> Bool {
        let turnsConflict = event.turnID != nil
            && existing.turnID != nil
            && event.turnID != existing.turnID

        switch event.hookEventName {
        case "SessionStart":
            return !isActive(existing)
        case "UserPromptSubmit":
            if turnsConflict {
                return true
            }
            return existing.state != .ended
                || event.timestamp > existing.updatedAt
        case "Notification" where event.state == .finished:
            guard existing.state != .ended else { return false }
            return !turnsConflict
        case "PermissionRequest", "PreToolUse", "Notification":
            guard isActive(existing) else { return false }
            return !turnsConflict
        case "Stop", "StopFailure":
            guard existing.state != .ended else { return false }
            return !turnsConflict
        case "SessionEnd":
            guard !turnsConflict else { return false }
            if event.turnID == nil && event.timestamp < existing.updatedAt {
                return false
            }
            return true
        default:
            return event.timestamp >= existing.updatedAt
        }
    }

    static func inheritedRunStart<S: Sequence>(
        for event: AgentEvent,
        sessions: S
    ) -> Date? where S.Element == SessionSummary {
        guard event.state == .finished || event.state == .failed,
              let process = event.origin.agentProcess
        else {
            return nil
        }
        return sessions
            .filter { summary in
                guard summary.provider == event.provider,
                      isActive(summary),
                      let candidate = summary.origin.agentProcess
                else {
                    return false
                }
                return candidate.pid == process.pid
                    && candidate.startIdentifier == process.startIdentifier
                    && summary.updatedAt <= event.timestamp
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?
            .runStartedAt
    }
}
