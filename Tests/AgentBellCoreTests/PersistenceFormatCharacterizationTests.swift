import XCTest
@testable import AgentBellCore

final class PersistenceFormatCharacterizationTests: XCTestCase {
    func testEventQueueEncodingKeepsCurrentKeysAndExcludesUnmodeledInput() throws {
        let directory = temporaryDirectory()
        let queueURL = directory.appendingPathComponent("events.jsonl")
        let event = AgentEvent(
            provider: .codex,
            state: .attention,
            hookEventName: "PermissionRequest",
            sessionID: "session-schema",
            turnID: "turn-schema",
            cwd: "/tmp/schema-project",
            projectName: "schema-project",
            timestamp: Date(timeIntervalSince1970: 100),
            notificationType: "Bash",
            displayTitle: "Schema title",
            contentPreview: "Codex CLI wants to run_command: swift test",
            testDisplayName: "Schema surface",
            origin: OriginMetadata(
                agentProcess: ProcessRecord(
                    pid: 101,
                    parentPID: 100,
                    tty: "ttys001",
                    startIdentifier: "process-birth",
                    command: "/opt/homebrew/bin/codex"
                ),
                shellProcess: ProcessRecord(
                    pid: 100,
                    parentPID: 1,
                    tty: "ttys001",
                    startIdentifier: "shell-birth",
                    command: "/bin/zsh"
                ),
                hostProcess: ProcessRecord(
                    pid: 99,
                    parentPID: 1,
                    tty: nil,
                    startIdentifier: "host-birth",
                    command: "/Applications/Terminal.app/Contents/MacOS/Terminal"
                ),
                hostBundleIdentifier: "com.apple.Terminal",
                executablePath: "/opt/homebrew/bin/codex",
                termProgram: "Apple_Terminal",
                cmuxWindowID: "window-1",
                cmuxWorkspaceID: "workspace-1",
                cmuxPaneID: "pane-1",
                cmuxSurfaceID: "surface-1",
                ghosttyTerminalID: "terminal-1"
            )
        )

        try EventQueue.append(event, to: queueURL)

        let line = try XCTUnwrap(
            String(data: Data(contentsOf: queueURL), encoding: .utf8)?
                .split(separator: "\n")
                .first
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "provider",
                "state",
                "hookEventName",
                "sessionID",
                "turnID",
                "cwd",
                "projectName",
                "timestamp",
                "notificationType",
                "displayTitle",
                "contentPreview",
                "testDisplayName",
                "origin",
            ])
        )
        let origin = try XCTUnwrap(object["origin"] as? [String: Any])
        XCTAssertEqual(
            Set(origin.keys),
            Set([
                "agentProcess",
                "shellProcess",
                "hostProcess",
                "hostBundleIdentifier",
                "executablePath",
                "termProgram",
                "cmuxWindowID",
                "cmuxWorkspaceID",
                "cmuxPaneID",
                "cmuxSurfaceID",
                "ghosttyTerminalID",
            ])
        )
        let serialized = String(decoding: Data(line.utf8), as: UTF8.self)
        XCTAssertFalse(serialized.contains("prompt"))
        XCTAssertFalse(serialized.contains("transcript"))
        XCTAssertFalse(serialized.contains("token"))
    }

    func testSessionStoreKeepsVersionThreeEnvelopeAndCurrentSummaryKeys() throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("sessions.json")
        let store = SessionStore(stateURL: stateURL)
        let event = AgentEvent(
            provider: .claude,
            state: .finished,
            hookEventName: "Stop",
            sessionID: "session-schema",
            turnID: "turn-schema",
            cwd: "/tmp/schema-project",
            projectName: "schema-project",
            timestamp: Date(timeIntervalSince1970: 100),
            notificationType: "finished",
            displayTitle: "Schema title",
            contentPreview: "Schema preview",
            origin: OriginMetadata(
                hostBundleIdentifier: "com.microsoft.VSCode"
            )
        )

        _ = store.apply(
            event,
            processedAt: Date(timeIntervalSince1970: 200)
        )

        let root = try jsonObject(at: stateURL)
        XCTAssertEqual(
            Set(root.keys),
            Set(["version", "sessions", "recentDedupeKeys"])
        )
        XCTAssertEqual(root["version"] as? Int, 3)
        let sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
        let summary = try XCTUnwrap(sessions.first)
        XCTAssertEqual(
            Set(summary.keys),
            Set([
                "sessionKey",
                "provider",
                "sessionID",
                "state",
                "cwd",
                "projectName",
                "updatedAt",
                "observedActivityAt",
                "displayTitle",
                "contentPreview",
                "origin",
                "turnID",
                "lastHookEventName",
            ])
        )
        XCTAssertNil(summary["runStartedAt"])
        XCTAssertNil(summary["testDisplayName"])
        let dedupe = try XCTUnwrap(
            root["recentDedupeKeys"] as? [String: Any]
        )
        XCTAssertEqual(dedupe.count, 1)
        XCTAssertNotNil(dedupe[event.deduplicationKey])
    }

    func testNtfyOutboxKeepsVersionTwoSecretFreeEnvelope() throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("ntfy-outbox.json")
        let outbox = NtfyOutbox(stateURL: stateURL)
        let delivery = NtfyDelivery(
            id: "agentbell-schema-delivery",
            serverURL: "https://ntfy.sh",
            message: NtfyMessage(
                title: "AgentBell",
                message: "Schema message",
                priority: .high,
                tags: ["bell"],
                sequenceID: "agentbell-schema-delivery"
            ),
            surfaceKey: "codexCLI",
            state: .attention,
            includesDetails: true,
            createdAt: Date(timeIntervalSince1970: 100),
            nextAttemptAt: Date(timeIntervalSince1970: 115),
            attemptCount: 1
        )

        try outbox.enqueue(delivery)

        let root = try jsonObject(at: stateURL)
        XCTAssertEqual(Set(root.keys), Set(["version", "deliveries"]))
        XCTAssertEqual(root["version"] as? Int, 2)
        let deliveries = try XCTUnwrap(
            root["deliveries"] as? [[String: Any]]
        )
        let persisted = try XCTUnwrap(deliveries.first)
        XCTAssertEqual(
            Set(persisted.keys),
            Set([
                "id",
                "serverURL",
                "message",
                "surfaceKey",
                "state",
                "includesDetails",
                "createdAt",
                "nextAttemptAt",
                "attemptCount",
            ])
        )
        let message = try XCTUnwrap(
            persisted["message"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(message.keys),
            Set(["title", "message", "priority", "tags", "sequenceID"])
        )
        let serialized = String(
            decoding: try Data(contentsOf: stateURL),
            as: UTF8.self
        )
        XCTAssertFalse(serialized.contains("\"topic\""))
        XCTAssertFalse(serialized.contains("accessToken"))
        XCTAssertFalse(serialized.contains("Authorization"))
    }

    func testFocusRequestEncodingKeepsCurrentRoutingSchema() throws {
        let request = FocusRequest(
            requestID: "request-schema",
            provider: .codex,
            sessionID: "session-schema",
            shellPID: 101,
            cwd: "/tmp/schema-project",
            executablePath: "/opt/homebrew/bin/codex",
            action: .resume,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request))
                as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set([
                "requestID",
                "provider",
                "sessionID",
                "shellPID",
                "cwd",
                "executablePath",
                "action",
                "createdAt",
            ])
        )
        XCTAssertEqual(object["provider"] as? String, "codex")
        XCTAssertEqual(object["action"] as? String, "resume")
        XCTAssertNil(object["command"])
        XCTAssertNil(object["arguments"])
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AgentBellPersistenceCharacterization-\(UUID().uuidString)",
                isDirectory: true
            )
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
    }
}
