import Foundation

public enum ConfigurationInstallerError: LocalizedError {
    case invalidJSONObject(URL)
    case missingHookExecutable
    case missingVSCodeCompanion
    case configurationWriteFailed(URL)
    case extensionInstallFailed(String)
    case extensionUninstallFailed(String)
    case hookLauncherWriteFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidJSONObject(let url):
            "The existing JSON file is invalid and was not changed: \(url.path)"
        case .missingHookExecutable:
            "TurnringHook is missing from the app bundle."
        case .missingVSCodeCompanion:
            "The bundled VS Code companion is missing."
        case .configurationWriteFailed(let url):
            "Could not safely write \(url.path)."
        case .extensionInstallFailed(let message):
            "VS Code companion installation failed: \(message)"
        case .extensionUninstallFailed(let message):
            "VS Code companion removal failed: \(message)"
        case .hookLauncherWriteFailed(let url):
            "Could not prepare the persistent Turnring hook at \(url.path)."
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
    public static let marker = "TurnringHook"
    public static let vscodeExtensionIdentifier = "turnring.focus"

    private let fileManager: FileManager
    private let hookExecutablePath: String
    private let codexHooksURL: URL
    private let claudeSettingsURL: URL
    private let files: ConfigurationFileStore
    private let hookEditor: HookConfigurationEditor
    private let vscodeCompanion: VSCodeCompanionManager

    public init(
        hookExecutablePath: String,
        vscodeVSIXPath: String?,
        codexHooksURL: URL = TurnringPaths.codexHooksFile,
        claudeSettingsURL: URL = TurnringPaths.claudeSettingsFile,
        fileManager: FileManager = .default
    ) {
        let files = ConfigurationFileStore(fileManager: fileManager)
        self.hookExecutablePath = hookExecutablePath
        self.codexHooksURL = codexHooksURL
        self.claudeSettingsURL = claudeSettingsURL
        self.fileManager = fileManager
        self.files = files
        hookEditor = HookConfigurationEditor(
            fileManager: fileManager,
            hookExecutablePath: hookExecutablePath,
            files: files
        )
        vscodeCompanion = VSCodeCompanionManager(
            fileManager: fileManager,
            vsixPath: vscodeVSIXPath,
            extensionIdentifier: Self.vscodeExtensionIdentifier
        )
    }

    public func install(
        providers: [AgentProvider] = AgentProvider.allCases
    ) throws -> IntegrationInstallResult {
        guard fileManager.isExecutableFile(atPath: hookExecutablePath) else {
            throw ConfigurationInstallerError.missingHookExecutable
        }
        try vscodeCompanion.validateBundleIfPresent()

        let selectedProviders = Set(providers.map(\.rawValue))
        let removeCodex = !selectedProviders.contains(
            AgentProvider.codex.rawValue
        ) && hookEditor.containsOwnedHook(at: codexHooksURL)
        let removeClaude = !selectedProviders.contains(
            AgentProvider.claude.rawValue
        ) && hookEditor.containsOwnedHook(at: claudeSettingsURL)
        var touchedURLs: [URL] = []
        if selectedProviders.contains(AgentProvider.codex.rawValue)
            || removeCodex
        {
            touchedURLs.append(codexHooksURL)
        }
        if selectedProviders.contains(AgentProvider.claude.rawValue)
            || removeClaude
        {
            touchedURLs.append(claudeSettingsURL)
        }

        // Validate every file this selection can change before changing any.
        for url in touchedURLs {
            _ = try files.readJSONObject(at: url)
        }
        let originals = try files.snapshots(for: touchedURLs)
        do {
            let codexBackup: URL?
            if selectedProviders.contains(AgentProvider.codex.rawValue) {
                codexBackup = try hookEditor.mergeHooks(
                    at: codexHooksURL,
                    provider: .codex
                )
            } else if removeCodex {
                try hookEditor.removeOwnedHooks(at: codexHooksURL)
                codexBackup = nil
            } else {
                codexBackup = nil
            }

            let claudeBackup: URL?
            if selectedProviders.contains(AgentProvider.claude.rawValue) {
                claudeBackup = try hookEditor.mergeHooks(
                    at: claudeSettingsURL,
                    provider: .claude
                )
            } else if removeClaude {
                try hookEditor.removeOwnedHooks(at: claudeSettingsURL)
                claudeBackup = nil
            } else {
                claudeBackup = nil
            }

            let companionInstalled = selectedProviders.isEmpty
                ? false
                : try vscodeCompanion.installIfAvailable()
            return IntegrationInstallResult(
                codexBackup: codexBackup,
                claudeBackup: claudeBackup,
                vscodeCompanionInstalled: companionInstalled
            )
        } catch {
            files.restore(originals)
            throw error
        }
    }

