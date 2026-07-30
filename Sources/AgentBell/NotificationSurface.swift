import AgentBellCore
import Foundation

enum NotificationSurface: String, CaseIterable {
    case chatGPTDesktop
    case codexDesktop
    case codexCLI
    case codexVSCode
    case claudeDesktop
    case claudeCLI
    case claudeVSCode

    var displayName: String {
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
            "com.openai.codex"
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
        switch (session.provider, session.origin.hostBundleIdentifier) {
        case (.codex, "com.openai.chat"):
            self = .chatGPTDesktop
        case (.codex, "com.openai.codex")
            where session.appDisplayName == "ChatGPT Desktop":
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
}
