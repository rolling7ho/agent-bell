import XCTest
@testable import TurnringCore

final class AgentExecutionSurfaceTests: XCTestCase {
    func testEveryKnownSurfaceUsesOneClassificationPolicy() {
        let cases: [(
            AgentProvider,
            String?,
            AgentExecutionSurface,
            String,
            Bool
        )] = [
            (.codex, "com.openai.codex", .codexDesktop, "Codex Desktop", true),
            (.codex, "com.openai.codex.helper", .codexDesktop, "Codex Desktop", true),
            (.codex, "com.openai.chat", .chatGPTDesktop, "ChatGPT Desktop", false),
            (.codex, "com.microsoft.VSCode", .codexVSCode, "Codex VS Code", true),
            (.codex, "com.microsoft.VSCodeInsiders", .codexVSCode, "Codex VS Code", true),
            (.codex, "com.apple.Terminal", .codexCLI, "Codex CLI", true),
            (.codex, nil, .codexCLI, "Codex CLI", true),
            (.claude, "com.anthropic.claudefordesktop", .claudeDesktop, "Claude Desktop", false),
            (.claude, "com.microsoft.VSCode.helper", .claudeVSCode, "Claude Code VS Code", true),
            (.claude, "com.mitchellh.ghostty", .claudeCLI, "Claude Code CLI", true),
            (.claude, nil, .claudeCLI, "Claude Code CLI", true),
        ]

        for (provider, bundleID, expected, name, isSupported) in cases {
            let origin = OriginMetadata(hostBundleIdentifier: bundleID)
            let surface = AgentExecutionSurface(
                provider: provider,
                origin: origin
            )
            XCTAssertEqual(surface, expected, bundleID ?? "nil")
            XCTAssertEqual(surface.displayName, name, bundleID ?? "nil")
            XCTAssertEqual(
                surface.supportsNotifications,
                isSupported,
                bundleID ?? "nil"
            )
            XCTAssertEqual(
                provider.appDisplayName(origin: origin),
                name,
                bundleID ?? "nil"
            )
        }
    }
}
