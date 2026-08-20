import Darwin
import XCTest
@testable import TurnringCore

final class ProcessInspectorTests: XCTestCase {
    func testCurrentProcessBirthIdentityIsAcceptedAndModifiedIdentityIsRejected() throws {
        let current = try XCTUnwrap(ProcessInspector.processRecord(pid: getpid()))
        XCTAssertTrue(ProcessInspector.isAlive(current))

        var reused = current
        reused.startIdentifier = "Mon Jan  1 00:00:00 1990"
        XCTAssertFalse(ProcessInspector.isAlive(reused))
    }

    func testKnownHostIdentification() {
        XCTAssertEqual(
            ProcessInspector.bundleIdentifier(
                for: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
            ),
            "com.microsoft.VSCode"
        )
        XCTAssertEqual(
            ProcessInspector.bundleIdentifier(
                for: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
            ),
            "com.apple.Terminal"
        )
        XCTAssertEqual(
            ProcessInspector.bundleIdentifier(
                for: "/Applications/Codex.app/Contents/MacOS/Codex"
            ),
            "com.openai.codex"
        )
        XCTAssertEqual(
            ProcessInspector.bundleIdentifier(
                for: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
            ),
            "com.openai.codex"
        )
        XCTAssertEqual(
            ProcessInspector.bundleIdentifier(
                for: "/Applications/ChatGPT Classic.app/Contents/MacOS/ChatGPT"
            ),
            "com.openai.chat"
        )
        XCTAssertEqual(
            ProcessInspector.bundleIdentifier(
                for: "/Applications/Claude.app/Contents/MacOS/Claude"
            ),
            "com.anthropic.claudefordesktop"
        )
        XCTAssertEqual(
            ProcessInspector.bundleIdentifier(
                for: "/APPLICATIONS/VISUAL STUDIO CODE - INSIDERS.APP/Contents/MacOS/Electron"
            ),
            "com.microsoft.VSCode"
        )
        XCTAssertEqual(
            ProcessInspector.bundleIdentifier(
                for: "/applications/CODEX.app/Contents/Resources/codex"
            ),
            "com.openai.codex"
        )
    }

    func testCanonicalHostBundleIdentifiersIncludeHelperAndInsiderVariants() {
        XCTAssertEqual(
            ProcessInspector.canonicalHostBundleIdentifier(
                "com.openai.codex.helper.GPU"
            ),
            "com.openai.codex"
        )
        XCTAssertEqual(
            ProcessInspector.canonicalHostBundleIdentifier(
                "com.microsoft.VSCodeInsiders.helper"
            ),
            "com.microsoft.VSCode"
        )
        XCTAssertEqual(
            ProcessInspector.canonicalHostBundleIdentifier(
                "com.anthropic.claudefordesktop.helper"
            ),
            "com.anthropic.claudefordesktop"
        )
        XCTAssertNil(
            ProcessInspector.canonicalHostBundleIdentifier(
                "com.example.lookalike"
            )
        )
    }

    func testSafeResumeArgumentsRejectShellSyntaxAndKeepArgumentsSeparate() {
        XCTAssertNil(
            TurnringValidation.resumeArguments(
                provider: .codex,
                sessionID: "thread; open -a Calculator"
            )
        )
        XCTAssertEqual(
            TurnringValidation.resumeArguments(
                provider: .claude,
                sessionID: "session-123"
            ),
            ["--resume", "session-123"]
        )
    }

    func testTimedOutChildProcessIsForceTerminatedWithoutHanging() {
        let started = Date()
        let result = ProcessInspector.run(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.01
        )

        XCTAssertEqual(result.status, -2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testOutputProducingChildCannotDeadlockTimeout() {
        let started = Date()
        let result = ProcessInspector.run(
            executable: "/usr/bin/yes",
            arguments: [],
            timeout: 0.03
        )

        XCTAssertEqual(result.status, -2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testSuccessfulCommandOutputIsBounded() {
        let result = ProcessInspector.run(
            executable: "/usr/bin/jot",
            arguments: ["-b", "1234567890", "110000"],
            timeout: 3
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertLessThanOrEqual(result.output.utf8.count, 1 * 1_024 * 1_024)
    }

    func testOriginEnvironmentRejectsUnsafeIdentifiers() {
        let origin = ProcessInspector.captureOrigin(
            provider: .codex,
            environment: [
                "TERM_PROGRAM": "vscode",
                "CMUX_WINDOW_ID": "safe-window",
                "CMUX_PANE_ID": "bad;command",
            ],
            startingPID: 1
        )

        XCTAssertEqual(origin.hostBundleIdentifier, "com.microsoft.VSCode")
        XCTAssertEqual(origin.cmuxWindowID, "safe-window")
        XCTAssertNil(origin.cmuxPaneID)
    }
}