    public func uninstall() throws {
        let originals = try files.snapshots(
            for: [codexHooksURL, claudeSettingsURL]
        )
        do {
            try hookEditor.removeOwnedHooks(at: codexHooksURL)
            try hookEditor.removeOwnedHooks(at: claudeSettingsURL)
            try vscodeCompanion.uninstallIfInstalled()
        } catch {
            files.restore(originals)
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
    public func mergeHooks(
        at url: URL,
        provider: AgentProvider
    ) throws -> URL? {
        try hookEditor.mergeHooks(at: url, provider: provider)
    }

    public func removeOwnedHooks(at url: URL) throws {
        try hookEditor.removeOwnedHooks(at: url)
    }

    public func containsOwnedHook(at url: URL) -> Bool {
        hookEditor.containsOwnedHook(at: url)
    }

    public func missingHookEvents(
        at url: URL,
        provider: AgentProvider
    ) -> [String] {
        hookEditor.missingHookEvents(at: url, provider: provider)
    }

    public static func vscodeCompanionIsInstalled() -> Bool {
        VSCodeCompanionManager.isInstalled(
            extensionIdentifier: Self.vscodeExtensionIdentifier
        )
    }

    public static func vscodeCLIPath() -> String? {
        VSCodeCompanionManager.cliPath()
    }

    @discardableResult
    public static func preparePersistentHookLauncher(
        at launcherURL: URL,
        bundledHookExecutablePath: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard fileManager.isExecutableFile(atPath: bundledHookExecutablePath)
        else {
            throw ConfigurationInstallerError.missingHookExecutable
        }

        let quotedExecutable = "'"
            + bundledHookExecutablePath.replacingOccurrences(
                of: "'",
                with: "'\"'\"'"
            )
            + "'"
        let contents = "#!/bin/zsh\nset -eu\nexec \(quotedExecutable) \"$@\"\n"
        let data = Data(contents.utf8)

        if fileManager.fileExists(atPath: launcherURL.path),
           let attributes = try? fileManager.attributesOfItem(
               atPath: launcherURL.path
           ),
           attributes[.type] as? FileAttributeType == .typeRegular,
           (try? Data(contentsOf: launcherURL)) == data,
           fileManager.isExecutableFile(atPath: launcherURL.path)
        {
            return false
        }

        let directory = launcherURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".TurnringHook-\(UUID().uuidString)"
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: temporary.path
            )
            if fileManager.fileExists(atPath: launcherURL.path) {
                let attributes = try fileManager.attributesOfItem(
                    atPath: launcherURL.path
                )
                guard attributes[.type] as? FileAttributeType == .typeRegular
                else {
                    throw ConfigurationInstallerError.hookLauncherWriteFailed(
                        launcherURL
                    )
                }
                _ = try fileManager.replaceItemAt(
                    launcherURL,
                    withItemAt: temporary
                )
            } else {
                try fileManager.moveItem(at: temporary, to: launcherURL)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: launcherURL.path
            )
            return true
        } catch {
            try? fileManager.removeItem(at: temporary)
            if let error = error as? ConfigurationInstallerError {
                throw error
            }
            throw ConfigurationInstallerError.hookLauncherWriteFailed(
                launcherURL
            )
        }
    }
}
