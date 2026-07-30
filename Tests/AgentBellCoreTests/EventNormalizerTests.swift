import XCTest
@testable import AgentBellCore

final class EventNormalizerTests: XCTestCase {
    func testCodexPromptIsNotPersistedAsConversationTitle() throws {
        let prompt = String(repeating: "A", count: 100) + "NEVER_STORE_THIS_TAIL"
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "thr_123456",
            "turn_id": "turn_987654",
            "cwd": FileManager.default.currentDirectoryPath,
            "permission_mode": "default",
            "approvals_reviewer": "user",
            "prompt": prompt,
            "tool_input": ["command": "secret command"],
        ]

        let event = try EventNormalizer.normalize(
            data: try JSONSerialization.data(withJSONObject: payload),
            provider: .codex,
            origin: OriginMetadata(),
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(event.state, .attention)
        XCTAssertEqual(event.sessionID, "thr_123456")
        XCTAssertEqual(event.turnID, "turn_987654")
        XCTAssertNil(event.displayTitle)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("NEVER_STORE_THIS_TAIL"))
        XCTAssertFalse(encoded.contains("secret command"))
    }

    func testCodexApprovalOnlyNotifiesForManualReviewer() throws {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "thr_123456",
            "turn_id": "turn_987654",
            "cwd": FileManager.default.currentDirectoryPath,
            "permission_mode": "default",
            "tool_name": "Bash",
            "tool_input": ["command": "swift test"],
        ]

        payload["approvals_reviewer"] = "user"
        XCTAssertNoThrow(
            try EventNormalizer.normalize(
                data: JSONSerialization.data(withJSONObject: payload),
                provider: .codex,
                origin: OriginMetadata()
            )
        )

        for reviewer in ["auto_review", "guardian_subagent"] {
            payload["approvals_reviewer"] = reviewer
            XCTAssertThrowsError(
                try EventNormalizer.normalize(
                    data: JSONSerialization.data(withJSONObject: payload),
                    provider: .codex,
                    origin: OriginMetadata()
                )
            ) {
                XCTAssertEqual($0 as? EventNormalizerError, .unsupportedEvent)
            }
        }
    }

    func testCodexFullAccessAndUnknownReviewerDoNotNotify() throws {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "thr_123456",
            "turn_id": "turn_987654",
            "cwd": FileManager.default.currentDirectoryPath,
            "permission_mode": "bypassPermissions",
            "approvals_reviewer": "user",
            "tool_name": "Bash",
            "tool_input": ["command": "swift test"],
        ]

        XCTAssertThrowsError(
            try EventNormalizer.normalize(
                data: JSONSerialization.data(withJSONObject: payload),
                provider: .codex,
                origin: OriginMetadata()
            )
        ) {
            XCTAssertEqual($0 as? EventNormalizerError, .unsupportedEvent)
        }

        payload["permission_mode"] = "default"
        payload.removeValue(forKey: "approvals_reviewer")
        XCTAssertThrowsError(
            try EventNormalizer.normalize(
                data: JSONSerialization.data(withJSONObject: payload),
                provider: .codex,
                origin: OriginMetadata()
            )
        ) {
            XCTAssertEqual($0 as? EventNormalizerError, .unsupportedEvent)
        }
    }

    func testCodexRequestUserInputNeedsAttentionWithQuestionOnly() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "thr_123456",
            "turn_id": "turn_987654",
            "cwd": FileManager.default.currentDirectoryPath,
            "tool_name": "request_user_input",
            "tool_use_id": "call_123",
            "tool_input": [
                "questions": [[
                    "question": "NEVER_STORE_THIS_QUESTION",
                    "options": [["label": "Sensitive answer"]],
                ]],
            ],
        ]

        let event = try EventNormalizer.normalize(
            data: try JSONSerialization.data(withJSONObject: payload),
            provider: .codex,
            origin: OriginMetadata()
        )

        XCTAssertEqual(event.state, .attention)
        XCTAssertEqual(event.hookEventName, "PreToolUse")
        XCTAssertEqual(event.contentPreview, "NEVER_STORE_THIS_QUESTION")
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Sensitive answer"))
    }

    func testClaudePermissionAndInputEventsMapToAttentionPreviews() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let permissionPayload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": "claude-session-123",
            "turn_id": "turn-1",
            "cwd": cwd,
            "tool_name": "Read",
            "tool_input": ["file_path": "\(cwd)/README.md", "content": "NEVER_STORE"],
        ]
        let permission = try EventNormalizer.normalize(
            data: try JSONSerialization.data(withJSONObject: permissionPayload),
            provider: .claude,
            origin: OriginMetadata(hostBundleIdentifier: "com.microsoft.VSCode")
        )
        XCTAssertEqual(permission.state, .attention)
        XCTAssertEqual(
            permission.contentPreview,
            "Claude Code VS Code wants to read_file: README.md"
        )

        let questionPayload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "claude-session-123",
            "turn_id": "turn-1",
            "cwd": cwd,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [[
                    "question": "Does this work?",
                    "options": [["label": "Yes"], ["label": "No"]],
                ]],
            ],
        ]
        let question = try EventNormalizer.normalize(
            data: try JSONSerialization.data(withJSONObject: questionPayload),
            provider: .claude,
            origin: OriginMetadata()
        )
        XCTAssertEqual(question.state, .attention)
        XCTAssertEqual(question.contentPreview, "Does this work?")
        XCTAssertEqual(question.notificationType, "AskUserQuestion")
    }

    func testOtherCodexPreToolUseEventsRemainUnsupported() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "thr_123456",
            "cwd": FileManager.default.currentDirectoryPath,
            "tool_name": "Bash",
            "tool_input": ["command": "echo should-not-be-observed"],
        ]

        XCTAssertThrowsError(
            try EventNormalizer.normalize(
                data: try JSONSerialization.data(withJSONObject: payload),
                provider: .codex,
                origin: OriginMetadata()
            )
        ) { XCTAssertEqual($0 as? EventNormalizerError, .unsupportedEvent) }
    }

    func testStopPreviewIsWhitespaceNormalizedAndBoundedForCustomDisplay() throws {
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "thr_123456",
            "turn_id": "turn_987654",
            "cwd": FileManager.default.currentDirectoryPath,
            "last_assistant_message": "  " + String(repeating: "result \n", count: 20),
        ]

        let event = try EventNormalizer.normalize(
            data: try JSONSerialization.data(withJSONObject: payload),
            provider: .codex,
            origin: OriginMetadata()
        )

        XCTAssertEqual(event.contentPreview?.last, "…")
        XCTAssertEqual(
            event.contentPreview?.dropLast().count,
            AttentionPreviewFormatter.maximumCharacters
        )
        XCTAssertFalse(event.contentPreview?.contains("\n") == true)
    }

    func testStopAndNotificationPreviewsRedactSecrets() throws {
        for (eventName, valueKey, notificationType) in [
            ("Stop", "last_assistant_message", nil),
            ("Notification", "message", "agent_needs_input"),
        ] {
            let payload: [String: Any?] = [
                "hook_event_name": eventName,
                "session_id": "thr_123456",
                "turn_id": "turn_987654",
                "cwd": FileManager.default.currentDirectoryPath,
                "notification_type": notificationType,
                valueKey: "Use API_TOKEN=super-secret-value now",
            ]
            let object = payload.compactMapValues { $0 }

            let event = try EventNormalizer.normalize(
                data: try JSONSerialization.data(withJSONObject: object),
                provider: eventName == "Notification" ? .claude : .codex,
                origin: OriginMetadata()
            )

            XCTAssertFalse(
                event.contentPreview?.contains("super-secret-value") == true
            )
            XCTAssertTrue(event.contentPreview?.contains("••••") == true)
        }
    }

    func testClaudeOfficialEventsMapToExpectedStates() throws {
        let expected: [(String, String?, AgentState)] = [
            ("SessionStart", nil, .started),
            ("UserPromptSubmit", nil, .working),
            ("Notification", "permission_prompt", .attention),
            ("Notification", "agent_needs_input", .attention),
            ("Notification", "idle_prompt", .finished),
            ("Stop", nil, .finished),
            ("StopFailure", nil, .failed),
            ("SessionEnd", nil, .ended),
        ]

        for (eventName, notificationType, state) in expected {
            var payload: [String: Any] = [
                "hook_event_name": eventName,
                "session_id": "claude-session-123",
                "cwd": FileManager.default.currentDirectoryPath,
            ]
            if let notificationType {
                payload["notification_type"] = notificationType
            }
            let event = try EventNormalizer.normalize(
                data: try JSONSerialization.data(withJSONObject: payload),
                provider: .claude,
                origin: OriginMetadata()
            )
            XCTAssertEqual(event.state, state, eventName)
        }
    }

    func testClaudeStopFailureClassifiesRateLimitWithoutRetainingPayload() throws {
        let payload: [String: Any] = [
            "hook_event_name": "StopFailure",
            "session_id": "claude-rate-limit",
            "turn_id": "turn-rate-limit",
            "cwd": FileManager.default.currentDirectoryPath,
            "error": "rate_limit",
            "unrelated_secret": "must-not-be-retained",
        ]

        let event = try EventNormalizer.normalize(
            data: try JSONSerialization.data(withJSONObject: payload),
            provider: .claude,
            origin: OriginMetadata()
        )

        XCTAssertEqual(event.state, .failed)
        XCTAssertEqual(event.notificationType, "rate_limit")
        XCTAssertEqual(event.contentPreview, "Rate limit reached.")
        XCTAssertFalse(event.contentPreview?.contains("must-not-be-retained") == true)
    }

    func testClaudeOfficialStopFailureKindsRemainFailed() throws {
        let expectedTypes: [String: String] = [
            "rate_limit": "rate_limit",
            "overloaded": "overloaded",
            "authentication_failed": "authentication_failed",
            "oauth_org_not_allowed": "authentication_failed",
            "billing_error": "billing_error",
            "invalid_request": "invalid_request",
            "model_not_found": "model_not_found",
            "server_error": "server_error",
            "max_output_tokens": "max_output_tokens",
            "unknown": "unknown",
        ]

        for (providerError, expectedType) in expectedTypes {
            let payload: [String: Any] = [
                "hook_event_name": "StopFailure",
                "session_id": "claude-\(providerError)",
                "cwd": FileManager.default.currentDirectoryPath,
                "error": providerError,
            ]
            let event = try EventNormalizer.normalize(
                data: try JSONSerialization.data(withJSONObject: payload),
                provider: .claude,
                origin: OriginMetadata()
            )

            XCTAssertEqual(event.state, .failed, providerError)
            XCTAssertEqual(event.notificationType, expectedType, providerError)
            XCTAssertFalse(event.contentPreview?.isEmpty == true, providerError)
        }
    }

    func testCodexExplicitNetworkErrorStopIsFailed() throws {
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "codex-network-failure",
            "turn_id": "turn-network",
            "cwd": FileManager.default.currentDirectoryPath,
            "last_assistant_message": "API Error: Network error while streaming",
        ]

        let event = try EventNormalizer.normalize(
            data: try JSONSerialization.data(withJSONObject: payload),
            provider: .codex,
            origin: OriginMetadata()
        )

        XCTAssertEqual(event.state, .failed)
        XCTAssertEqual(event.notificationType, "network_error")
    }

    func testCodexCompletionProseMentioningRateLimitIsStillFinished() throws {
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "codex-success",
            "turn_id": "turn-success",
            "cwd": FileManager.default.currentDirectoryPath,
            "last_assistant_message": "Fixed the rate limit handling and tests pass.",
        ]

        let event = try EventNormalizer.normalize(
            data: try JSONSerialization.data(withJSONObject: payload),
            provider: .codex,
            origin: OriginMetadata()
        )

        XCTAssertEqual(event.state, .finished)
        XCTAssertNil(event.notificationType)
    }

    func testRejectsMalformedAndOversizedPayloads() {
        XCTAssertThrowsError(
            try EventNormalizer.normalize(
                data: Data("not json".utf8),
                provider: .codex,
                origin: OriginMetadata()
            )
        ) { XCTAssertEqual($0 as? EventNormalizerError, .invalidJSON) }

        XCTAssertThrowsError(
            try EventNormalizer.normalize(
                data: Data(repeating: 0, count: EventNormalizer.maximumPayloadBytes + 1),
                provider: .codex,
                origin: OriginMetadata()
            )
        ) { XCTAssertEqual($0 as? EventNormalizerError, .oversizedPayload) }
    }

    func testRejectsInvalidSessionAndWorkingDirectory() throws {
        let invalidSession: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "bad session; rm",
            "cwd": FileManager.default.currentDirectoryPath,
        ]
        XCTAssertThrowsError(
            try EventNormalizer.normalize(
                data: try JSONSerialization.data(withJSONObject: invalidSession),
                provider: .codex,
                origin: OriginMetadata()
            )
        ) { XCTAssertEqual($0 as? EventNormalizerError, .invalidSessionID) }

        let invalidCWD: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "valid-session",
            "cwd": "relative/path",
        ]
        XCTAssertThrowsError(
            try EventNormalizer.normalize(
                data: try JSONSerialization.data(withJSONObject: invalidCWD),
                provider: .codex,
                origin: OriginMetadata()
            )
        ) { XCTAssertEqual($0 as? EventNormalizerError, .invalidWorkingDirectory) }
    }

    func testAcceptsAbsoluteWorkingDirectoryDeletedBeforeHookRuns() throws {
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": "valid-session",
            "cwd": "/deleted/agentbell/project",
        ]

        let event = try EventNormalizer.normalize(
            data: try JSONSerialization.data(withJSONObject: payload),
            provider: .codex,
            origin: OriginMetadata()
        )

        XCTAssertEqual(event.cwd, "/deleted/agentbell/project")
        XCTAssertEqual(event.projectName, "project")
    }
}
