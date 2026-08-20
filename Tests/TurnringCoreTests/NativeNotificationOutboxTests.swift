import XCTest
@testable import TurnringCore

final class NativeNotificationOutboxTests: XCTestCase {
    func testPersistsPrivateDeliveryUntilNotificationCenterConfirmsIt() throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("native-outbox.json")
        var outbox: NativeNotificationOutbox? = NativeNotificationOutbox(
            stateURL: stateURL
        )
        let delivery = makeDelivery(id: "completion-1")

        try outbox?.enqueue(delivery)
        XCTAssertEqual(try permissions(at: directory) & 0o777, 0o700)
        XCTAssertEqual(try permissions(at: stateURL) & 0o777, 0o600)
        outbox = nil

        let restored = NativeNotificationOutbox(stateURL: stateURL)
        XCTAssertTrue(restored.isOperational)
        XCTAssertEqual(restored.allDeliveries(), [delivery])
        try restored.markSucceeded(id: delivery.id)
        XCTAssertTrue(restored.allDeliveries().isEmpty)
        XCTAssertTrue(
            NativeNotificationOutbox(stateURL: stateURL)
                .allDeliveries().isEmpty
        )
    }

    func testDeliveryPolicyRetriesAcceptedButUnretainedNotifications() {
        XCTAssertEqual(
            NativeNotificationDeliveryPolicy.disposition(
                isPresentInNotificationCenter: false,
                isDisplayCaptureActive: false
            ),
            .retry
        )
    }

    func testDeliveryPolicyRetriesNotificationsMutedDuringDisplayCapture() {
        XCTAssertEqual(
            NativeNotificationDeliveryPolicy.disposition(
                isPresentInNotificationCenter: true,
                isDisplayCaptureActive: true
            ),
            .retry
        )
    }

    func testDeliveryPolicyAcknowledgesConfirmedUnsuppressedNotification() {
        XCTAssertEqual(
            NativeNotificationDeliveryPolicy.disposition(
                isPresentInNotificationCenter: true,
                isDisplayCaptureActive: false
            ),
            .acknowledge
        )
    }

    func testDuplicateIDIsIdempotentAcrossQueueReplay() throws {
        let outbox = NativeNotificationOutbox(
            stateURL: temporaryDirectory().appendingPathComponent("outbox.json")
        )
        let delivery = makeDelivery(id: "stable-completion")

        try outbox.enqueue(delivery)
        try outbox.enqueue(delivery)

        XCTAssertEqual(outbox.allDeliveries(), [delivery])
    }

    func testFailuresBackOffWithoutDiscardingDelivery() throws {
        let outbox = NativeNotificationOutbox(
            stateURL: temporaryDirectory().appendingPathComponent("outbox.json")
        )
        let delivery = makeDelivery(id: "retry-forever")
        let now = Date(timeIntervalSince1970: 100)
        try outbox.enqueue(delivery)

        for _ in 0..<100 {
            try outbox.markFailed(id: delivery.id, at: now)
        }

        XCTAssertEqual(outbox.allDeliveries().count, 1)
        XCTAssertEqual(outbox.allDeliveries().first?.attemptCount, 100)
    }

    func testCorruptStateFailsClosedWithoutDeletingEvidence() throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("outbox.json")
        try Data("not-json".utf8).write(to: stateURL)

        let outbox = NativeNotificationOutbox(stateURL: stateURL)

        XCTAssertFalse(outbox.isOperational)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertThrowsError(try outbox.enqueue(makeDelivery(id: "new"))) {
            XCTAssertEqual(
                $0 as? NativeNotificationOutboxError,
                .unavailable
            )
        }
    }

    private func makeDelivery(id: String) -> NativeNotificationDelivery {
        NativeNotificationDelivery(
            id: id,
            title: "Codex CLI • Finished",
            body: "Completed the private task.",
            genericTitle: "Codex CLI • Finished",
            genericBody: "Task finished.",
            threadIdentifier: "route",
            routeID: "route",
            containsPrivateDetails: true,
            surfaceKey: "codexCLI",
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TurnringNativeOutboxTests-\(UUID().uuidString)"
            )
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
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}
