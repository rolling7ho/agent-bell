import XCTest
@testable import TurnringCore

final class AttentionPreviewFormatterTests: XCTestCase {
    func testApprovalPreviewUsesSurfaceToolAndRelativeFile() {
        let cwd = FileManager.default.currentDirectoryPath
        let preview = AttentionPreviewFormatter.preview(
            provider: .codex,
            origin: OriginMetadata(hostBundleIdentifier: "com.openai.codex"),
            eventName: "PermissionRequest",
            toolName: "read_file",
            toolInput: ["file_path": "\(cwd)/README.md"],
            cwd: cwd
        )

        XCTAssertEqual(
            preview,
            "Codex Desktop wants permission to read a file: README.md."
        )
    }

    func testCommandPreviewUsesVSCodeSurfaceAndRedactsSecrets() {
        let preview = AttentionPreviewFormatter.preview(
            provider: .claude,
            origin: OriginMetadata(hostBundleIdentifier: "com.microsoft.VSCode"),
            eventName: "PermissionRequest",
            toolName: "Bash",
            toolInput: [
                "command": "  API_TOKEN=secret\nnpx install ccusage@latest --password hunter2  ",
            ],
            cwd: FileManager.default.currentDirectoryPath
        )

        XCTAssertEqual(
            preview,
            "Claude Code VS Code wants permission to run a command: API_TOKEN=•••• npx install ccusage@latest --password ••••."
        )
        XCTAssertFalse(preview?.contains("secret") == true)
        XCTAssertFalse(preview?.contains("hunter2") == true)
    }

    func testQuestionPreviewContainsOnlyFirstQuestion() {
        let preview = AttentionPreviewFormatter.preview(
            provider: .claude,
            origin: OriginMetadata(),
            eventName: "PreToolUse",
            toolName: "AskUserQuestion",
            toolInput: [
                "questions": [
                    [
                        "question": "  Does this\nwork? ",
                        "options": [["label": "Sensitive choice"]],
                    ],
                    ["question": "Second question"],
                ],
                "answers": ["Does this work?": "Sensitive answer"],
            ],
            cwd: FileManager.default.currentDirectoryPath
        )

        XCTAssertEqual(
            preview,
            "Claude Code CLI has 2 questions. First: Does this work?"
        )
        XCTAssertFalse(preview?.contains("Sensitive") == true)
        XCTAssertFalse(preview?.contains("Second") == true)
    }

    func testExitPlanModeUsesGenericReviewActionWithoutPlanContent() {
        let preview = AttentionPreviewFormatter.preview(
            provider: .claude,
            origin: OriginMetadata(),
            eventName: "PreToolUse",
            toolName: "ExitPlanMode",
            toolInput: ["plan": "NEVER_STORE_PLAN"],
            cwd: FileManager.default.currentDirectoryPath
        )

        XCTAssertEqual(
            preview,
            "Claude Code CLI wants you to review its plan and choose Approve or Reject."
        )
        XCTAssertFalse(preview?.contains("NEVER_STORE_PLAN") == true)
    }

    func testMCPAndSearchToolNamesAreNormalized() {
        let cwd = FileManager.default.currentDirectoryPath
        XCTAssertEqual(
            AttentionPreviewFormatter.preview(
                provider: .codex,
                origin: OriginMetadata(),
                eventName: "PermissionRequest",
                toolName: "mcp__filesystem__read_file",
                toolInput: ["path": "\(cwd)/Sources/App.swift"],
                cwd: cwd
            ),
            "Codex CLI wants permission to read a file: Sources/App.swift."
        )
        XCTAssertEqual(
            AttentionPreviewFormatter.preview(
                provider: .claude,
                origin: OriginMetadata(),
                eventName: "PermissionRequest",
                toolName: "Grep",
                toolInput: ["pattern": "Needs attention", "path": "\(cwd)/Sources"],
                cwd: cwd
            ),
            "Claude Code CLI wants permission to search text: Needs attention in Sources."
        )
    }

