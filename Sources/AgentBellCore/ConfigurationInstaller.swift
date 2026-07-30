import Foundation

public enum ConfigurationInstallerError: LocalizedError {
    case invalidJSONObject(URL)
    case missingHookExecutable
    case missingVSCodeCompanion
    case configurationWriteFailed(URL)
    case extensionInstallFailed(String)
    case extensionUninstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSONObject(let url):
            "The existing JSON file is invalid and was not changed: \(url.path)"
        case .missingHookExecutable:
            "AgentBellHook is missing from the app bundle."
        case .missingVSCodeCompanion:
            "The bundled VS Code companion is missing."
        case .configurationWriteFailed(let url):
            "Could not safely write \(url.path)."
        case .extensionInstallFailed(let message):
            "VS Code companion installation failed: \(message)"
        case .extensionUninstallFailed(let message):
            "VS Code companion removal failed: \(message)"
        }
    }
}

public struct IntegrationInstallResult: Sendable {
    public var codexBackup: URL?
    public var claudeBackup: URL?
    public var vscodeCompanionInstalled: Bool

    public init(codexBackup: URL?, claudeBackup: URL?, vscodeCompanionInstalled: Bool) {
        self.codexBackup = codexBackup
        self.claudeBackup = claudeBackup
        self.vscodeCompanionInstalled = vscodeCompanionInstalled
    }
}

public struct IntegrationStatus: Sendable, Equatable {
    public var codex: Bool
    public var claude: Bool
    public var vscode: Bool
    public var missingCodexEvents: [String]
    public var missingClaudeEvents: [String]

    public init(
        codex: Bool,
        claude: Bool,
        vscode: Bool,
        missingCodexEvents: [String] = [],
        missingClaudeEvents: [String] = []
    ) {
        self.codex = codex
        self.claude = claude
        self.vscode = vscode
        self.missingCodexEvents = missingCodexEvents
        self.missingClaudeEvents = missingClaudeEvents
    }
}

public final class ConfigurationInstaller: @unchecked Sendable {
    public static let marker = "AgentBellHook"
    public static let vscodeExtensionIdentifier = "agentbell.focus"
    private static let maximumConfigurationBytes = 8 * 1_024 * 1_024

    private let fileManager: FileManager
    private let hookExecutablePath: String
    private let vscodeVSIXPath: String?
    private let codexHooksURL: URL
    private let claudeSettingsURL: URL

    private struct ConfigurationSnapshot {
        var url: URL
        var data: Data?
    }

    public init(
        hookExecutablePath: String,
        vscodeVSIXPath: String?,
        codexHooksURL: URL = AgentBellPaths.codexHooksFile,
        claudeSettingsURL: URL = AgentBellPaths.claudeSettingsFile,
        fileManager: FileManager = .default
    ) {
        self.hookExecutablePath = hookExecutablePath
        self.vscodeVSIXPath = vscodeVSIXPath
        self.codexHooksURL = codexHooksURL
        self.claudeSettingsURL = claudeSettingsURL
        self.fileManager = fileManager
    }

    public func install() throws -> IntegrationInstallResult {
        guard fileManager.isExecutableFile(atPath: hookExecutablePath) else {
            throw ConfigurationInstallerError.missingHookExecutable
        }
        if let vscodeVSIXPath,
           !fileManager.fileExists(atPath: vscodeVSIXPath)
        {
            throw ConfigurationInstallerError.missingVSCodeCompanion
        }

        // Validate both existing files before changing either one.
        _ = try readJSONObject(at: codexHooksURL)
        _ = try readJSONObject(at: claudeSettingsURL)

        let originals = try configurationSnapshots()
        do {
            let codexBackup = try mergeHooks(
                at: codexHooksURL,
                provider: .codex
            )
            let claudeBackup = try mergeHooks(
                at: claudeSettingsURL,
                provider: .claude
            )
            let companionInstalled = try installVSCodeCompanionIfAvailable()
            return IntegrationInstallResult(
                codexBackup: codexBackup,
                claudeBackup: claudeBackup,
                vscodeCompanionInstalled: companionInstalled
            )
        } catch {
            restoreConfigurations(from: originals)
            throw error
        }
    }

    public func uninstall() throws {
        let originals = try configurationSnapshots()
        do {
            try removeOwnedHooks(at: codexHooksURL)
            try removeOwnedHooks(at: claudeSettingsURL)
            try uninstallVSCodeCompanion()
        } catch {
            restoreConfigurations(from: originals)
            throw error
        }
    }

