import Foundation

public enum NativeNotificationOutboxError: Error, Equatable {
    case capacityReached
    case unavailable
}

public struct NativeNotificationDelivery: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var genericTitle: String
    public var genericBody: String
    public var threadIdentifier: String
    public var routeID: String
    public var containsPrivateDetails: Bool
    public var isTest: Bool
    public var surfaceKey: String
    public var createdAt: Date
    public var nextAttemptAt: Date
    public var attemptCount: Int

    public init(
        id: String,
        title: String,
        body: String,
        genericTitle: String,
        genericBody: String,
        threadIdentifier: String,
        routeID: String,
        containsPrivateDetails: Bool,
        isTest: Bool = false,
        surfaceKey: String,
        createdAt: Date = Date(),
        nextAttemptAt: Date? = nil,
        attemptCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.genericTitle = genericTitle
        self.genericBody = genericBody
        self.threadIdentifier = threadIdentifier
        self.routeID = routeID
        self.containsPrivateDetails = containsPrivateDetails
        self.isTest = isTest
        self.surfaceKey = surfaceKey
        self.createdAt = createdAt
        self.nextAttemptAt = nextAttemptAt ?? createdAt
        self.attemptCount = max(0, attemptCount)
    }
}

public final class NativeNotificationOutbox: @unchecked Sendable {
    public static let maximumDeliveries = 2_000
    private static let maximumStateBytes = 8 * 1_024 * 1_024

    private struct PersistedState: Codable {
        var version: Int
        var deliveries: [NativeNotificationDelivery]
    }

    private let lock = NSLock()
    private let stateURL: URL
    private var deliveriesByID: [String: NativeNotificationDelivery] = [:]
    private var loadFailed = false

    public init(stateURL: URL = TurnringPaths.nativeNotificationOutboxFile) {
        self.stateURL = stateURL
        load()
    }

    public var isOperational: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !loadFailed
    }

    public func enqueue(_ delivery: NativeNotificationDelivery) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else {
            throw NativeNotificationOutboxError.unavailable
        }
        guard deliveriesByID[delivery.id] == nil else { return }
        guard deliveriesByID.count < Self.maximumDeliveries else {
            throw NativeNotificationOutboxError.capacityReached
        }
        var updated = deliveriesByID
        updated[delivery.id] = delivery
        try saveLocked(updated)
        deliveriesByID = updated
    }

    public func dueDeliveries(
        at date: Date = Date(),
        limit: Int = 20
    ) -> [NativeNotificationDelivery] {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else { return [] }
        return deliveriesByID.values
            .filter {
                $0.nextAttemptAt <= date
                    || $0.nextAttemptAt.timeIntervalSince(date) > 3_600
            }
            .sorted { lhs, rhs in
                if lhs.nextAttemptAt == rhs.nextAttemptAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.nextAttemptAt < rhs.nextAttemptAt
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func markSucceeded(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else {
            throw NativeNotificationOutboxError.unavailable
        }
        guard deliveriesByID[id] != nil else { return }
        var updated = deliveriesByID
        updated.removeValue(forKey: id)
        try saveLocked(updated)
        deliveriesByID = updated
    }

    public func markFailed(id: String, at date: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else {
            throw NativeNotificationOutboxError.unavailable
        }
        guard var delivery = deliveriesByID[id] else { return }
        delivery.attemptCount = delivery.attemptCount == Int.max
            ? Int.max
            : delivery.attemptCount + 1
        delivery.nextAttemptAt = date.addingTimeInterval(
            retryDelay(after: delivery.attemptCount)
        )
        var updated = deliveriesByID
        updated[id] = delivery
        try saveLocked(updated)
        deliveriesByID = updated
    }

    public func discard(
        where shouldDiscard: (NativeNotificationDelivery) -> Bool
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else {
            throw NativeNotificationOutboxError.unavailable
        }
        let updated = deliveriesByID.filter {
            !shouldDiscard($0.value)
        }
        guard updated.count != deliveriesByID.count else { return }
        try saveLocked(updated)
        deliveriesByID = updated
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: stateURL.path) {
            try FileManager.default.removeItem(at: stateURL)
        }
        deliveriesByID.removeAll()
        loadFailed = false
    }

    public func allDeliveries() -> [NativeNotificationDelivery] {
        lock.lock()
        defer { lock.unlock() }
        return deliveriesByID.values.sorted { $0.createdAt < $1.createdAt }
    }

    private func retryDelay(after attemptCount: Int) -> TimeInterval {
        let delays: [TimeInterval] = [5, 15, 60, 300, 900, 3_600]
        return delays[min(max(1, attemptCount) - 1, delays.count - 1)]
    }

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: stateURL) else {
            return
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(
            upToCount: Self.maximumStateBytes + 1
        ),
            data.count <= Self.maximumStateBytes
        else {
            loadFailed = true
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(PersistedState.self, from: data)
        else {
            loadFailed = true
            return
        }
        var loaded: [String: NativeNotificationDelivery] = [:]
        for delivery in state.deliveries {
            guard let validated = validatedLoadedDelivery(delivery) else {
                loadFailed = true
                return
            }
            if let existing = loaded[validated.id],
               existing.createdAt >= validated.createdAt
            {
                continue
            }
            loaded[validated.id] = validated
        }
        guard loaded.count <= Self.maximumDeliveries else {
            loadFailed = true
            return
        }
        deliveriesByID = loaded
    }

    private func validatedLoadedDelivery(
        _ value: NativeNotificationDelivery
    ) -> NativeNotificationDelivery? {
        guard !value.id.isEmpty,
              value.id.utf8.count <= 128,
              value.id.allSatisfy({
                  $0.isLetter || $0.isNumber || "._:-".contains($0)
              }),
              !value.title.isEmpty,
              value.title.count <= 200,
              !value.body.isEmpty,
              value.body.count <= 1_000,
              !value.genericTitle.isEmpty,
              value.genericTitle.count <= 200,
              !value.genericBody.isEmpty,
              value.genericBody.count <= 1_000,
              !value.threadIdentifier.isEmpty,
              value.threadIdentifier.utf8.count <= 128,
              !value.routeID.isEmpty,
              value.routeID.utf8.count <= 128,
              !value.surfaceKey.isEmpty,
              value.surfaceKey.utf8.count <= 100,
              value.createdAt.timeIntervalSinceReferenceDate.isFinite,
              value.nextAttemptAt.timeIntervalSinceReferenceDate.isFinite,
              value.attemptCount >= 0
        else {
            return nil
        }
        return value
    }

    private func saveLocked(
        _ deliveries: [String: NativeNotificationDelivery]
    ) throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            PersistedState(
                version: 1,
                deliveries: deliveries.values.sorted {
                    $0.createdAt < $1.createdAt
                }
            )
        )
        guard data.count <= Self.maximumStateBytes else {
            throw NativeNotificationOutboxError.capacityReached
        }
        try DurableFileWriter.write(data, to: stateURL)
    }
}
