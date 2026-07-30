import Foundation

public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String { sessionKey }
    public var sessionKey: String
    public var provider: AgentProvider
    public var sessionID: String
    public var state: AgentState
    public var cwd: String
    public var projectName: String
    public var updatedAt: Date
    public var runStartedAt: Date?
    public var observedActivityAt: Date?
    public var displayTitle: String?
    public var contentPreview: String?
    public var testDisplayName: String?
    public var origin: OriginMetadata
    public var turnID: String?
    public var lastHookEventName: String?

    public init(event: AgentEvent) {
        sessionKey = event.sessionKey
        provider = event.provider
        sessionID = event.sessionID
        state = event.state
        cwd = event.cwd
        projectName = event.projectName
        updatedAt = event.timestamp
        runStartedAt = event.state == .finished
            || event.state == .failed
            || event.state == .ended
            ? nil
            : event.timestamp
        observedActivityAt = event.isMeaningfulActivity
            ? event.timestamp
            : nil
        displayTitle = event.displayTitle
        contentPreview = event.contentPreview
        testDisplayName = event.testDisplayName
        origin = event.origin
        turnID = event.turnID
        lastHookEventName = event.hookEventName
    }

    public mutating func apply(
        _ event: AgentEvent,
        effectiveTimestamp: Date? = nil
    ) {
        let previousState = state
        let previousTurnID = turnID
        let appliedTimestamp = effectiveTimestamp ?? event.timestamp
        if event.hookEventName == "UserPromptSubmit",
           previousState == .started
                || previousState == .finished
                || previousState == .failed
                || previousState == .ended
                || previousTurnID != event.turnID
        {
            runStartedAt = event.timestamp
        } else if runStartedAt == nil,
                  event.isMeaningfulActivity,
                  event.state == .started
                    || event.state == .working
                    || event.state == .attention
        {
            runStartedAt = event.timestamp
        }
        if event.isMeaningfulActivity {
            observedActivityAt = appliedTimestamp
        }
        state = event.state
        cwd = event.cwd
        projectName = event.projectName
        updatedAt = appliedTimestamp
        if let displayTitle = event.displayTitle {
            self.displayTitle = displayTitle
        }
        contentPreview = event.contentPreview
        if let testDisplayName = event.testDisplayName {
            self.testDisplayName = testDisplayName
        }
        origin = origin.merging(event.origin)
        if let turnID = event.turnID {
            self.turnID = turnID
        }
        lastHookEventName = event.hookEventName
    }

    public var appDisplayName: String {
        testDisplayName ?? provider.appDisplayName(origin: origin)
    }

    public var isTest: Bool { testDisplayName != nil }

    public var formattedTitle: String {
        let safeTitle = AgentBellSafeText.redacted(
            displayTitle ?? "Untitled task"
        )
        let base = "\(appDisplayName) • \(safeTitle)"
        guard state == .finished,
              let formattedElapsedDuration
        else {
            return base
        }
        return "\(base) (\(formattedElapsedDuration))"
    }

    public var elapsedDuration: TimeInterval? {
        guard let runStartedAt else { return nil }
        return max(0, updatedAt.timeIntervalSince(runStartedAt))
    }

    public var formattedElapsedDuration: String? {
        guard let elapsedDuration else { return nil }
        let totalSeconds = max(0, Int(elapsedDuration.rounded(.down)))
        if elapsedDuration > 0, totalSeconds == 0 {
            return "<1s"
        }
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    public var dashboardStateName: String {
        guard state == .finished,
              let formattedElapsedDuration
        else {
            return state.displayName
        }
        return "\(state.displayName) (\(formattedElapsedDuration))"
    }

    public var notificationBody: String? {
        switch state {
        case .attention:
            contentPreview ?? "Needs your attention."
        case .finished:
            contentPreview ?? "Task finished."
        case .failed:
            contentPreview ?? "Task stopped unexpectedly."
        case .started, .working, .ended:
            nil
        }
    }

    public var genericNotificationTitle: String {
        var value = "\(appDisplayName) • \(state.displayName)"
        if state == .finished,
           let formattedElapsedDuration
        {
            value += " (\(formattedElapsedDuration))"
        }
        return value
    }

    public var genericNotificationBody: String? {
        switch state {
        case .attention:
            "Needs your attention."
        case .finished:
            "Task finished."
        case .failed:
            "Task stopped unexpectedly."
        case .started, .working, .ended:
            nil
        }
    }

    public func dashboardTitle(includesPrivateDetails: Bool) -> String {
        includesPrivateDetails || isTest
            ? formattedTitle
            : genericNotificationTitle
    }

    public func dashboardPreview(
        includesPrivateDetails: Bool,
        maximumCharacters: Int
    ) -> String {
        if includesPrivateDetails || isTest,
           let contentPreview,
           !contentPreview.isEmpty
        {
            return AgentBellSafeText.collapsed(
                contentPreview,
                maximumCharacters: max(
                    10,
                    min(
                        AttentionPreviewFormatter.maximumCharacters,
                        maximumCharacters
                    )
                ),
                appendEllipsisWhenTruncated: true
            )
        }
        return switch state {
        case .started:
            "Session started."
        case .working:
            "Task is running."
        case .attention:
            "Needs your attention."
        case .finished:
            "Task finished."
        case .failed:
            "Task stopped unexpectedly."
        case .ended:
            "Session ended."
        }
    }
}

public enum SessionPresentation {
    public static func rows(
        from sessions: [SessionSummary],
        limit: Int = SessionStore.maximumSessions
    ) -> [SessionSummary] {
        var newestByInstance: [String: SessionSummary] = [:]
        for session in sessions where session.isTest || session.observedActivityAt != nil {
            let key = instanceKey(for: session)
            if let existing = newestByInstance[key],
               existing.updatedAt >= session.updatedAt
            {
                continue
            }
            newestByInstance[key] = session
        }

        return Array(
            newestByInstance.values.sorted(by: dashboardOrder).prefix(max(0, limit))
        )
    }

    public static func representsSameInstance(
        _ lhs: SessionSummary,
        _ rhs: SessionSummary
    ) -> Bool {
        instanceKey(for: lhs) == instanceKey(for: rhs)
    }

    private static func instanceKey(for session: SessionSummary) -> String {
        guard let process = session.origin.agentProcess else {
            return session.sessionKey
        }
        return [
            session.provider.rawValue,
            String(process.pid),
            process.startIdentifier,
        ].joined(separator: ":")
    }

    private static func dashboardOrder(
        _ lhs: SessionSummary,
        _ rhs: SessionSummary
    ) -> Bool {
        if lhs.state == .attention && rhs.state != .attention { return true }
        if rhs.state == .attention && lhs.state != .attention { return false }
        if lhs.state == .working && rhs.state != .working { return true }
        if rhs.state == .working && lhs.state != .working { return false }
        return lhs.updatedAt > rhs.updatedAt
    }
}

private extension AgentEvent {
    var isMeaningfulActivity: Bool {
        hookEventName != "SessionStart" && hookEventName != "SessionEnd"
    }
}
