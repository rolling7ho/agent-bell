import Foundation

public enum AgentBellPaths {
    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    public static var applicationSupportDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AgentBell", isDirectory: true)
    }

    public static var queueFile: URL {
        applicationSupportDirectory.appendingPathComponent("events.jsonl")
    }

    public static var queueClaimFile: URL {
        applicationSupportDirectory.appendingPathComponent("events.processing.jsonl")
    }

    public static var stateFile: URL {
        applicationSupportDirectory.appendingPathComponent("sessions.json")
    }

    public static var instanceLockFile: URL {
        applicationSupportDirectory.appendingPathComponent("instance.lock")
    }

    public static var ntfyOutboxFile: URL {
        applicationSupportDirectory.appendingPathComponent("ntfy-outbox.json")
    }

    public static var focusRequestsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("focus-requests", isDirectory: true)
    }

    public static var resumeScriptsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("resume-scripts", isDirectory: true)
    }

    public static var codexHooksFile: URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    public static var claudeSettingsFile: URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public static let eventNotificationName = Notification.Name(
        "com.agentbell.app.event"
    )

    public static func prepareRuntimeDirectories() throws {
        let manager = FileManager.default
        for directory in [
            applicationSupportDirectory,
            focusRequestsDirectory,
            resumeScriptsDirectory,
        ] {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    @discardableResult
    public static func cleanupStaleRuntimeFiles(
        now: Date = Date(),
        maximumAge: TimeInterval = 3_600,
        fileManager: FileManager = .default,
        directories: [(url: URL, fileExtension: String)]? = nil
    ) -> Int {
        let targets = directories ?? [
            (focusRequestsDirectory, "json"),
            (resumeScriptsDirectory, "command"),
        ]
        var removedCount = 0
        for target in targets {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: target.url,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for url in contents where url.pathExtension == target.fileExtension {
                guard let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey]
                ),
                    values.isRegularFile == true,
                    let modifiedAt = values.contentModificationDate,
                    now.timeIntervalSince(modifiedAt) >= maximumAge
                else {
                    continue
                }
                if (try? fileManager.removeItem(at: url)) != nil {
                    removedCount += 1
                }
            }
        }
        return removedCount
    }
}

public enum AgentBellValidation {
    private static let sessionPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$"#
    )

    public static func isValidSessionID(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return sessionPattern.firstMatch(in: value, range: range) != nil
    }

    public static func isValidOptionalIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 192 else { return false }
        return value.allSatisfy {
            $0.isLetter || $0.isNumber || "._:-".contains($0)
        }
    }

    public static func validatedDirectory(_ value: String) -> String? {
        guard let path = normalizedAbsolutePath(value) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return path
    }

    public static func normalizedAbsolutePath(_ value: String) -> String? {
        guard !value.isEmpty,
              value.hasPrefix("/"),
              value.utf8.count <= 4096,
              !value.contains("\0")
        else {
            return nil
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    public static func projectName(for cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        let safeName = AgentBellSafeText.collapsed(
            name,
            maximumCharacters: 100
        )
        return safeName.isEmpty ? "Project" : safeName
    }

    public static func resumeArguments(
        provider: AgentProvider,
        sessionID: String
    ) -> [String]? {
        guard isValidSessionID(sessionID) else { return nil }
        return provider.resumeArguments + [sessionID]
    }

    public static func isValidExecutable(
        _ path: String,
        for provider: AgentProvider,
        fileManager: FileManager = .default
    ) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let expectedNames = provider == .codex
            ? ["codex"]
            : ["claude", "claude.exe"]
        return expectedNames.contains(name)
            && fileManager.isExecutableFile(atPath: path)
    }
}
