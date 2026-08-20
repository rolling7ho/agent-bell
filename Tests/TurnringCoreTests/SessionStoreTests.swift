import XCTest
@testable import TurnringCore

final class SessionStoreTests: XCTestCase {
    func testDeduplicationSurvivesStoreRestartForQueueReplay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurnringSessionTests-\(UUID().uuidString)")
        let stateURL = directory.appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = AgentEvent(
            provider: .codex,
            state: .finished,
            hookEventName: "Stop",
            sessionID: "persisted-dedupe",
            turnID: "turn-1",
            cwd: FileManager.default.currentDirectoryPath,
            projectName: "Project",
            timestamp: Date(timeIntervalSince1970: 100),
            notificationType: nil,
            origin: OriginMetadata()
        )

        var store: SessionStore? = SessionStore(stateURL: stateURL)
        XCTAssertTrue(store?.apply(event).shouldNotify == true)
        store = nil

        let restored = SessionStore(stateURL: stateURL)
        XCTAssertFalse(restored.apply(event).shouldNotify)
    }

    func testDuplicateSuppressionAndClaudeIdleStopCoalescing() throws {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        let base = event(state: .attention, eventName: "Notification", turnID: "turn-1")

        XCTAssertTrue(store.apply(base).shouldNotify)
        XCTAssertFalse(store.apply(base).shouldNotify)

        let nextTurn = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-2",
            date: Date(timeIntervalSince1970: 190)
        )
        _ = store.apply(nextTurn)
        let idle = event(
            state: .finished,
            eventName: "Notification",
            turnID: "turn-2",
            notificationType: "idle_prompt",
            date: Date(timeIntervalSince1970: 200)
        )
        let stop = event(
            state: .finished,
            eventName: "Stop",
            turnID: "turn-2",
            date: Date(timeIntervalSince1970: 250)
        )
        XCTAssertTrue(store.apply(idle).shouldNotify)
        XCTAssertFalse(store.apply(stop).shouldNotify)
    }

    func testDifferentApprovalActionsInSameTurnEachNotifyButReplaysDoNot() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        var read = event(
            state: .attention,
            eventName: "PermissionRequest",
            turnID: "turn-approval"
        )
        read.contentPreview = "Claude Code CLI wants permission to read a file: README.md."
        var command = read
        command.contentPreview = "Claude Code CLI wants permission to run a command: npm test."

        XCTAssertTrue(store.apply(read).shouldNotify)
        XCTAssertTrue(store.apply(command).shouldNotify)
        XCTAssertFalse(store.apply(read).shouldNotify)
    }

    func testUnexpectedExitOnlyMarksActiveSessionFailed() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        let working = event(state: .working, eventName: "UserPromptSubmit", turnID: "turn-1")
        _ = store.apply(working)

        XCTAssertEqual(store.markUnexpectedExit(sessionKey: working.sessionKey)?.state, .failed)
        XCTAssertNil(store.markUnexpectedExit(sessionKey: working.sessionKey))
    }

    func testUnexpectedExitReplacesStaleAttentionPreview() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        var attention = event(
            state: .attention,
            eventName: "PermissionRequest",
            turnID: "turn-1"
        )
        attention.contentPreview = "Claude Code CLI wants permission to run a command: npm test."
        _ = store.apply(attention)

        let failed = store.markUnexpectedExit(
            sessionKey: attention.sessionKey,
            at: Date(timeIntervalSince1970: 101)
        )

        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(
            failed?.contentPreview,
            "Agent process exited before completing."
        )
        XCTAssertEqual(failed?.lastHookEventName, "UnexpectedExit")
    }

    func testFinishedStateIncludesElapsedTurnDuration() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        let started = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-duration",
            date: Date(timeIntervalSince1970: 100)
        )
        _ = store.apply(started)
        let finished = event(
            state: .finished,
            eventName: "Stop",
            turnID: "turn-duration",
            date: Date(timeIntervalSince1970: 1_222)
        )

        let summary = store.apply(finished).summary

        XCTAssertEqual(summary.formattedElapsedDuration, "18m 42s")
        XCTAssertEqual(
            summary.formattedTitle,
            "Claude Code CLI • Untitled task (18m 42s)"
        )
        XCTAssertEqual(summary.dashboardStateName, "Finished (18m 42s)")
        XCTAssertEqual(
            summary.genericNotificationTitle,
            "Claude Code CLI • Finished (18m 42s)"
        )
        XCTAssertEqual(summary.genericNotificationBody, "Task finished.")
    }

    func testTerminalOnlyEventDoesNotInventAZeroSecondDuration() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        let summary = store.apply(
            event(
                state: .finished,
                eventName: "Stop",
                turnID: "turn-terminal-only"
            )
        ).summary

        XCTAssertNil(summary.formattedElapsedDuration)
        XCTAssertEqual(summary.formattedTitle, "Claude Code CLI • Untitled task")
        XCTAssertEqual(summary.dashboardStateName, "Finished")
        XCTAssertEqual(
            summary.genericNotificationTitle,
            "Claude Code CLI • Finished"
        )
    }

    func testGenericPresentationSpecifiesQuestionsPlansPermissionsAndLimits() {
        let cases: [(String, AgentState, String, String)] = [
            ("question", .attention, "Question", "Open Claude Code CLI to answer."),
            ("plan_approval", .attention, "Plan approval", "Approve or reject the proposed plan."),
            ("permission_request", .attention, "Permission", "Approve or deny the requested action."),
            ("agent_needs_input", .attention, "Input needed", "Open Claude Code CLI to continue."),
            ("rate_limit", .failed, "Usage limit", "Usage limit reached. Try again after it resets."),
            ("max_output_tokens", .failed, "Output limit", "The task reached its output limit."),
        ]

        for (type, state, status, body) in cases {
            let summary = SessionSummary(
                event: event(
                    state: state,
                    eventName: state == .attention ? "PreToolUse" : "StopFailure",
                    turnID: "turn-\(type)",
                    notificationType: type
                )
            )
            XCTAssertEqual(summary.dashboardStateName, status, type)
            XCTAssertEqual(
                summary.genericNotificationTitle,
                "Claude Code CLI • \(status)",
                type
            )
            XCTAssertEqual(summary.genericNotificationBody, body, type)
        }
    }

    func testClaudeRotatedSessionIDInheritsSameProcessRunStart() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        let process = ProcessRecord(
            pid: 912,
            parentPID: 100,
            tty: "ttys001",
            startIdentifier: "claude-process-birth",
            command: "/usr/local/bin/claude"
        )
        var working = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-original",
            date: Date(timeIntervalSince1970: 100)
        )
        working.sessionID = "claude-session-original"
        working.origin.agentProcess = process
        _ = store.apply(working)

        var finished = event(
            state: .finished,
            eventName: "Stop",
            turnID: "turn-rotated",
            date: Date(timeIntervalSince1970: 142)
        )
        finished.sessionID = "claude-session-rotated"
        finished.displayTitle = "Implement website"
        finished.contentPreview = "Implemented and verified the website."
        finished.origin.agentProcess = process

        let summary = store.apply(finished).summary

        XCTAssertEqual(summary.formattedElapsedDuration, "42s")
        XCTAssertEqual(
            summary.formattedTitle,
            "Claude Code CLI • Implement website (42s)"
        )
        XCTAssertEqual(
            summary.notificationBody,
            "Implemented and verified the website."
        )
    }

    func testRotatedSessionDoesNotInheritStartFromReusedPID() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        var working = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-original",
            date: Date(timeIntervalSince1970: 100)
        )
        working.sessionID = "claude-session-original"
        working.origin.agentProcess = ProcessRecord(
            pid: 912,
            parentPID: 100,
            tty: nil,
            startIdentifier: "old-process-birth",
            command: "/usr/local/bin/claude"
        )
        _ = store.apply(working)

        var finished = event(
            state: .finished,
            eventName: "Stop",
            turnID: "turn-new",
            date: Date(timeIntervalSince1970: 142)
        )
        finished.sessionID = "claude-session-new"
        finished.origin.agentProcess = ProcessRecord(
            pid: 912,
            parentPID: 100,
            tty: nil,
            startIdentifier: "new-process-birth",
            command: "/usr/local/bin/claude"
        )

        let summary = store.apply(finished).summary

        XCTAssertNil(summary.formattedElapsedDuration)
        XCTAssertFalse(summary.formattedTitle.contains("(0s)"))
    }

    func testPersistedTerminalZeroDurationIsDiscarded() throws {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        var summary = SessionSummary(
            event: event(
                state: .finished,
                eventName: "Stop",
                turnID: "turn-persisted-zero",
                date: Date(timeIntervalSince1970: 100)
            )
        )
        summary.runStartedAt = summary.updatedAt
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([summary]).write(to: stateURL, options: .atomic)

        let restored = SessionStore(stateURL: stateURL)
            .session(provider: .claude, sessionID: summary.sessionID)

        XCTAssertNil(restored?.formattedElapsedDuration)
        XCTAssertFalse(restored?.formattedTitle.contains("(0s)") == true)
    }

    func testSubsecondDurationUsesLessThanOneSecondLabel() {
        var summary = SessionSummary(
            event: event(
                state: .working,
                eventName: "UserPromptSubmit",
                turnID: "turn-subsecond",
                date: Date(timeIntervalSince1970: 100)
            )
        )
        summary.apply(
            event(
                state: .finished,
                eventName: "Stop",
                turnID: "turn-subsecond",
                date: Date(timeIntervalSince1970: 100.5)
            )
        )

        XCTAssertEqual(summary.formattedElapsedDuration, "<1s")
        XCTAssertTrue(summary.formattedTitle.hasSuffix("(<1s)"))
    }

    func testHistoryRetentionExpiresOnlyTerminalAndTestEntries() {
        let now = Date(timeIntervalSince1970: 10_000)
        let oldDate = now.addingTimeInterval(-1_801)
        var finished = SessionSummary(
            event: event(
                state: .finished,
                eventName: "Stop",
                turnID: "finished",
                date: oldDate
            )
        )
        finished.sessionID = "finished-session"
        finished.sessionKey = "claude:finished-session"

        var failed = SessionSummary(
            event: event(
                state: .failed,
                eventName: "StopFailure",
                turnID: "failed",
                date: oldDate
            )
        )
        failed.sessionID = "failed-session"
        failed.sessionKey = "claude:failed-session"

        var attention = SessionSummary(
            event: event(
                state: .attention,
                eventName: "PermissionRequest",
                turnID: "attention",
                date: oldDate
            )
        )
        attention.sessionID = "attention-session"
        attention.sessionKey = "claude:attention-session"

        var test = attention
        test.sessionID = "test-session"
        test.sessionKey = "claude:test-session"
        test.testDisplayName = "Turnring"

        var recent = finished
        recent.sessionID = "recent-session"
        recent.sessionKey = "claude:recent-session"
        recent.updatedAt = now.addingTimeInterval(-1_799)

        let expired = SessionHistoryRetentionPolicy.expiredSessions(
            from: [finished, failed, attention, test, recent],
            at: now,
            retention: 1_800
        )

        XCTAssertEqual(
            Set(expired.map(\.sessionID)),
            Set(["finished-session", "failed-session", "test-session"])
        )
    }

    func testHistoryRetentionBoundsCustomIntervals() {
        XCTAssertEqual(
            SessionHistoryRetentionPolicy.clampedRetention(0),
            SessionHistoryRetentionPolicy.minimumRetention
        )
        XCTAssertEqual(
            SessionHistoryRetentionPolicy.clampedRetention(
                30 * 24 * 60 * 60
            ),
            SessionHistoryRetentionPolicy.maximumRetention
        )
    }

    func testDesktopDurationThresholdRequiresObservedMinimum() {
        let started = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-threshold",
            date: Date(timeIntervalSince1970: 100)
        )
        var summary = SessionSummary(event: started)
        summary.apply(
            event(
                state: .finished,
                eventName: "Stop",
                turnID: "turn-threshold",
                date: Date(timeIntervalSince1970: 129)
            )
        )

        XCTAssertFalse(
            DesktopNotificationThresholdPolicy.shouldNotify(
                for: summary,
                minimumDuration: 30
            )
        )
        XCTAssertTrue(
            DesktopNotificationThresholdPolicy.shouldNotify(
                for: summary,
                minimumDuration: 0
            )
        )

        summary.updatedAt = Date(timeIntervalSince1970: 130)
        XCTAssertTrue(
            DesktopNotificationThresholdPolicy.shouldNotify(
                for: summary,
                minimumDuration: 30
            )
        )
    }

    func testDesktopThresholdSuppressesSessionWithoutKnownDuration() {
        let summary = SessionSummary(
            event: event(
                state: .finished,
                eventName: "Stop",
                turnID: "turn-no-start"
            )
        )

        XCTAssertFalse(
            DesktopNotificationThresholdPolicy.shouldNotify(
                for: summary,
                minimumDuration: 30
            )
        )
    }

    func testCodexBundleIDWinsOverLegacyChatGPTExecutablePath() {
        let codexHost = ProcessRecord(
            pid: 10,
            parentPID: 1,
            tty: nil,
            startIdentifier: "codex-birth",
            command: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
        )
        let claudeHost = ProcessRecord(
            pid: 11,
            parentPID: 1,
            tty: nil,
            startIdentifier: "claude-birth",
            command: "/Applications/Claude.app/Contents/MacOS/Claude"
        )
        var codex = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "codex"
        )
        codex.provider = .codex
        codex.origin = OriginMetadata(
            hostProcess: codexHost,
            hostBundleIdentifier: "com.openai.codex"
        )
        var claude = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "claude"
        )
        claude.origin = OriginMetadata(
            hostProcess: claudeHost,
            hostBundleIdentifier: "com.anthropic.claudefordesktop"
        )

        XCTAssertEqual(
            SessionSummary(event: codex).appDisplayName,
            "Codex Desktop"
        )
        XCTAssertEqual(
            SessionSummary(event: claude).appDisplayName,
            "Claude Desktop"
        )
    }

    func testPresentationConsolidatesRotatedSessionIDsForSameProcess() {
        var ended = event(
            state: .ended,
            eventName: "SessionEnd",
            turnID: nil,
            date: Date(timeIntervalSince1970: 100)
        )
        ended.sessionID = "rotated-old"
        ended.origin.agentProcess = ProcessRecord(
            pid: 123,
            parentPID: 1,
            tty: nil,
            startIdentifier: "same-birth",
            command: "claude"
        )
        var working = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-current",
            date: Date(timeIntervalSince1970: 200)
        )
        working.sessionID = "rotated-current"
        working.origin = ended.origin
        var endedSummary = SessionSummary(event: ended)
        endedSummary.observedActivityAt = Date(timeIntervalSince1970: 90)

        let rows = SessionPresentation.rows(
            from: [endedSummary, SessionSummary(event: working)]
        )

        XCTAssertEqual(rows.map(\.sessionID), ["rotated-current"])
        XCTAssertTrue(
            SessionPresentation.representsSameInstance(
                endedSummary,
                SessionSummary(event: working)
            )
        )
    }

    func testPresentationHidesLifecycleOnlySessions() {
        let started = SessionSummary(
            event: event(
                state: .started,
                eventName: "SessionStart",
                turnID: nil
            )
        )
        let ended = SessionSummary(
            event: event(
                state: .ended,
                eventName: "SessionEnd",
                turnID: nil,
                date: Date(timeIntervalSince1970: 101)
            )
        )

        XCTAssertTrue(SessionPresentation.rows(from: [started, ended]).isEmpty)
    }

    func testPresentationKeepsPidReuseWithDifferentBirthIdentifiersSeparate() {
        var first = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-1"
        )
        first.sessionID = "first"
        first.origin.agentProcess = ProcessRecord(
            pid: 123,
            parentPID: 1,
            tty: nil,
            startIdentifier: "birth-1",
            command: "claude"
        )
        var second = first
        second.sessionID = "second"
        second.origin.agentProcess?.startIdentifier = "birth-2"

        XCTAssertEqual(
            SessionPresentation.rows(
                from: [SessionSummary(event: first), SessionSummary(event: second)]
            ).count,
            2
        )
    }

    func testSingleSessionCanBeRemovedWithoutClearingHistory() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        var first = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-1"
        )
        first.sessionID = "session-first"
        var second = first
        second.sessionID = "session-second"
        _ = store.apply(first)
        _ = store.apply(second)

        XCTAssertTrue(store.remove(sessionKey: first.sessionKey))
        XCTAssertFalse(store.remove(sessionKey: first.sessionKey))
        XCTAssertNil(store.session(provider: .claude, sessionID: "session-first"))
        XCTAssertNotNil(store.session(provider: .claude, sessionID: "session-second"))
    }

    func testTitlelessSessionDoesNotExposeGeneratedProjectBasename() {
        let summary = SessionSummary(
            event: AgentEvent(
                provider: .codex,
                state: .started,
                hookEventName: "SessionStart",
                sessionID: "session-123",
                turnID: nil,
                cwd: FileManager.default.currentDirectoryPath,
                projectName: "cre",
                timestamp: Date(),
                notificationType: nil,
                origin: OriginMetadata()
            )
        )

        XCTAssertEqual(summary.formattedTitle, "Codex CLI • Untitled task")
        XCTAssertFalse(summary.formattedTitle.contains("cre"))
    }

    func testAllActiveSessionsAreRetainedBeyondDashboardHistoryLimit() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        for index in 0..<60 {
            var value = event(
                state: .working,
                eventName: "UserPromptSubmit",
                turnID: "turn-\(index)",
                date: Date(timeIntervalSince1970: TimeInterval(index))
            )
            value.sessionID = "session-\(index)"
            _ = store.apply(value)
        }
        XCTAssertEqual(store.allSessions().count, 60)
    }

    func testInactiveHistoryIsLimitedToFiftySessions() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        for index in 0..<60 {
            var value = event(
                state: .finished,
                eventName: "Stop",
                turnID: "turn-\(index)",
                date: Date(timeIntervalSince1970: TimeInterval(index))
            )
            value.sessionID = "session-\(index)"
            _ = store.apply(value)
        }
        XCTAssertEqual(store.allSessions().count, 50)
    }

    func testDelayedTerminalEventFromOldTurnCannotRegressCurrentTurn() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        let current = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-new",
            date: Date(timeIntervalSince1970: 200)
        )
        _ = store.apply(current)
        let delayed = event(
            state: .finished,
            eventName: "Stop",
            turnID: "turn-old",
            date: Date(timeIntervalSince1970: 100)
        )

        let result = store.apply(delayed)

        XCTAssertEqual(result.summary.state, .working)
        XCTAssertEqual(result.summary.turnID, "turn-new")
        XCTAssertFalse(result.shouldNotify)
    }

    func testDelayedClaudeIdleEventFromOldTurnCannotRegressCurrentTurn() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        let current = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-new",
            date: Date(timeIntervalSince1970: 200)
        )
        _ = store.apply(current)
        let delayedIdle = event(
            state: .finished,
            eventName: "Notification",
            turnID: "turn-old",
            notificationType: "idle_prompt",
            date: Date(timeIntervalSince1970: 100)
        )

        let result = store.apply(delayedIdle)

        XCTAssertEqual(result.summary.state, .working)
        XCTAssertFalse(result.shouldNotify)
    }

    func testDelayedSessionStartCannotRegressWorkingSession() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        let working = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-1",
            date: Date(timeIntervalSince1970: 200)
        )
        _ = store.apply(working)
        let delayedStart = event(
            state: .started,
            eventName: "SessionStart",
            turnID: nil,
            date: Date(timeIntervalSince1970: 100)
        )

        let result = store.apply(delayedStart)

        XCTAssertEqual(result.summary.state, .working)
        XCTAssertEqual(result.summary.turnID, "turn-1")
    }

    func testSameSessionIDFromDifferentProvidersDoesNotCollide() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        var claude = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-1"
        )
        claude.sessionID = "shared-id"
        var codex = claude
        codex.provider = .codex

        _ = store.apply(claude)
        _ = store.apply(codex)

        XCTAssertNotNil(store.session(provider: .claude, sessionID: "shared-id"))
        XCTAssertNotNil(store.session(provider: .codex, sessionID: "shared-id"))
        XCTAssertEqual(store.allSessions().count, 2)
    }

    func testNewTurnSurvivesWallClockMovingBackward() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        let finished = event(
            state: .finished,
            eventName: "Stop",
            turnID: "turn-old",
            date: Date(timeIntervalSince1970: 500)
        )
        _ = store.apply(finished)
        let newTurn = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-new",
            date: Date(timeIntervalSince1970: 100)
        )

        let result = store.apply(newTurn)

        XCTAssertEqual(result.summary.state, .working)
        XCTAssertEqual(result.summary.turnID, "turn-new")
        XCTAssertGreaterThan(result.summary.updatedAt, finished.timestamp)
    }

    func testSparseFollowUpPreservesRoutingOriginAndClearsStalePreview() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        var finished = event(
            state: .finished,
            eventName: "Stop",
            turnID: "turn-old",
            date: Date(timeIntervalSince1970: 100)
        )
        finished.contentPreview = "Old completion preview"
        finished.origin = OriginMetadata(
            hostBundleIdentifier: "com.microsoft.VSCode",
            executablePath: "/opt/homebrew/bin/claude",
            ghosttyTerminalID: "terminal-1"
        )
        _ = store.apply(finished)

        var newTurn = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-new",
            date: Date(timeIntervalSince1970: 101)
        )
        newTurn.origin = OriginMetadata()
        let summary = store.apply(newTurn).summary

        XCTAssertNil(summary.contentPreview)
        XCTAssertEqual(summary.origin.hostBundleIdentifier, "com.microsoft.VSCode")
        XCTAssertEqual(summary.origin.executablePath, "/opt/homebrew/bin/claude")
        XCTAssertEqual(summary.origin.ghosttyTerminalID, "terminal-1")
    }

    func testConditionalRemovalDoesNotDeleteSessionUpdatedDuringAnimation() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        let initial = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-1",
            date: Date(timeIntervalSince1970: 100)
        )
        let snapshot = store.apply(initial).summary
        var attention = event(
            state: .attention,
            eventName: "PermissionRequest",
            turnID: "turn-1",
            date: Date(timeIntervalSince1970: 101)
        )
        attention.contentPreview = "Needs approval"
        _ = store.apply(attention)

        XCTAssertFalse(
            store.remove(
                sessionKey: snapshot.sessionKey,
                ifUpdatedAt: snapshot.updatedAt
            )
        )
        XCTAssertEqual(
            store.session(provider: .claude, sessionID: initial.sessionID)?.state,
            .attention
        )
    }

    func testPersistedSummariesWithInvalidIdentityOrPathAreRejected() throws {
        let stateURL = temporaryDirectory().appendingPathComponent("sessions.json")
        var valid = SessionSummary(
            event: event(
                state: .working,
                eventName: "UserPromptSubmit",
                turnID: "turn-valid"
            )
        )
        valid.sessionID = "valid-session"
        valid.sessionKey = "claude:valid-session"

        var invalidID = valid
        invalidID.sessionID = "invalid session"
        invalidID.sessionKey = "claude:invalid session"

        var mismatchedKey = valid
        mismatchedKey.sessionID = "mismatched-session"

        var relativePath = valid
        relativePath.sessionID = "relative-path-session"
        relativePath.sessionKey = "claude:relative-path-session"
        relativePath.cwd = "relative/project"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([
            invalidID,
            mismatchedKey,
            relativePath,
            valid,
        ]).write(to: stateURL)

        let restored = SessionStore(stateURL: stateURL)

        XCTAssertEqual(restored.allSessions().map(\.sessionKey), [valid.sessionKey])
    }

    func testPersistedSummaryFieldsAreSanitizedBeforeRestoration() throws {
        let stateURL = temporaryDirectory().appendingPathComponent("sessions.json")
        var summary = SessionSummary(
            event: event(
                state: .working,
                eventName: "UserPromptSubmit",
                turnID: "turn-valid"
            )
        )
        summary.projectName = "  Project\nName  "
        summary.displayTitle = String(repeating: "T", count: 90)
        summary.contentPreview = String(repeating: "🙂", count: 130)
        summary.notificationType = "bad type!"
        summary.testDisplayName = "  Turnring\nTest  "
        summary.turnID = "invalid turn"
        summary.lastHookEventName = "  Stop\nFailure  "
        summary.origin = OriginMetadata(
            agentProcess: ProcessRecord(
                pid: 1,
                parentPID: 0,
                tty: nil,
                startIdentifier: "invalid",
                command: "claude"
            ),
            shellProcess: ProcessRecord(
                pid: 222,
                parentPID: 0,
                tty: "ttys001",
                startIdentifier: "  shell\nbirth  ",
                command: "  /bin/zsh\n"
            ),
            hostBundleIdentifier: "com.microsoft.VSCode;unsafe",
            executablePath: "relative/claude",
            termProgram: "unsafe value",
            cmuxWindowID: "window:1"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([summary]).write(to: stateURL)

        let restored = try XCTUnwrap(
            SessionStore(stateURL: stateURL)
                .session(provider: .claude, sessionID: summary.sessionID)
        )

        XCTAssertEqual(restored.projectName, "Project Name")
        XCTAssertEqual(restored.displayTitle?.count, 81)
        XCTAssertEqual(restored.displayTitle?.last, "…")
        XCTAssertEqual(restored.contentPreview?.count, 120)
        XCTAssertEqual(restored.contentPreview?.last, "…")
        XCTAssertNil(restored.notificationType)
        XCTAssertEqual(restored.testDisplayName, "Turnring Test")
        XCTAssertNil(restored.turnID)
        XCTAssertEqual(restored.lastHookEventName, "Stop Failure")
        XCTAssertNil(restored.origin.agentProcess)
        XCTAssertEqual(restored.origin.shellProcess?.startIdentifier, "shell birth")
        XCTAssertEqual(restored.origin.shellProcess?.command, "/bin/zsh")
        XCTAssertNil(restored.origin.hostBundleIdentifier)
        XCTAssertNil(restored.origin.executablePath)
        XCTAssertNil(restored.origin.termProgram)
        XCTAssertEqual(restored.origin.cmuxWindowID, "window:1")
    }

    func testCorruptPersistedStateIsQuarantinedWithoutBreakingStartup() throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("sessions.json")
        try Data("invalid-state".utf8).write(to: stateURL)

        let store = SessionStore(stateURL: stateURL)

        XCTAssertTrue(store.allSessions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("sessions.corrupt-") })
    }

    func testDuplicatePersistedSessionKeysKeepNewestWithoutCrashing() throws {
        let directory = temporaryDirectory()
        let stateURL = directory.appendingPathComponent("sessions.json")
        var older = SessionSummary(
            event: event(
                state: .working,
                eventName: "UserPromptSubmit",
                turnID: "turn-1",
                date: Date(timeIntervalSince1970: 100)
            )
        )
        older.displayTitle = "Older"
        var newer = older
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        newer.displayTitle = "Newer"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([older, newer]).write(to: stateURL)

        let store = SessionStore(stateURL: stateURL)

        XCTAssertEqual(store.allSessions().count, 1)
        XCTAssertEqual(store.allSessions().first?.displayTitle, "Newer")
    }

    func testConcurrentSessionUpdatesDoNotLoseIndependentSessions() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)

        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let value = AgentEvent(
                provider: .claude,
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
            )
            _ = store.apply(value)
        }

        XCTAssertEqual(store.allSessions().count, 40)
    }

    func testConversationTitleUpdatesAndSurfaceNameReflectsCapturedHost() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        let store = SessionStore(stateURL: stateURL)
        var working = event(
            state: .working,
            eventName: "UserPromptSubmit",
            turnID: "turn-1"
        )
        working.displayTitle = "Create site"
        working.origin.hostBundleIdentifier = "com.microsoft.VSCode"
        _ = store.apply(working)

        var followUp = working
        followUp.displayTitle = "Renamed conversation"
        followUp.timestamp = Date(timeIntervalSince1970: 100.5)
        _ = store.apply(followUp)

        var stopped = event(
            state: .finished,
            eventName: "Stop",
            turnID: "turn-1",
            date: Date(timeIntervalSince1970: 101)
        )
        stopped.contentPreview = "Created the site and verified deployment."
        stopped.origin.hostBundleIdentifier = "com.microsoft.VSCode"
        let summary = store.apply(stopped).summary

        XCTAssertEqual(
            summary.formattedTitle,
            "Claude Code VS Code • Renamed conversation (1s)"
        )
        XCTAssertEqual(summary.contentPreview, "Created the site and verified deployment.")
        XCTAssertEqual(
            summary.notificationBody,
            "Created the site and verified deployment."
        )
        XCTAssertFalse(summary.notificationBody?.contains("Claude Code VS Code") == true)
    }

    func testDashboardPrivacyUsesGenericContentAndCustomDetailedLength() {
        var finished = event(
            state: .finished,
            eventName: "Stop",
            turnID: "turn-private"
        )
        finished.displayTitle = "Secret conversation title"
        finished.contentPreview =
            "Implemented the private customer dashboard successfully."
        let summary = SessionSummary(event: finished)

        XCTAssertEqual(
            summary.dashboardTitle(includesPrivateDetails: false),
            "Claude Code CLI • Finished"
        )
        XCTAssertEqual(
            summary.dashboardPreview(
                includesPrivateDetails: false,
                maximumCharacters: 50
            ),
            "Task finished."
        )
        XCTAssertEqual(
            summary.dashboardTitle(includesPrivateDetails: true),
            "Claude Code CLI • Secret conversation title"
        )
        let detailedPreview = summary.dashboardPreview(
            includesPrivateDetails: true,
            maximumCharacters: 20
        )
        XCTAssertEqual(detailedPreview.count, 20)
        XCTAssertEqual(detailedPreview.last, "…")
    }

    func testSyntheticTestEntryPersistsDisplayNameAndRemainsMarkedAsTest() {
        let stateURL = temporaryDirectory().appendingPathComponent("state.json")
        var store: SessionStore? = SessionStore(stateURL: stateURL)
        let testEvent = AgentEvent(
            provider: .codex,
            state: .attention,
            hookEventName: "TurnringTest",
            sessionID: "turnring-test-alert-123",
            turnID: nil,
            cwd: FileManager.default.currentDirectoryPath,
            projectName: "Turnring",
            timestamp: Date(timeIntervalSince1970: 100),
            notificationType: "alert",
            displayTitle: "Test alert",
            contentPreview: "Notifications are working.",
            testDisplayName: "Turnring",
            origin: OriginMetadata()
        )

        let created = store?.apply(testEvent).summary
        XCTAssertEqual(created?.formattedTitle, "Turnring • Test alert")
        XCTAssertTrue(created?.isTest == true)
        store = nil

        let restored = SessionStore(stateURL: stateURL)
            .session(provider: .codex, sessionID: testEvent.sessionID)
        XCTAssertEqual(restored?.testDisplayName, "Turnring")
        XCTAssertTrue(restored?.isTest == true)
    }

    private func event(
        state: AgentState,
        eventName: String,
        turnID: String?,
        notificationType: String? = nil,
        date: Date = Date(timeIntervalSince1970: 100)
    ) -> AgentEvent {
        AgentEvent(
            provider: .claude,
            state: state,
            hookEventName: eventName,
            sessionID: "session-123",
            turnID: turnID,
            cwd: FileManager.default.currentDirectoryPath,
            projectName: "Project",
            timestamp: date,
            notificationType: notificationType,
            origin: OriginMetadata()
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurnringTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
