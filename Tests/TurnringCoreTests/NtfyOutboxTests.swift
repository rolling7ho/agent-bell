import XCTest
@testable import TurnringCore

final class NtfyOutboxTests: XCTestCase {
    func testPersistsPrivateDurableDeliveryAndRemovesAfterSuccess() throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("outbox.json")
        var outbox: NtfyOutbox? = NtfyOutbox(stateURL: stateURL)
        let delivery = makeDelivery(
            id: "delivery-1",
            date: Date().timeIntervalSince1970
        )

        try outbox?.enqueue(delivery)
        XCTAssertEqual(try permissions(at: directory) & 0o777, 0o700)
        XCTAssertEqual(try permissions(at: stateURL) & 0o777, 0o600)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        let deliveries = try XCTUnwrap(
            persisted["deliveries"] as? [[String: Any]]
        )
        XCTAssertNil(deliveries.first?["topic"])
        outbox = nil

        let restored = NtfyOutbox(stateURL: stateURL)
        let restoredDelivery = try XCTUnwrap(restored.allDeliveries().first)
        XCTAssertEqual(restoredDelivery.id, delivery.id)
        XCTAssertEqual(restoredDelivery.message, delivery.message)
        XCTAssertEqual(restoredDelivery.surfaceKey, delivery.surfaceKey)
        XCTAssertEqual(restoredDelivery.state, delivery.state)
        try restored.markSucceeded(id: delivery.id)
        XCTAssertTrue(restored.allDeliveries().isEmpty)
    }

    func testDuplicateDeliveryIDDoesNotCreateSecondPhoneAlert() throws {
        let outbox = NtfyOutbox(
            stateURL: temporaryDirectory().appendingPathComponent("outbox.json")
        )
        let delivery = makeDelivery(id: "stable-sequence", date: 100)

        try outbox.enqueue(delivery)
        try outbox.enqueue(delivery)

        XCTAssertEqual(outbox.allDeliveries().count, 1)
    }

    func testLegacyPlaintextTopicIsRemovedWhenOutboxLoads() throws {
        let stateURL = temporaryDirectory()
            .appendingPathComponent("outbox.json")
        let outbox = NtfyOutbox(stateURL: stateURL)
        try outbox.enqueue(makeDelivery(id: "legacy-topic", date: Date().timeIntervalSince1970))

        var state = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        var deliveries = try XCTUnwrap(
            state["deliveries"] as? [[String: Any]]
        )
        deliveries[0]["topic"] =
            "turnring-legacy-plaintext-topic-secret"
        state["deliveries"] = deliveries
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.sortedKeys]
        ).write(to: stateURL)

        _ = NtfyOutbox(stateURL: stateURL)

        let migrated = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        let migratedDeliveries = try XCTUnwrap(
            migrated["deliveries"] as? [[String: Any]]
        )
        XCTAssertNil(migratedDeliveries.first?["topic"])
    }

    func testFailureBackoffAndDueSelection() throws {
        let outbox = NtfyOutbox(
            stateURL: temporaryDirectory().appendingPathComponent("outbox.json")
        )
        let delivery = makeDelivery(id: "delivery-1", date: 100)
        try outbox.enqueue(delivery)

        XCTAssertEqual(
            outbox.dueDeliveries(at: Date(timeIntervalSince1970: 100)),
            [delivery]
        )
        try outbox.markFailed(
            id: delivery.id,
            at: Date(timeIntervalSince1970: 100)
        )
        XCTAssertTrue(
            outbox.dueDeliveries(at: Date(timeIntervalSince1970: 114)).isEmpty
        )
        XCTAssertEqual(
            outbox.dueDeliveries(at: Date(timeIntervalSince1970: 115)).first?.id,
            delivery.id
        )
        XCTAssertEqual(outbox.allDeliveries().first?.attemptCount, 1)
    }

    func testFailedDeliveryIsDiscardedAfterBoundedAttempts() throws {
        let outbox = NtfyOutbox(
            stateURL: temporaryDirectory().appendingPathComponent("outbox.json")
        )
        let now = Date()
        let delivery = makeDelivery(
            id: "bounded-retry",
            date: now.timeIntervalSince1970
        )
        try outbox.enqueue(delivery)

        for _ in 0..<NtfyOutbox.maximumAttempts {
            try outbox.markFailed(id: delivery.id, at: now)
        }

        XCTAssertTrue(outbox.allDeliveries().isEmpty)
    }

    func testExpiredDeliveryIsDiscardedInsteadOfRetriedForever() throws {
        let outbox = NtfyOutbox(
            stateURL: temporaryDirectory().appendingPathComponent("outbox.json")
        )
        let now = Date()
        let delivery = makeDelivery(
            id: "expired-delivery",
            date: now.addingTimeInterval(
                -NtfyOutbox.maximumDeliveryAge - 1
            ).timeIntervalSince1970
        )
        try outbox.enqueue(delivery)

        XCTAssertTrue(outbox.dueDeliveries(at: now).isEmpty)
        XCTAssertTrue(outbox.allDeliveries().isEmpty)
    }

    func testWallClockRollbackCannotStrandQueuedDelivery() throws {
        let outbox = NtfyOutbox(
            stateURL: temporaryDirectory().appendingPathComponent("outbox.json")
        )
        let delivery = NtfyDelivery(
            id: "clock-shift",
            serverURL: "https://ntfy.sh",
            message: NtfyMessage(
                title: "Turnring",
                message: "Queued",
                priority: .default,
                tags: []
            ),
            surfaceKey: "codexCLI",
            state: .finished,
            createdAt: Date(timeIntervalSince1970: 10_000),
            nextAttemptAt: Date(timeIntervalSince1970: 10_100)
        )
        try outbox.enqueue(delivery)

        XCTAssertEqual(
            outbox.dueDeliveries(
                at: Date(timeIntervalSince1970: 1_000)
            ).first?.id,
            delivery.id
        )
    }

    func testDuplicatePersistedIDsKeepNewestWithoutCrashing() throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("ntfy-outbox.json")
        let now = Date().timeIntervalSince1970
        var older = makeDelivery(id: "turnring-duplicate", date: now - 100)
        var newer = older
        newer.createdAt = Date(timeIntervalSince1970: now)
        newer.nextAttemptAt = newer.createdAt
        newer.message = NtfyMessage(
            title: "Newer",
            message: "Newer",
            priority: .default,
            tags: [],
            sequenceID: newer.id
        )
        older.message = NtfyMessage(
            title: "Older",
            message: "Older",
            priority: .default,
            tags: [],
            sequenceID: older.id
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode([older, newer])
        let deliveries = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        let state: [String: Any] = [
            "version": 1,
            "deliveries": deliveries,
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)

        let outbox = NtfyOutbox(stateURL: stateURL)

        XCTAssertEqual(outbox.allDeliveries().count, 1)
        XCTAssertEqual(outbox.allDeliveries().first?.message.title, "Newer")
    }

    func testOversizedOutboxIsQuarantinedWithoutLoadingIt() throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("ntfy-outbox.json")
        try Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1)
            .write(to: stateURL)

        let outbox = NtfyOutbox(stateURL: stateURL)

        XCTAssertTrue(outbox.allDeliveries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        let files = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        XCTAssertTrue(files.contains {
            $0.hasPrefix("ntfy-outbox.corrupt-")
        })
    }

    func testCorruptOutboxIsQuarantinedWithoutBreakingStartup() throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("outbox.json")
        try Data("not-json".utf8).write(to: stateURL)

        let outbox = NtfyOutbox(stateURL: stateURL)

        XCTAssertTrue(outbox.allDeliveries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("ntfy-outbox.corrupt-") })
    }

    func testOutboxBoundsQueuedDeliveries() throws {
        let outbox = NtfyOutbox(
            stateURL: temporaryDirectory().appendingPathComponent("outbox.json")
        )
        for index in 0..<(NtfyOutbox.maximumDeliveries + 10) {
            try outbox.enqueue(
                makeDelivery(
                    id: "delivery-\(index)",
                    date: TimeInterval(index)
                )
            )
        }

        XCTAssertEqual(
            outbox.allDeliveries().count,
            NtfyOutbox.maximumDeliveries
        )
        XCTAssertNil(
            outbox.allDeliveries().first {
                $0.id == "delivery-0"
            }
        )
    }

    private func makeDelivery(id: String, date: TimeInterval) -> NtfyDelivery {
        let createdAt = Date(timeIntervalSince1970: date)
        return NtfyDelivery(
            id: id,
            serverURL: "https://ntfy.sh",
            message: NtfyMessage(
                title: "Turnring • Test",
                message: "A sanitized test",
                priority: .default,
                tags: [],
                sequenceID: id
            ),
            surfaceKey: "codexDesktop",
            state: .finished,
            createdAt: createdAt
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurnringNtfyTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}