    public func integrationStatus() -> IntegrationStatus {
        let missingCodex = missingHookEvents(
            at: codexHooksURL,
            provider: .codex
        )
        let missingClaude = missingHookEvents(
            at: claudeSettingsURL,
            provider: .claude
        )
        return IntegrationStatus(
            codex: missingCodex.isEmpty,
            claude: missingClaude.isEmpty,
            vscode: Self.vscodeCompanionIsInstalled(),
            missingCodexEvents: missingCodex,
            missingClaudeEvents: missingClaude
        )
    }

    @discardableResult
    public func mergeHooks(at url: URL, provider: AgentProvider) throws -> URL? {
        var root = try readJSONObject(at: url)
        let original = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let desiredEvents = hookEvents(for: provider)

        for (eventName, matcher) in desiredEvents {
            var groups = hooks[eventName] as? [[String: Any]] ?? []
            groups = removeOwnedHandlers(from: groups)

            let handler: [String: Any] = [
                "type": "command",
                "command": hookCommand(provider: provider),
                "timeout": 2,
                "statusMessage": "Updating AgentBell",
                "agentbellOwner": "com.agentbell.app",
            ]

            var group: [String: Any] = ["hooks": [handler]]
            if let matcher {
                group["matcher"] = matcher
            }
            groups.append(group)
            hooks[eventName] = groups
        }

        root["hooks"] = hooks
        guard !jsonObjectsEqual(original, root) else { return nil }
        let backup = try backupIfPresent(url)
        try writeJSONObject(root, to: url)
        return backup
    }

    public func removeOwnedHooks(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        var root = try readJSONObject(at: url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        var changed = false

        for eventName in Array(hooks.keys) {
            guard let groups = hooks[eventName] as? [[String: Any]] else { continue }
            let cleaned = removeOwnedHandlers(from: groups)
            if !jsonObjectsEqual(groups, cleaned) {
                changed = true
            }
            if cleaned.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = cleaned
            }
        }

        guard changed else { return }
        root["hooks"] = hooks
        _ = try backupIfPresent(url)
        try writeJSONObject(root, to: url)
    }

