import Foundation

private enum ReliabilitySmokeError: Error {
    case failed(String)
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw ReliabilitySmokeError.failed(message)
    }
}

@main
private enum TurnringReliabilitySmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TurnringReliabilitySmoke-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try verifyInputQueue(in: root)
        try verifyNativeOutbox(in: root)
        try verifyNativeDeliveryConfirmationPolicy()
        try verifyPhoneOutbox(in: root)
        try verifyCorruptOutboxesFailClosed(in: root)
        try verifyReplayDeliveryIntent(in: root)
        try verifyIntegrationMerge(in: root)
        print("Turnring reliability smoke checks passed.")
    }

    private static func verifyInputQueue(in root: URL) throws {
        let queueURL = root.appendingPathComponent("events.jsonl")
        let processingURL = root.appendingPathComponent("events.processing.jsonl")
        let first = event(sessionID: "first", timestamp: 100)
        let second = event(sessionID: "second", timestamp: 101)
        try EventQueue.append(first, to: queueURL)
        let original = try requireValue(
            EventQueue.claim(from: queueURL, processingURL: processingURL),
            "input queue did not produce a claim"
        )
        try require(original.events == [first], "input queue changed first event")
        try EventQueue.append(second, to: queueURL)
        let replay = try requireValue(
            EventQueue.claim(from: queueURL, processingURL: processingURL),
            "unacknowledged claim disappeared"
        )
        try require(replay.events == [first], "unacknowledged claim did not replay")
        try EventQueue.acknowledge(replay)
        let next = try requireValue(
            EventQueue.claim(from: queueURL, processingURL: processingURL),
            "new event disappeared behind replay"
        )
        try require(next.events == [second], "new event changed after replay")
        try EventQueue.acknowledge(next)
    }

    private static func verifyNativeOutbox(in root: URL) throws {
        let stateURL = root.appendingPathComponent("native-outbox.json")
        let delivery = NativeNotificationDelivery(
            id: "native-finished",
            title: "Codex CLI • Finished",
            body: "Private completion",
            genericTitle: "Codex CLI • Finished",
            genericBody: "Task finished.",
            threadIdentifier: "route",
            routeID: "route",
            containsPrivateDetails: true,
            surfaceKey: "codexCLI",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        var outbox: NativeNotificationOutbox? = NativeNotificationOutbox(
            stateURL: stateURL
        )
        try outbox?.enqueue(delivery)
        outbox = nil
        let restored = NativeNotificationOutbox(stateURL: stateURL)
        try require(restored.allDeliveries() == [delivery], "native intent was not durable")
        for _ in 0..<100 {
            try restored.markFailed(
                id: delivery.id,
                at: Date(timeIntervalSince1970: 200)
            )
        }
        try require(
            restored.allDeliveries().first?.attemptCount == 100,
            "native intent expired during retries"
        )
    }

    private static func verifyNativeDeliveryConfirmationPolicy() throws {
        try require(
            NativeNotificationDeliveryPolicy.disposition(
                isPresentInNotificationCenter: true,
                isDisplayCaptureActive: false
            ) == .acknowledge,
            "confirmed native delivery was not acknowledged"
        )
        try require(
            NativeNotificationDeliveryPolicy.disposition(
                isPresentInNotificationCenter: false,
                isDisplayCaptureActive: false
            ) == .retry,
            "unretained native delivery was discarded"
        )
        try require(
            NativeNotificationDeliveryPolicy.disposition(
                isPresentInNotificationCenter: true,
                isDisplayCaptureActive: true
            ) == .retry,
            "capture-muted native delivery was discarded"
        )
    }

    private static func verifyPhoneOutbox(in root: URL) throws {
        let stateURL = root.appendingPathComponent("phone-outbox.json")
        let detailed = NtfyMessage(
            title: "Private title",
            message: "Private completion",
            priority: .default,
            tags: [],
            sequenceID: "phone-finished"
        )
        let generic = NtfyMessage(
            title: "Codex CLI • Finished",
            message: "Task finished.",
            priority: .default,
            tags: [],
            sequenceID: "phone-finished"
        )
        let delivery = NtfyDelivery(
            id: "phone-finished",
            serverURL: "https://ntfy.sh",
            message: detailed,
            genericMessage: generic,
            surfaceKey: "codexCLI",
            state: .finished,
            includesDetails: true,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let outbox = NtfyOutbox(stateURL: stateURL)
        try outbox.enqueue(delivery)
        for _ in 0..<100 {
            try outbox.markFailed(
                id: delivery.id,
                at: Date(timeIntervalSince1970: 200)
            )
        }
        let restored = NtfyOutbox(stateURL: stateURL)
        try require(
            restored.allDeliveries().first?.attemptCount == 100,
            "phone intent expired during retries"
        )
        try require(
            restored.allDeliveries().first?.genericMessage == generic,
            "phone privacy fallback was not durable"
        )
    }

    private static func verifyReplayDeliveryIntent(in root: URL) throws {
        let store = SessionStore(
            stateURL: root.appendingPathComponent("sessions.json")
        )
        let completion = AgentEvent(
            provider: .codex,
            state: .finished,
            hookEventName: "SessionEnd",
            sessionID: "replayed-completion",
            turnID: "turn",
            cwd: "/tmp/project",
            projectName: "Project",
            timestamp: Date(timeIntervalSince1970: 300),
            notificationType: nil,
            origin: OriginMetadata()
        )
        let first = store.apply(completion, processedAt: completion.timestamp)
        let replay = store.apply(
            completion,
            processedAt: completion.timestamp.addingTimeInterval(1)
        )
        try require(first.shouldEnsureDelivery, "first completion had no delivery intent")
        try require(replay.shouldEnsureDelivery, "replay lost its delivery intent")
        try require(!replay.shouldNotify, "replay created a duplicate presentation intent")
    }

    private static func verifyCorruptOutboxesFailClosed(
        in root: URL
    ) throws {
        let nativeURL = root.appendingPathComponent("native-corrupt.json")
        let phoneURL = root.appendingPathComponent("phone-corrupt.json")
        try Data("not-json".utf8).write(to: nativeURL)
        try Data("not-json".utf8).write(to: phoneURL)
        let native = NativeNotificationOutbox(stateURL: nativeURL)
        let phone = NtfyOutbox(stateURL: phoneURL)
        try require(!native.isOperational, "corrupt native outbox did not fail closed")
        try require(!phone.isOperational, "corrupt phone outbox did not fail closed")
        try require(
            FileManager.default.fileExists(atPath: nativeURL.path),
            "corrupt native evidence was deleted"
        )
        try require(
            FileManager.default.fileExists(atPath: phoneURL.path),
            "corrupt phone evidence was deleted"
        )
    }

    private static func verifyIntegrationMerge(in root: URL) throws {
        let configURL = root.appendingPathComponent("codex-hooks.json")
        let launcherURL = root.appendingPathComponent("Turnring Hook")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcherURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: launcherURL.path
        )
        let existing: [String: Any] = [
            "notify": ["/usr/bin/true"],
            "hooks": [String: Any](),
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: configURL)
        let installer = ConfigurationInstaller(
            hookExecutablePath: launcherURL.path,
            vscodeVSIXPath: nil
        )
        _ = try installer.mergeHooks(at: configURL, provider: .codex)
        let rootObject = try requireValue(
            JSONSerialization.jsonObject(with: Data(contentsOf: configURL))
                as? [String: Any],
            "installed hook configuration was not an object"
        )
        try require(
            rootObject["notify"] as? [String] == ["/usr/bin/true"],
            "integration merge replaced an unrelated notify command"
        )
        let hooks = try requireValue(
            rootObject["hooks"] as? [String: Any],
            "integration merge did not create hooks"
        )
        try require(hooks.count == 6, "Codex integration did not install six hooks")
        for value in hooks.values {
            let groups = try requireValue(
                value as? [[String: Any]],
                "hook event did not contain handler groups"
            )
            let handlers = try requireValue(
                groups.last?["hooks"] as? [[String: Any]],
                "hook group did not contain handlers"
            )
            try require(
                handlers.last?["timeout"] as? Int == 10,
                "hook timeout was not hardened to 10 seconds"
            )
        }
        try require(
            installer.missingHookEvents(at: configURL, provider: .codex).isEmpty,
            "freshly installed hooks failed their own health check"
        )
    }

    private static func event(
        sessionID: String,
        timestamp: TimeInterval
    ) -> AgentEvent {
        AgentEvent(
            provider: .codex,
            state: .working,
            hookEventName: "UserPromptSubmit",
            sessionID: sessionID,
            turnID: "turn-\(sessionID)",
            cwd: "/tmp/project",
            projectName: "Project",
            timestamp: Date(timeIntervalSince1970: timestamp),
            notificationType: nil,
            origin: OriginMetadata()
        )
    }

    private static func requireValue<T>(
        _ value: T?,
        _ message: String
    ) throws -> T {
        guard let value else {
            throw ReliabilitySmokeError.failed(message)
        }
        return value
    }
}
