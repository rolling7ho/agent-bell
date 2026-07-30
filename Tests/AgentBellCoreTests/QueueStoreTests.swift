import XCTest
@testable import AgentBellCore

final class QueueStoreTests: XCTestCase {
    func testQueueRoundTripUsesPrivatePermissionsAndDrainsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBellQueueTests-\(UUID().uuidString)", isDirectory: true)
        let queueURL = directory.appendingPathComponent("events.jsonl")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let event = AgentEvent(
            provider: .codex,
            state: .working,
            hookEventName: "UserPromptSubmit",
            sessionID: "session-123",
            turnID: "turn-123",
            cwd: FileManager.default.currentDirectoryPath,
            projectName: "Project",
            timestamp: Date(timeIntervalSince1970: 100),
            notificationType: nil,
            origin: OriginMetadata()
        )

        try EventQueue.append(event, to: queueURL)
        let directoryMode = try permissions(at: directory)
        let queueMode = try permissions(at: queueURL)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(queueMode & 0o777, 0o600)
        XCTAssertEqual(try EventQueue.drain(from: queueURL), [event])
        XCTAssertTrue(try EventQueue.drain(from: queueURL).isEmpty)
    }

    func testUnacknowledgedClaimReplaysBeforeNewEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBellQueueTests-\(UUID().uuidString)", isDirectory: true)
        let queueURL = directory.appendingPathComponent("events.jsonl")
        let processingURL = directory.appendingPathComponent("events.processing.jsonl")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let first = event(sessionID: "first", timestamp: 100)
        let second = event(sessionID: "second", timestamp: 101)
        try EventQueue.append(first, to: queueURL)
        let originalClaim = try XCTUnwrap(
            EventQueue.claim(from: queueURL, processingURL: processingURL)
        )
        XCTAssertEqual(originalClaim.events, [first])

        try EventQueue.append(second, to: queueURL)
        let replayedClaim = try XCTUnwrap(
            EventQueue.claim(from: queueURL, processingURL: processingURL)
        )
        XCTAssertEqual(replayedClaim.events, [first])
        try EventQueue.acknowledge(replayedClaim)

        let nextClaim = try XCTUnwrap(
            EventQueue.claim(from: queueURL, processingURL: processingURL)
        )
        XCTAssertEqual(nextClaim.events, [second])
        try EventQueue.acknowledge(nextClaim)
        XCTAssertNil(try EventQueue.claim(from: queueURL, processingURL: processingURL))
    }

    func testMalformedAndPartialLinesDoNotPreventValidEventsFromDraining() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentBellQueueTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let queueURL = directory.appendingPathComponent("events.jsonl")
        let processingURL = directory.appendingPathComponent("events.processing.jsonl")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event(sessionID: "valid", timestamp: 100))
        data.append(Data("\n{malformed}\n{\"partial\":".utf8))
        try data.write(to: processingURL)

        let claim = try XCTUnwrap(
            EventQueue.claim(from: queueURL, processingURL: processingURL)
        )

        XCTAssertEqual(claim.events.map(\.sessionID), ["valid"])
        try EventQueue.acknowledge(claim)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: processingURL.path)
        )
    }

    func testConcurrentHookWritersProduceCompleteQueueRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentBellQueueTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let queueURL = directory.appendingPathComponent("events.jsonl")
        let processingURL = directory.appendingPathComponent("processing.jsonl")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let errors = LockedErrors()

        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                try EventQueue.append(
                    AgentEvent(
                        provider: .codex,
                        state: .working,
                        hookEventName: "UserPromptSubmit",
                        sessionID: "concurrent-\(index)",
                        turnID: "turn-\(index)",
                        cwd: FileManager.default.currentDirectoryPath,
                        projectName: "Project",
                        timestamp: Date(
                            timeIntervalSince1970: TimeInterval(index)
                        ),
                        notificationType: nil,
                        origin: OriginMetadata()
                    ),
                    to: queueURL
                )
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        XCTAssertTrue(errors.isEmpty)
        let claim = try XCTUnwrap(
            EventQueue.claim(
                from: queueURL,
                processingURL: processingURL
            )
        )
        XCTAssertEqual(Set(claim.events.map(\.sessionID)).count, 40)
    }

    private func event(sessionID: String, timestamp: TimeInterval) -> AgentEvent {
        AgentEvent(
            provider: .codex,
            state: .working,
            hookEventName: "UserPromptSubmit",
            sessionID: sessionID,
            turnID: "turn-\(sessionID)",
            cwd: FileManager.default.currentDirectoryPath,
            projectName: "Project",
            timestamp: Date(timeIntervalSince1970: timestamp),
            notificationType: nil,
            origin: OriginMetadata()
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty
    }

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
