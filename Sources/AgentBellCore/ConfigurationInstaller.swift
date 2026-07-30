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
        codexHooksURL: URL = AgentBellPaths.codexHooksFile,
        claudeSettingsURL: URL = AgentBellPaths.claudeSettingsFile,
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

    public func install() throws -> IntegrationInstallResult {
        guard fileManager.isExecutableFile(atPath: hookExecutablePath) else {
            throw ConfigurationInstallerError.missingHookExecutable
        }
        try vscodeCompanion.validateBundleIfPresent()

        // Validate both existing files before changing either one.
        _ = try files.readJSONObject(at: codexHooksURL)
        _ = try files.readJSONObject(at: claudeSettingsURL)

        let originals = try files.snapshots(
            for: [codexHooksURL, claudeSettingsURL]
        )
        do {
            let codexBackup = try hookEditor.mergeHooks(
                at: codexHooksURL,
                provider: .codex
            )
            let claudeBackup = try hookEditor.mergeHooks(
                at: claudeSettingsURL,
                provider: .claude
            )
            let companionInstalled = try vscodeCompanion.installIfAvailable()
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
}
