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
        AgentExecutionSurface(provider: self, origin: origin).displayName
    }
}

public enum AgentExecutionSurface: String, CaseIterable, Sendable {
    case chatGPTDesktop
    case codexDesktop
    case codexCLI
    case codexVSCode
    case claudeDesktop
    case claudeCLI
    case claudeVSCode

    public init(provider: AgentProvider, origin: OriginMetadata) {
        let host = ProcessInspector.canonicalHostBundleIdentifier(
            origin.hostBundleIdentifier
        )
        switch (provider, host) {
        case (.codex, "com.openai.chat"):
            self = .chatGPTDesktop
        case (.codex, "com.openai.codex"):
            self = .codexDesktop
        case (.codex, "com.microsoft.VSCode"):
            self = .codexVSCode
        case (.codex, _):
            self = .codexCLI
        case (.claude, "com.anthropic.claudefordesktop"):
            self = .claudeDesktop
        case (.claude, "com.microsoft.VSCode"):
            self = .claudeVSCode
        case (.claude, _):
            self = .claudeCLI
        }
    }

    public var displayName: String {
        switch self {
        case .chatGPTDesktop: "ChatGPT Desktop"
        case .codexDesktop: "Codex Desktop"
        case .codexCLI: "Codex CLI"
        case .codexVSCode: "Codex VS Code"
        case .claudeDesktop: "Claude Desktop"
        case .claudeCLI: "Claude Code CLI"
        case .claudeVSCode: "Claude Code VS Code"
        }
    }

    public var supportsNotifications: Bool {
        switch self {
        case .chatGPTDesktop, .claudeDesktop:
            false
        case .codexDesktop, .codexCLI, .codexVSCode, .claudeCLI,
             .claudeVSCode:
            true
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
