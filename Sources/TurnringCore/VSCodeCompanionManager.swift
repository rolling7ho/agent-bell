import Foundation

struct VSCodeCompanionManager {
    private let fileManager: FileManager
    private let vsixPath: String?
    private let extensionIdentifier: String

    init(
        fileManager: FileManager,
        vsixPath: String?,
        extensionIdentifier: String
    ) {
        self.fileManager = fileManager
        self.vsixPath = vsixPath
        self.extensionIdentifier = extensionIdentifier
    }

    func validateBundleIfPresent() throws {
        if let vsixPath,
           !fileManager.fileExists(atPath: vsixPath)
        {
            throw ConfigurationInstallerError.missingVSCodeCompanion
        }
    }

    func installIfAvailable() throws -> Bool {
        guard let vsixPath else { return false }
        guard fileManager.fileExists(atPath: vsixPath) else {
            throw ConfigurationInstallerError.missingVSCodeCompanion
        }
        guard let codePath = Self.cliPath() else { return false }
        let result = ProcessInspector.run(
            executable: codePath,
            arguments: ["--install-extension", vsixPath, "--force"],
            timeout: 20
        )
        guard result.status == 0 else {
            throw ConfigurationInstallerError.extensionInstallFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return true
    }

    func uninstallIfInstalled() throws {
        guard Self.isInstalled(extensionIdentifier: extensionIdentifier),
              let codePath = Self.cliPath()
        else {
            return
        }
        let result = ProcessInspector.run(
            executable: codePath,
            arguments: ["--uninstall-extension", extensionIdentifier],
            timeout: 20
        )
        guard result.status == 0 else {
            throw ConfigurationInstallerError.extensionUninstallFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func isInstalled(extensionIdentifier: String) -> Bool {
        guard let codePath = cliPath() else { return false }
        let result = ProcessInspector.run(
            executable: codePath,
            arguments: ["--list-extensions"],
            timeout: 10
        )
        return result.status == 0
            && result.output.split(whereSeparator: \.isNewline)
                .contains(Substring(extensionIdentifier))
    }

    static func cliPath() -> String? {
        let candidates = [
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code",
        ]
        return candidates.first(
            where: FileManager.default.isExecutableFile(atPath:)
        )
    }
}
