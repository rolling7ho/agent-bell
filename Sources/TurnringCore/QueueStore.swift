import Darwin
import Foundation

public enum QueueStoreError: Error {
    case openFailed
    case lockFailed
    case writeFailed
    case claimFailed
}

public enum EventQueue {
    private static let maximumQueueBytes = EventNormalizer.maximumPayloadBytes * 64

    public static func append(_ event: AgentEvent, to url: URL = TurnringPaths.queueFile) throws {
        try prepareParentDirectory(for: url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A)

        let lockDescriptor = try acquireQueueLock(for: url)
        defer {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }

        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw QueueStoreError.openFailed }
        defer { Darwin.close(descriptor) }

        var fileStatus = stat()
        if fstat(descriptor, &fileStatus) == 0,
           fileStatus.st_size > maximumQueueBytes
        {
            _ = ftruncate(descriptor, 0)
        }

        var bytesWritten = 0
        let succeeded = data.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            while bytesWritten < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: bytesWritten),
                    buffer.count - bytesWritten
                )
                guard result > 0 else { return false }
                bytesWritten += result
            }
            return true
        }
        guard succeeded else { throw QueueStoreError.writeFailed }
        _ = fsync(descriptor)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public struct Claim: Sendable {
        public let events: [AgentEvent]
        fileprivate let processingURL: URL
    }

    /// Atomically moves the current queue into a processing file. New hook
    /// events continue to append to a fresh queue while the app handles this
    /// claim. A surviving processing file is replayed after an app crash.
    public static func claim(
        from url: URL = TurnringPaths.queueFile,
        processingURL: URL? = nil
    ) throws -> Claim? {
        try prepareParentDirectory(for: url)
        let claimedURL = processingURL
            ?? url.deletingLastPathComponent().appendingPathComponent("events.processing.jsonl")

        if FileManager.default.fileExists(atPath: claimedURL.path) {
            return try decodeClaim(at: claimedURL)
        }

        let lockDescriptor = try acquireQueueLock(for: url)
        defer {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }

        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw QueueStoreError.openFailed }
        defer { Darwin.close(descriptor) }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0 else {
            throw QueueStoreError.claimFailed
        }
        guard fileStatus.st_size > 0 else { return nil }
        guard fileStatus.st_size <= maximumQueueBytes else {
            _ = ftruncate(descriptor, 0)
            return nil
        }

        do {
            if FileManager.default.fileExists(atPath: claimedURL.path) {
                try FileManager.default.removeItem(at: claimedURL)
            }
            try FileManager.default.moveItem(at: url, to: claimedURL)
            let replacement = Darwin.open(
                url.path,
                O_WRONLY | O_CREAT | O_EXCL,
                S_IRUSR | S_IWUSR
            )
            guard replacement >= 0 else { throw QueueStoreError.claimFailed }
            Darwin.close(replacement)
        } catch {
            throw QueueStoreError.claimFailed
        }
        return try decodeClaim(at: claimedURL)
    }

    public static func acknowledge(_ claim: Claim) throws {
        guard FileManager.default.fileExists(atPath: claim.processingURL.path) else { return }
        try FileManager.default.removeItem(at: claim.processingURL)
    }

    /// Compatibility helper for callers that do not need crash-safe
    /// acknowledgement. The application uses `claim` and `acknowledge`.
    public static func drain(from url: URL = TurnringPaths.queueFile) throws -> [AgentEvent] {
        let processingURL = url.deletingLastPathComponent()
            .appendingPathComponent("events.processing.jsonl")
        guard let claim = try claim(from: url, processingURL: processingURL) else { return [] }
        try acknowledge(claim)
        return claim.events
    }

    private static func decodeClaim(at url: URL) throws -> Claim? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(
            upToCount: maximumQueueBytes + 1
        ) ?? Data()
        guard data.count <= maximumQueueBytes else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(AgentEvent.self, from: Data($0)) }
        return Claim(events: events, processingURL: url)
    }

    private static func prepareParentDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static func acquireQueueLock(for url: URL) throws -> Int32 {
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".events.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw QueueStoreError.openFailed }
        guard flock(descriptor, LOCK_EX) == 0 else {
            Darwin.close(descriptor)
            throw QueueStoreError.lockFailed
        }
        return descriptor
    }
}
