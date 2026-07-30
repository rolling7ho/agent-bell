import Foundation

public struct NtfyDelivery: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var serverURL: String
    public var message: NtfyMessage
    public var surfaceKey: String
    public var state: AgentState
    public var includesDetails: Bool?
    public var createdAt: Date
    public var nextAttemptAt: Date
    public var attemptCount: Int

    public init(
        id: String,
        serverURL: String,
        message: NtfyMessage,
        surfaceKey: String,
        state: AgentState,
        includesDetails: Bool = false,
        createdAt: Date = Date(),
        nextAttemptAt: Date? = nil,
        attemptCount: Int = 0
    ) {
        self.id = id
        self.serverURL = serverURL
        self.message = message
        self.surfaceKey = surfaceKey
        self.state = state
        self.includesDetails = includesDetails
        self.createdAt = createdAt
        self.nextAttemptAt = nextAttemptAt ?? createdAt
        self.attemptCount = min(max(0, attemptCount), 10_000)
    }
}

public final class NtfyOutbox: @unchecked Sendable {
    public static let maximumDeliveries = 200
    public static let maximumAttempts = 8
    public static let maximumDeliveryAge: TimeInterval = 24 * 60 * 60
    private static let maximumStateBytes = 2 * 1_024 * 1_024

    private struct PersistedState: Codable {
        var version: Int
        var deliveries: [NtfyDelivery]
    }

    private let lock = NSLock()
    private let stateURL: URL
    private var deliveriesByID: [String: NtfyDelivery] = [:]

    public init(stateURL: URL = AgentBellPaths.ntfyOutboxFile) {
        self.stateURL = stateURL
        load()
    }

    public func enqueue(_ delivery: NtfyDelivery) throws {
        lock.lock()
        defer { lock.unlock() }
        guard deliveriesByID[delivery.id] == nil else { return }
        deliveriesByID[delivery.id] = delivery
        trimLocked(referenceDate: delivery.createdAt)
        try saveLocked()
    }

    public func dueDeliveries(
        at date: Date = Date(),
        limit: Int = 20
    ) -> [NtfyDelivery] {
        lock.lock()
        defer { lock.unlock() }
        trimLocked(referenceDate: date)
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
        guard deliveriesByID.removeValue(forKey: id) != nil else { return }
        try saveLocked()
    }

    public func markFailed(id: String, at date: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var delivery = deliveriesByID[id] else { return }
        if delivery.attemptCount + 1 >= Self.maximumAttempts {
            deliveriesByID.removeValue(forKey: id)
            try saveLocked()
            return
        }
        delivery.attemptCount = min(
            Self.maximumAttempts,
            delivery.attemptCount >= Self.maximumAttempts
                ? Self.maximumAttempts
                : delivery.attemptCount + 1
        )
        delivery.nextAttemptAt = date.addingTimeInterval(
            retryDelay(after: delivery.attemptCount)
        )
        deliveriesByID[id] = delivery
        try saveLocked()
    }

    public func discard(id: String) throws {
        try markSucceeded(id: id)
    }

    public func discard(
        where shouldDiscard: (NtfyDelivery) -> Bool
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let originalCount = deliveriesByID.count
        deliveriesByID = deliveriesByID.filter {
            !shouldDiscard($0.value)
        }
        guard deliveriesByID.count != originalCount else { return }
        try saveLocked()
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        deliveriesByID.removeAll()
        if FileManager.default.fileExists(atPath: stateURL.path) {
            try FileManager.default.removeItem(at: stateURL)
        }
    }

    public func allDeliveries() -> [NtfyDelivery] {
        lock.lock()
        defer { lock.unlock() }
        return deliveriesByID.values.sorted { $0.createdAt < $1.createdAt }
    }

    private func retryDelay(after attemptCount: Int) -> TimeInterval {
        let delays: [TimeInterval] = [15, 60, 300, 900, 3_600]
        return delays[min(max(1, attemptCount) - 1, delays.count - 1)]
    }

    private func trimLocked(referenceDate: Date) {
        deliveriesByID = deliveriesByID.filter {
            let age = referenceDate.timeIntervalSince($0.value.createdAt)
            return age < Self.maximumDeliveryAge
                && $0.value.attemptCount < Self.maximumAttempts
        }
        guard deliveriesByID.count > Self.maximumDeliveries else { return }
        deliveriesByID = Dictionary(
            uniqueKeysWithValues: deliveriesByID.values
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(Self.maximumDeliveries)
                .map { ($0.id, $0) }
        )
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
        ) else {
            return
        }
        guard data.count <= Self.maximumStateBytes else {
            quarantineCorruptStateLocked()
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(PersistedState.self, from: data) else {
            quarantineCorruptStateLocked()
            return
        }
        deliveriesByID = [:]
        for delivery in state.deliveries {
            guard let validated = validatedLoadedDelivery(delivery) else {
                continue
            }
            if let existing = deliveriesByID[validated.id],
               existing.createdAt >= validated.createdAt
            {
                continue
            }
            deliveriesByID[validated.id] = validated
        }
        trimLocked(referenceDate: Date())
        // Rewrite older state immediately so legacy plaintext topic fields are
        // removed even when no delivery is attempted during this launch.
        try? saveLocked()
    }

    private func validatedLoadedDelivery(
        _ value: NtfyDelivery
    ) -> NtfyDelivery? {
        guard !value.id.isEmpty,
              value.id.utf8.count <= 128,
              value.id.allSatisfy({
                  $0.isLetter || $0.isNumber || "._:-".contains($0)
              }),
              value.state.shouldNotify,
              value.createdAt.timeIntervalSinceReferenceDate.isFinite,
              value.nextAttemptAt.timeIntervalSinceReferenceDate.isFinite
        else {
            return nil
        }
        let sanitizedMessage = NtfyMessage(
            title: value.message.title,
            message: value.message.message,
            priority: value.message.priority,
            tags: value.message.tags,
            sequenceID: value.id
        )
        guard (try? NtfyRequestBuilder.makeRequest(
            serverURL: value.serverURL,
            topic: "agentbell-outbox-validation",
            message: sanitizedMessage
        )) != nil else {
            return nil
        }
        var delivery = value
        delivery.attemptCount = min(
            max(0, value.attemptCount),
            Self.maximumAttempts
        )
        delivery.message = sanitizedMessage
        delivery.surfaceKey = AgentBellSafeText.collapsed(
            value.surfaceKey,
            maximumCharacters: 100
        )
        delivery.includesDetails = value.includesDetails ?? false
        return delivery
    }

    private func quarantineCorruptStateLocked() {
        let corruptURL = stateURL.deletingLastPathComponent()
            .appendingPathComponent("ntfy-outbox.corrupt-\(UUID().uuidString).json")
        try? FileManager.default.moveItem(at: stateURL, to: corruptURL)
    }

    private func saveLocked() throws {
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
                version: 2,
                deliveries: deliveriesByID.values.sorted {
                    $0.createdAt < $1.createdAt
                }
            )
        )
        try data.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
    }
}
