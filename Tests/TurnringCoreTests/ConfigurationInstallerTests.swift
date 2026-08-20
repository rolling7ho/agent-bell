import XCTest
@testable import TurnringCore

final class ConfigurationInstallerTests: XCTestCase {
    func testMergePreservesUnrelatedHooksAndNotifyAndIsIdempotent() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("hooks.json")
        let hookExecutable = try makeExecutable(in: directory)
        let original: [String: Any] = [
            "notify": ["/usr/local/bin/computer-use-notify"],
            "unrelated": "preserve-me",
            "hooks": [
                "Stop": [[
                    "hooks": [[
                        "type": "command",
                        "command": "/usr/bin/true",
                    ]],
                ]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settingsURL)

        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil
        )
        XCTAssertNotNil(try installer.mergeHooks(at: settingsURL, provider: .codex))
        XCTAssertNil(try installer.mergeHooks(at: settingsURL, provider: .codex))

        let merged = try json(at: settingsURL)
        XCTAssertEqual(merged["notify"] as? [String], ["/usr/local/bin/computer-use-notify"])
        XCTAssertEqual(merged["unrelated"] as? String, "preserve-me")
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        let stopGroups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopGroups.count, 2)
        let preToolUseGroups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUseGroups.count, 1)
        XCTAssertEqual(preToolUseGroups[0]["matcher"] as? String, "^request_user_input$")
        XCTAssertTrue(installer.containsOwnedHook(at: settingsURL))
    }

    func testUninstallRemovesOnlyOwnedEntries() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let hookExecutable = try makeExecutable(in: directory)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil
        )
        _ = try installer.mergeHooks(at: settingsURL, provider: .claude)

        var root = try json(at: settingsURL)
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        hooks["PostToolUse"] = [[
            "matcher": "Bash",
            "hooks": [["type": "command", "command": "/usr/bin/true"]],
        ]]
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: settingsURL)

        try installer.removeOwnedHooks(at: settingsURL)
        let cleaned = try json(at: settingsURL)
        let cleanedHooks = try XCTUnwrap(cleaned["hooks"] as? [String: Any])
        XCTAssertNil(cleanedHooks["Stop"])
        XCTAssertNotNil(cleanedHooks["PostToolUse"])
        XCTAssertFalse(installer.containsOwnedHook(at: settingsURL))
    }

    func testInvalidJSONIsNotChanged() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let hookExecutable = try makeExecutable(in: directory)
        let invalid = Data("{not-valid-json".utf8)
        try invalid.write(to: settingsURL)

        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil
        )
        XCTAssertThrowsError(try installer.mergeHooks(at: settingsURL, provider: .claude))
        XCTAssertEqual(try Data(contentsOf: settingsURL), invalid)
    }

    func testOversizedConfigurationIsRejectedWithoutBeingChanged() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let hookExecutable = try makeExecutable(in: directory)
        let oversized = Data(repeating: 0x20, count: 8 * 1_024 * 1_024 + 1)
        try oversized.write(to: settingsURL)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil
        )

        XCTAssertThrowsError(
            try installer.mergeHooks(at: settingsURL, provider: .claude)
        )
        XCTAssertEqual(try Data(contentsOf: settingsURL), oversized)
    }

    func testHookPathIsShellQuotedWithoutCommandInjection() throws {
        let directory = temporaryDirectory()
            .appendingPathComponent("Turnring's Files")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let settingsURL = directory.appendingPathComponent("settings.json")
        let hookExecutable = try makeExecutable(in: directory)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil
        )

        _ = try installer.mergeHooks(at: settingsURL, provider: .codex)

        XCTAssertTrue(
            installer.missingHookEvents(
                at: settingsURL,
                provider: .codex
            ).isEmpty
        )
        let root = try json(at: settingsURL)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let handlers = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        let command = try XCTUnwrap(handlers[0]["command"] as? String)
        XCTAssertTrue(command.contains("'\"'\"'"))
        XCTAssertTrue(command.hasSuffix(" --provider codex"))
    }

    func testHealthRequiresEveryExactProviderHook() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("hooks.json")
        let hookExecutable = try makeExecutable(in: directory)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil
        )
        _ = try installer.mergeHooks(at: settingsURL, provider: .codex)
        XCTAssertTrue(
            installer.missingHookEvents(at: settingsURL, provider: .codex).isEmpty
        )

        var root = try json(at: settingsURL)
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "PermissionRequest")
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: settingsURL)

        XCTAssertEqual(
            installer.missingHookEvents(at: settingsURL, provider: .codex),
            ["PermissionRequest"]
        )
    }

    func testHealthRequiresExactRequestUserInputMatcher() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("hooks.json")
        let hookExecutable = try makeExecutable(in: directory)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil
        )
        _ = try installer.mergeHooks(at: settingsURL, provider: .codex)

        var root = try json(at: settingsURL)
        var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        var groups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        groups[0]["matcher"] = "^Bash$"
        hooks["PreToolUse"] = groups
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: settingsURL)

        XCTAssertEqual(
            installer.missingHookEvents(at: settingsURL, provider: .codex),
            ["PreToolUse"]
        )
    }

    func testClaudeUsesDetailedPermissionAndInteractiveToolHooksWithoutGenericPermissionNotification()
        throws
    {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let hookExecutable = try makeExecutable(in: directory)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil
        )

        _ = try installer.mergeHooks(at: settingsURL, provider: .claude)
        let hooks = try XCTUnwrap(
            try json(at: settingsURL)["hooks"] as? [String: Any]
        )
        let permissionGroups = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertNil(permissionGroups[0]["matcher"])

        let preToolGroups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(
            preToolGroups[0]["matcher"] as? String,
            "^(AskUserQuestion|ExitPlanMode)$"
        )

        let notificationGroups = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let matcher = try XCTUnwrap(notificationGroups[0]["matcher"] as? String)
        XCTAssertFalse(matcher.contains("permission_prompt"))
        XCTAssertTrue(matcher.contains("idle_prompt"))
    }

    func testClaudeUpgradeReplacesOwnedLegacyPermissionNotificationMatcher() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let hookExecutable = try makeExecutable(in: directory)
        let legacy: [String: Any] = [
            "hooks": [
                "Notification": [[
                    "matcher": "permission_prompt|idle_prompt|elicitation_dialog|agent_needs_input",
                    "hooks": [[
                        "type": "command",
                        "command": "\"\(hookExecutable.path)\" --provider claude",
                        "timeout": 2,
                    ]],
                ]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: settingsURL)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil
        )

        _ = try installer.mergeHooks(at: settingsURL, provider: .claude)
        let hooks = try XCTUnwrap(
            try json(at: settingsURL)["hooks"] as? [String: Any]
        )
        let groups = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups[0]["matcher"] as? String,
            "idle_prompt|elicitation_dialog|agent_needs_input"
        )
    }

    func testUninstallPreservesUnrelatedCommandThatOnlyContainsMarkerText() throws {
        let directory = temporaryDirectory()
        let settingsURL = directory.appendingPathComponent("settings.json")
        let hookExecutable = try makeExecutable(in: directory)
        let root: [String: Any] = [
            "hooks": [
                "Stop": [[
                    "hooks": [[
                        "type": "command",
                        "command": "/tmp/MyTurnringHook-wrapper --provider claude",
                    ]],
                ]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: settingsURL)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil
        )

        try installer.removeOwnedHooks(at: settingsURL)

        let preserved = try XCTUnwrap(
            try json(at: settingsURL)["hooks"] as? [String: Any]
        )
        XCTAssertNotNil(preserved["Stop"])
    }

    func testInstallRollsBackCodexWhenClaudeWriteFails() throws {
        let directory = temporaryDirectory()
        let codexDirectory = directory.appendingPathComponent("codex")
        let claudeDirectory = directory.appendingPathComponent("claude")
        try FileManager.default.createDirectory(
            at: codexDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: claudeDirectory,
            withIntermediateDirectories: true
        )
        let codexURL = codexDirectory.appendingPathComponent("hooks.json")
        let claudeURL = claudeDirectory.appendingPathComponent("settings.json")
        let originalCodex = Data(#"{"codex":"original"}"#.utf8)
        let originalClaude = Data(#"{"claude":"original"}"#.utf8)
        try originalCodex.write(to: codexURL)
        try originalClaude.write(to: claudeURL)
        let hookExecutable = try makeExecutable(in: directory)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil,
            codexHooksURL: codexURL,
            claudeSettingsURL: claudeURL
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: claudeDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: claudeDirectory.path
            )
        }

        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try Data(contentsOf: codexURL), originalCodex)
        XCTAssertEqual(try Data(contentsOf: claudeURL), originalClaude)
    }

    func testInstalledHookGroupsKeepExactCurrentSchema() throws {
        let directory = temporaryDirectory()
        let hookExecutable = try makeExecutable(in: directory)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil
        )
        let cases: [
            (
                provider: AgentProvider,
                fileName: String,
                matchers: [String: String?]
            )
        ] = [
            (
                .codex,
                "codex.json",
                [
                    "SessionStart": "startup|resume|clear|compact",
                    "UserPromptSubmit": nil,
                    "PermissionRequest": nil,
                    "PreToolUse": "^request_user_input$",
                    "Stop": nil,
                    "SessionEnd": nil,
                ]
            ),
            (
                .claude,
                "claude.json",
                [
                    "SessionStart": "startup|resume|clear|compact",
                    "UserPromptSubmit": nil,
                    "PermissionRequest": nil,
                    "PreToolUse": "^(AskUserQuestion|ExitPlanMode)$",
                    "Notification":
                        "idle_prompt|elicitation_dialog|agent_needs_input",
                    "Stop": nil,
                    "StopFailure": nil,
                    "SessionEnd": nil,
                ]
            ),
        ]

        for testCase in cases {
            let url = directory.appendingPathComponent(testCase.fileName)
            _ = try installer.mergeHooks(
                at: url,
                provider: testCase.provider
            )
            let hooks = try XCTUnwrap(
                try json(at: url)["hooks"] as? [String: Any]
            )
            XCTAssertEqual(Set(hooks.keys), Set(testCase.matchers.keys))

            for (eventName, matcher) in testCase.matchers {
                let groups = try XCTUnwrap(
                    hooks[eventName] as? [[String: Any]]
                )
                XCTAssertEqual(groups.count, 1)
                let group = try XCTUnwrap(groups.first)
                XCTAssertEqual(
                    Set(group.keys),
                    matcher == nil
                        ? Set(["hooks"])
                        : Set(["hooks", "matcher"])
                )
                XCTAssertEqual(group["matcher"] as? String, matcher)

                let handlers = try XCTUnwrap(
                    group["hooks"] as? [[String: Any]]
                )
                let handler = try XCTUnwrap(handlers.first)
                XCTAssertEqual(
                    Set(handler.keys),
                    Set([
                        "type",
                        "command",
                        "timeout",
                        "statusMessage",
                        "turnringOwner",
                    ])
                )
                XCTAssertEqual(handler["type"] as? String, "command")
                XCTAssertEqual(
                    handler["command"] as? String,
                    "'\(hookExecutable.path)' --provider "
                        + testCase.provider.rawValue
                )
                XCTAssertEqual(handler["timeout"] as? Int, 10)
                XCTAssertEqual(
                    handler["statusMessage"] as? String,
                    "Updating Turnring"
                )
                XCTAssertEqual(
                    handler["turnringOwner"] as? String,
                    "com.turnring.app"
                )
            }
        }
    }

    func testInstallSynchronizesOnlySelectedProviders() throws {
        let directory = temporaryDirectory()
        let codexURL = directory.appendingPathComponent("codex.json")
        let claudeURL = directory.appendingPathComponent("claude.json")
        let hookExecutable = try makeExecutable(in: directory)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil,
            codexHooksURL: codexURL,
            claudeSettingsURL: claudeURL
        )

        _ = try installer.install(providers: [.codex, .claude])
        XCTAssertTrue(installer.containsOwnedHook(at: codexURL))
        XCTAssertTrue(installer.containsOwnedHook(at: claudeURL))

        _ = try installer.install(providers: [.codex])

        XCTAssertTrue(
            installer.missingHookEvents(
                at: codexURL,
                provider: .codex
            ).isEmpty
        )
        XCTAssertFalse(installer.containsOwnedHook(at: claudeURL))
    }

    func testSelectedProviderIsNotBlockedByUnselectedInvalidConfiguration()
        throws
    {
        let directory = temporaryDirectory()
        let codexURL = directory.appendingPathComponent("codex.json")
        let claudeURL = directory.appendingPathComponent("claude.json")
        try Data("not-json".utf8).write(to: claudeURL)
        let hookExecutable = try makeExecutable(in: directory)
        let installer = ConfigurationInstaller(
            hookExecutablePath: hookExecutable.path,
            vscodeVSIXPath: nil,
            codexHooksURL: codexURL,
            claudeSettingsURL: claudeURL
        )

        _ = try installer.install(providers: [.codex])

        XCTAssertTrue(
            installer.missingHookEvents(
                at: codexURL,
                provider: .codex
            ).isEmpty
        )
        XCTAssertEqual(try Data(contentsOf: claudeURL), Data("not-json".utf8))
    }

    func testPersistentLauncherKeepsHookCommandStableAcrossAppMoves() throws {
        let directory = temporaryDirectory()
        let firstBundle = directory.appendingPathComponent("First App")
        let secondBundle = directory.appendingPathComponent("Second's App")
        try FileManager.default.createDirectory(
            at: firstBundle,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondBundle,
            withIntermediateDirectories: true
        )
        let firstHook = try makeExecutable(in: firstBundle)
        let secondHook = try makeExecutable(in: secondBundle)
        let launcher = directory.appendingPathComponent("support/TurnringHook")

        XCTAssertTrue(
            try ConfigurationInstaller.preparePersistentHookLauncher(
                at: launcher,
                bundledHookExecutablePath: firstHook.path
            )
        )
        let firstContents = try String(contentsOf: launcher, encoding: .utf8)
        XCTAssertTrue(firstContents.contains(firstHook.path))
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: launcher.path)
        )

        XCTAssertFalse(
            try ConfigurationInstaller.preparePersistentHookLauncher(
                at: launcher,
                bundledHookExecutablePath: firstHook.path
            )
        )
        XCTAssertTrue(
            try ConfigurationInstaller.preparePersistentHookLauncher(
                at: launcher,
                bundledHookExecutablePath: secondHook.path
            )
        )
        let secondContents = try String(contentsOf: launcher, encoding: .utf8)
        XCTAssertTrue(secondContents.contains("'\"'\"'"))
        XCTAssertFalse(secondContents.contains(firstHook.path))
        let process = Process()
        process.executableURL = launcher
        process.arguments = ["--provider", "codex"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeExecutable(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("TurnringHook")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func json(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurnringConfigTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
