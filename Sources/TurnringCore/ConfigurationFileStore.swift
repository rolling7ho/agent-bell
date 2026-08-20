import Foundation

final class ConfigurationFileStore {
    private static let maximumConfigurationBytes = 8 * 1_024 * 1_024

    struct Snapshot {
        var url: URL
        var data: Data?
    }

    let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func readJSONObject(at url: URL) throws -> [String: Any] {
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

    func writeJSONObject(_ object: [String: Any], to url: URL) throws {
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

        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).turnring-\(UUID().uuidString)"
        )
        do {
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
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw ConfigurationInstallerError.configurationWriteFailed(url)
        }
    }

    func backupIfPresent(_ url: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backup = url
            .deletingPathExtension()
            .appendingPathExtension(
                "turnring-backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json"
            )
        try fileManager.copyItem(at: url, to: backup)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backup.path
        )
        return backup
    }

    func jsonObjectsEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject(lhs),
              JSONSerialization.isValidJSONObject(rhs),
              let left = try? JSONSerialization.data(
                  withJSONObject: lhs,
                  options: [.sortedKeys]
              ),
              let right = try? JSONSerialization.data(
                  withJSONObject: rhs,
                  options: [.sortedKeys]
              )
        else {
            return false
        }
        return left == right
    }

    func snapshots(for urls: [URL]) throws -> [Snapshot] {
        try urls.map { url in
            Snapshot(
                url: url,
                data: fileManager.fileExists(atPath: url.path)
                    ? try readRawConfigurationData(at: url)
                    : nil
            )
        }
    }

    func restore(_ snapshots: [Snapshot]) {
        for snapshot in snapshots {
            if let data = snapshot.data {
                try? restoreData(data, to: snapshot.url)
            } else if fileManager.fileExists(atPath: snapshot.url.path) {
                try? fileManager.removeItem(at: snapshot.url)
            }
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

    private func restoreData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).turnring-rollback-\(UUID().uuidString)"
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
}