    func testUnknownToolDoesNotSerializeUnrelatedInput() {
        let preview = AttentionPreviewFormatter.preview(
            provider: .codex,
            origin: OriginMetadata(),
            eventName: "PermissionRequest",
            toolName: "CustomMagicTool",
            toolInput: ["content": "NEVER_STORE_CONTENT"],
            cwd: FileManager.default.currentDirectoryPath
        )

        XCTAssertEqual(
            preview,
            "Codex CLI wants permission to use Custom Magic Tool."
        )
        XCTAssertFalse(preview?.contains("NEVER_STORE_CONTENT") == true)
    }

    func testQuestionsAndURLsRedactCommonCredentialShapes() {
        let cwd = FileManager.default.currentDirectoryPath
        let question = AttentionPreviewFormatter.preview(
            provider: .claude,
            origin: OriginMetadata(),
            eventName: "PreToolUse",
            toolName: "AskUserQuestion",
            toolInput: [
                "questions": [[
                    "question": "Use token=secret-value and sk-abcdefghijklmnopqrstuvwxyz?",
                    "options": [["label": "Do not retain"]],
                ]],
            ],
            cwd: cwd
        )
        let url = AttentionPreviewFormatter.preview(
            provider: .codex,
            origin: OriginMetadata(),
            eventName: "PermissionRequest",
            toolName: "WebFetch",
            toolInput: [
                "url": "https://user:password@example.com/path?access_token=secret-value",
            ],
            cwd: cwd
        )

        XCTAssertFalse(try XCTUnwrap(question).contains("secret-value"))
        XCTAssertFalse(try XCTUnwrap(question).contains("sk-abcdefgh"))
        XCTAssertFalse(try XCTUnwrap(url).contains("password"))
        XCTAssertFalse(try XCTUnwrap(url).contains("secret-value"))
        XCTAssertTrue(try XCTUnwrap(url).contains("••••"))
    }

    func testOutsideProjectPathUsesOnlyBasename() {
        let preview = AttentionPreviewFormatter.preview(
            provider: .claude,
            origin: OriginMetadata(),
            eventName: "PermissionRequest",
            toolName: "Write",
            toolInput: ["file_path": "/Users/person/private/secrets.txt"],
            cwd: FileManager.default.currentDirectoryPath
        )

        XCTAssertEqual(
            preview,
            "Claude Code CLI wants permission to write to a file: secrets.txt."
        )
    }

    func testPreviewIsUnicodeSafeAndAtMostOneHundredTwentyCharacters() {
        let preview = AttentionPreviewFormatter.preview(
            provider: .codex,
            origin: OriginMetadata(),
            eventName: "PermissionRequest",
            toolName: "Bash",
            toolInput: ["command": String(repeating: "🛠️", count: 100)],
            cwd: FileManager.default.currentDirectoryPath
        )

        XCTAssertEqual(preview?.count, AttentionPreviewFormatter.maximumCharacters)
        XCTAssertEqual(preview?.last, "…")
    }

    func testEverySupportedSurfaceHasExpectedName() {
        XCTAssertEqual(
            AgentProvider.codex.appDisplayName(
                origin: OriginMetadata(hostBundleIdentifier: "com.openai.codex")
            ),
            "Codex Desktop"
        )
        XCTAssertEqual(
            AgentProvider.codex.appDisplayName(
                origin: OriginMetadata(hostBundleIdentifier: "com.microsoft.VSCode")
            ),
            "Codex VS Code"
        )
        XCTAssertEqual(AgentProvider.codex.appDisplayName(origin: OriginMetadata()), "Codex CLI")
        XCTAssertEqual(
            AgentProvider.claude.appDisplayName(
                origin: OriginMetadata(hostBundleIdentifier: "com.microsoft.VSCode")
            ),
            "Claude Code VS Code"
        )
        XCTAssertEqual(
            AgentProvider.claude.appDisplayName(origin: OriginMetadata()),
            "Claude Code CLI"
        )
    }
}