    public func containsOwnedHook(at url: URL) -> Bool {
        guard let root = try? readJSONObject(at: url),
              let hooks = root["hooks"] as? [String: Any]
        else {
            return false
        }
        return hooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                return handlers.contains(where: isOwnedHandler)
            }
        }
    }

    public func missingHookEvents(at url: URL, provider: AgentProvider) -> [String] {
        guard fileManager.isExecutableFile(atPath: hookExecutablePath),
              let root = try? readJSONObject(at: url),
              let hooks = root["hooks"] as? [String: Any]
        else {
            return hookEvents(for: provider).map { $0.0 }
        }
        let expectedCommand = hookCommand(provider: provider)
        return hookEvents(for: provider).compactMap { eventName, expectedMatcher in
            guard let groups = hooks[eventName] as? [[String: Any]] else {
                return eventName
            }
            let hasExactHandler = groups.contains { group in
                guard group["matcher"] as? String == expectedMatcher else {
                    return false
                }
                guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                return handlers.contains { handler in
                    isOwnedHandler(handler)
                        && handler["type"] as? String == "command"
                        && handler["command"] as? String == expectedCommand
                }
            }
            return hasExactHandler ? nil : eventName
        }
    }

    private func hookEvents(for provider: AgentProvider) -> [(String, String?)] {
        switch provider {
        case .codex:
            [
                ("SessionStart", "startup|resume|clear|compact"),
                ("UserPromptSubmit", nil),
                ("PermissionRequest", nil),
                ("PreToolUse", "^request_user_input$"),
                ("Stop", nil),
                ("SessionEnd", nil),
            ]
        case .claude:
            [
                ("SessionStart", "startup|resume|clear|compact"),
                ("UserPromptSubmit", nil),
                ("PermissionRequest", nil),
                ("PreToolUse", "^(AskUserQuestion|ExitPlanMode)$"),
                ("Notification", "idle_prompt|elicitation_dialog|agent_needs_input"),
                ("Stop", nil),
                ("StopFailure", nil),
                ("SessionEnd", nil),
            ]
        }
    }

    private func removeOwnedHandlers(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
            let filtered = handlers.filter { !isOwnedHandler($0) }
            guard !filtered.isEmpty else { return nil }
            var updated = group
            updated["hooks"] = filtered
            return updated
        }
    }

    private func isOwnedHandler(_ handler: [String: Any]) -> Bool {
        if handler["agentbellOwner"] as? String == "com.agentbell.app" {
            return true
        }
        guard let command = handler["command"] as? String else { return false }
        let pattern = #"^"[^"]*/AgentBellHook"\s+--provider\s+(codex|claude)$"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    private func readJSONObject(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ),
            let size = attributes[.size] as? NSNumber,
            size.intValue <= Self.maximumConfigurationBytes
        else {
            throw ConfigurationInstallerError.invalidJSONObject(url)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(
            upToCount: Self.maximumConfigurationBytes + 1
        ) ?? Data()
        guard data.count <= Self.maximumConfigurationBytes else {
            throw ConfigurationInstallerError.invalidJSONObject(url)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw ConfigurationInstallerError.invalidJSONObject(url)
        }
        return dictionary
    }

    private func hookCommand(provider: AgentProvider) -> String {
        let quotedPath = "'"
            + hookExecutablePath.replacingOccurrences(
                of: "'",
                with: "'\"'\"'"
            )
            + "'"
        return "\(quotedPath) --provider \(provider.rawValue)"
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).agentbell-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw ConfigurationInstallerError.configurationWriteFailed(url)
        }
    }

    private func backupIfPresent(_ url: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backup = url
            .deletingPathExtension()
            .appendingPathExtension(
                "agentbell-backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json"
            )
        try fileManager.copyItem(at: url, to: backup)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup
    }

    private func jsonObjectsEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject(lhs),
              JSONSerialization.isValidJSONObject(rhs),
              let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
        else {
            return false
        }
        return left == right
    }

    private func configurationSnapshots() throws -> [ConfigurationSnapshot] {
        try [codexHooksURL, claudeSettingsURL].map { url in
            ConfigurationSnapshot(
                url: url,
                data: fileManager.fileExists(atPath: url.path)
                    ? try readRawConfigurationData(at: url)
                    : nil
            )
        }
    }

    private func readRawConfigurationData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(
            upToCount: Self.maximumConfigurationBytes + 1
        ) ?? Data()
        guard data.count <= Self.maximumConfigurationBytes else {
            throw ConfigurationInstallerError.invalidJSONObject(url)
        }
        return data
    }

    private func restoreConfigurations(from snapshots: [ConfigurationSnapshot]) {
        for snapshot in snapshots {
            if let data = snapshot.data {
                try? restoreData(data, to: snapshot.url)
            } else if fileManager.fileExists(atPath: snapshot.url.path) {
                try? fileManager.removeItem(at: snapshot.url)
            }
        }
    }

    private func restoreData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).agentbell-rollback-\(UUID().uuidString)"
        )
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    private func installVSCodeCompanionIfAvailable() throws -> Bool {
        guard let vscodeVSIXPath else { return false }
        guard fileManager.fileExists(atPath: vscodeVSIXPath) else {
            throw ConfigurationInstallerError.missingVSCodeCompanion
        }
        guard let codePath = Self.vscodeCLIPath() else { return false }
        let result = ProcessInspector.run(
            executable: codePath,
            arguments: ["--install-extension", vscodeVSIXPath, "--force"],
            timeout: 20
        )
        guard result.status == 0 else {
            throw ConfigurationInstallerError.extensionInstallFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return true
    }

    private func uninstallVSCodeCompanion() throws {
        guard Self.vscodeCompanionIsInstalled(),
              let codePath = Self.vscodeCLIPath()
        else {
            return
        }
        let result = ProcessInspector.run(
            executable: codePath,
            arguments: ["--uninstall-extension", Self.vscodeExtensionIdentifier],
            timeout: 20
        )
        guard result.status == 0 else {
            throw ConfigurationInstallerError.extensionUninstallFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    public static func vscodeCompanionIsInstalled() -> Bool {
        guard let codePath = Self.vscodeCLIPath() else { return false }
        let result = ProcessInspector.run(
            executable: codePath,
            arguments: ["--list-extensions"],
            timeout: 10
        )
        return result.status == 0
            && result.output.split(whereSeparator: \.isNewline)
                .contains(Substring(Self.vscodeExtensionIdentifier))
    }

    public static func vscodeCLIPath() -> String? {
        let candidates = [
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}
