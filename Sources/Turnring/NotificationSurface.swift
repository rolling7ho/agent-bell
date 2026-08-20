import TurnringCore
import Foundation

enum NotificationSurface: String, CaseIterable {
    case chatGPTDesktop
    case codexDesktop
    case codexCLI
    case codexVSCode
    case claudeDesktop
    case claudeCLI
    case claudeVSCode

    static var supportedCases: [NotificationSurface] {
        allCases.filter(\.isSupported)
    }

    var isSupported: Bool {
        executionSurface.supportsNotifications
    }

    var displayName: String {
        executionSurface.displayName
    }

    private var executionSurface: AgentExecutionSurface {
        switch self {
        case .chatGPTDesktop: .chatGPTDesktop
        case .codexDesktop: .codexDesktop
        case .codexCLI: .codexCLI
        case .codexVSCode: .codexVSCode
        case .claudeDesktop: .claudeDesktop
        case .claudeCLI: .claudeCLI
        case .claudeVSCode: .claudeVSCode
        }
    }

    var provider: AgentProvider {
        switch self {
        case .chatGPTDesktop, .codexDesktop, .codexCLI, .codexVSCode:
            .codex
        case .claudeDesktop, .claudeCLI, .claudeVSCode:
            .claude
        }
    }

    var hostBundleIdentifier: String? {
        switch self {
        case .chatGPTDesktop:
            "com.openai.chat"
        case .codexDesktop:
            "com.openai.codex"
        case .claudeDesktop:
            "com.anthropic.claudefordesktop"
        case .codexVSCode, .claudeVSCode:
            "com.microsoft.VSCode"
        case .codexCLI, .claudeCLI:
            nil
        }
    }

    init(session: SessionSummary) {
        switch AgentExecutionSurface(
            provider: session.provider,
            origin: session.origin
        ) {
        case .chatGPTDesktop: self = .chatGPTDesktop
        case .codexDesktop: self = .codexDesktop
        case .codexCLI: self = .codexCLI
        case .codexVSCode: self = .codexVSCode
        case .claudeDesktop: self = .claudeDesktop
        case .claudeCLI: self = .claudeCLI
        case .claudeVSCode: self = .claudeVSCode
        }
    }
}
