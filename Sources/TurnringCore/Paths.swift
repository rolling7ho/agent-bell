import Foundation

public enum TurnringPaths {
    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    public static var applicationSupportDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Turnring", isDirectory: true)
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

    public static var integrationHookLauncher: URL {
        applicationSupportDirectory.appendingPathComponent("TurnringHook")
    }

    public static var ntfyOutboxFile: URL {
        applicationSupportDirectory.appendingPathComponent("ntfy-outbox.json")
    }

    public static var nativeNotificationOutboxFile: URL {
        applicationSupportDirectory.appendingPathComponent(
            "native-notification-outbox.json"
        )
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
        "com.turnring.app.event"
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
