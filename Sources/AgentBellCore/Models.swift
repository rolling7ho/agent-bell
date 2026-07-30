import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    public var resumeArguments: [String] {
        switch self {
        case .codex: ["resume"]
        case .claude: ["--resume"]
        }
    }

    public func appDisplayName(origin: OriginMetadata) -> String {
        switch (self, origin.hostBundleIdentifier) {
        case (.codex, "com.openai.codex"):
            origin.hostProcess?.command.contains("/ChatGPT.app/") == true
                ? "ChatGPT Desktop"
                : "Codex Desktop"
        case (.codex, "com.openai.chat"):
            "ChatGPT Desktop"
        case (.codex, "com.microsoft.VSCode"):
            "Codex VS Code"
        case (.codex, _):
            "Codex CLI"
        case (.claude, "com.anthropic.claudefordesktop"):
            "Claude Desktop"
        case (.claude, "com.microsoft.VSCode"):
            "Claude Code VS Code"
        case (.claude, _):
            "Claude Code CLI"
        }
    }
}

public enum DesktopNotificationThresholdPolicy {
    public static func shouldNotify(
        for session: SessionSummary,
        minimumDuration: TimeInterval
    ) -> Bool {
        let threshold = max(0, minimumDuration)
        guard threshold > 0 else { return true }
        guard let elapsedDuration = session.elapsedDuration else {
            return false
        }
        return elapsedDuration >= threshold
    }
}

public enum AgentState: String, Codable, Sendable {
    case started
    case working
    case attention
    case finished
    case failed
    case ended

    public var shouldNotify: Bool {
        switch self {
        case .attention, .finished, .failed: true
        case .started, .working, .ended: false
        }
    }

    public var displayName: String {
        switch self {
        case .started: "Started"
        case .working: "Working"
        case .attention: "Needs attention"
        case .finished: "Finished"
        case .failed: "Failed"
        case .ended: "Ended"
        }
    }
}

public struct ProcessRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var tty: String?
    public var startIdentifier: String
    public var command: String

    public init(
        pid: Int32,
        parentPID: Int32,
        tty: String?,
        startIdentifier: String,
        command: String
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.tty = tty
        self.startIdentifier = startIdentifier
        self.command = command
    }
}

public struct OriginMetadata: Codable, Equatable, Sendable {
    public var agentProcess: ProcessRecord?
    public var shellProcess: ProcessRecord?
    public var hostProcess: ProcessRecord?
    public var hostBundleIdentifier: String?
    public var executablePath: String?
    public var termProgram: String?
    public var cmuxWindowID: String?
    public var cmuxWorkspaceID: String?
    public var cmuxPaneID: String?
    public var cmuxSurfaceID: String?
    public var ghosttyTerminalID: String?

    public init(
        agentProcess: ProcessRecord? = nil,
        shellProcess: ProcessRecord? = nil,
        hostProcess: ProcessRecord? = nil,
        hostBundleIdentifier: String? = nil,
        executablePath: String? = nil,
        termProgram: String? = nil,
        cmuxWindowID: String? = nil,
        cmuxWorkspaceID: String? = nil,
        cmuxPaneID: String? = nil,
        cmuxSurfaceID: String? = nil,
        ghosttyTerminalID: String? = nil
    ) {
        self.agentProcess = agentProcess
        self.shellProcess = shellProcess
        self.hostProcess = hostProcess
        self.hostBundleIdentifier = hostBundleIdentifier
        self.executablePath = executablePath
        self.termProgram = termProgram
        self.cmuxWindowID = cmuxWindowID
        self.cmuxWorkspaceID = cmuxWorkspaceID
        self.cmuxPaneID = cmuxPaneID
        self.cmuxSurfaceID = cmuxSurfaceID
        self.ghosttyTerminalID = ghosttyTerminalID
    }

    public func merging(_ newer: OriginMetadata) -> OriginMetadata {
        OriginMetadata(
            agentProcess: newer.agentProcess ?? agentProcess,
            shellProcess: newer.shellProcess ?? shellProcess,
            hostProcess: newer.hostProcess ?? hostProcess,
            hostBundleIdentifier: newer.hostBundleIdentifier ?? hostBundleIdentifier,
            executablePath: newer.executablePath ?? executablePath,
            termProgram: newer.termProgram ?? termProgram,
            cmuxWindowID: newer.cmuxWindowID ?? cmuxWindowID,
            cmuxWorkspaceID: newer.cmuxWorkspaceID ?? cmuxWorkspaceID,
            cmuxPaneID: newer.cmuxPaneID ?? cmuxPaneID,
            cmuxSurfaceID: newer.cmuxSurfaceID ?? cmuxSurfaceID,
            ghosttyTerminalID: newer.ghosttyTerminalID ?? ghosttyTerminalID
        )
    }
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public var provider: AgentProvider
    public var state: AgentState
    public var hookEventName: String
    public var sessionID: String
    public var turnID: String?
    public var cwd: String
    public var projectName: String
    public var timestamp: Date
    public var notificationType: String?
    public var displayTitle: String?
    public var contentPreview: String?
    public var testDisplayName: String?
    public var origin: OriginMetadata

    public init(
        provider: AgentProvider,
        state: AgentState,
        hookEventName: String,
        sessionID: String,
        turnID: String?,
        cwd: String,
        projectName: String,
        timestamp: Date,
        notificationType: String?,
        displayTitle: String? = nil,
        contentPreview: String? = nil,
        testDisplayName: String? = nil,
        origin: OriginMetadata
    ) {
        self.provider = provider
        self.state = state
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.projectName = projectName
        self.timestamp = timestamp
        self.notificationType = notificationType
        self.displayTitle = displayTitle
        self.contentPreview = contentPreview
        self.testDisplayName = testDisplayName
        self.origin = origin
    }

    public var sessionKey: String {
        "\(provider.rawValue):\(sessionID)"
    }

    public var deduplicationKey: String {
        var components = [
            provider.rawValue,
            sessionID,
            turnID ?? "no-turn",
            hookEventName,
            notificationType ?? "no-notification-type",
        ]
        if state == .attention {
            components.append(contentPreview ?? "no-preview")
        }
        return components.joined(separator: ":")
    }
}

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

public struct FocusRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case focus
        case resume
    }

    public var requestID: String
    public var provider: AgentProvider
    public var sessionID: String
    public var shellPID: Int32?
    public var cwd: String
    public var executablePath: String?
    public var action: Action
    public var createdAt: Date

    public init(
        requestID: String,
        provider: AgentProvider,
        sessionID: String,
        shellPID: Int32?,
        cwd: String,
        executablePath: String?,
        action: Action,
        createdAt: Date = Date()
    ) {
        self.requestID = requestID
        self.provider = provider
        self.sessionID = sessionID
        self.shellPID = shellPID
        self.cwd = cwd
        self.executablePath = executablePath
        self.action = action
        self.createdAt = createdAt
    }
}
