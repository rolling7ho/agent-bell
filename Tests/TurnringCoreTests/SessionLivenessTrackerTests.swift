import XCTest
@testable import TurnringCore

final class SessionLivenessTrackerTests: XCTestCase {
    func testAttentionOnlySessionIsTrackedAndRequiresTwoDeadObservations() {
        let session = summary(state: .attention, hasProcess: true)
        var tracker = SessionLivenessTracker(sessions: [session])

        XCTAssertEqual(tracker.trackedKeys, [session.sessionKey])
        XCTAssertEqual(
            tracker.observe(sessionKey: session.sessionKey, isAlive: false),
            .suspectedDead
        )
        XCTAssertEqual(
            tracker.observe(sessionKey: session.sessionKey, isAlive: false),
            .confirmedDead
        )
        XCTAssertTrue(tracker.isEmpty)
    }

    func testNewActivityClearsAFalseDeadObservation() {
        let session = summary(state: .working, hasProcess: true)
        var tracker = SessionLivenessTracker(sessions: [session])

        XCTAssertEqual(
            tracker.observe(sessionKey: session.sessionKey, isAlive: false),
            .suspectedDead
        )
        tracker.track(session)
        XCTAssertEqual(
            tracker.observe(sessionKey: session.sessionKey, isAlive: false),
            .suspectedDead
        )
    }

    func testAliveObservationClearsSuspicion() {
        let session = summary(state: .started, hasProcess: true)
        var tracker = SessionLivenessTracker(sessions: [session])

        XCTAssertEqual(
            tracker.observe(sessionKey: session.sessionKey, isAlive: false),
            .suspectedDead
        )
        XCTAssertEqual(
            tracker.observe(sessionKey: session.sessionKey, isAlive: true),
            .alive
        )
        XCTAssertEqual(
            tracker.observe(sessionKey: session.sessionKey, isAlive: false),
            .suspectedDead
        )
    }

    func testSleepResetClearsAllDeadSuspicionsWithoutDroppingTracking() {
        let session = summary(state: .working, hasProcess: true)
        var tracker = SessionLivenessTracker(sessions: [session])

        XCTAssertEqual(
            tracker.observe(sessionKey: session.sessionKey, isAlive: false),
            .suspectedDead
        )
        tracker.resetDeadObservations()

        XCTAssertEqual(tracker.trackedKeys, [session.sessionKey])
        XCTAssertEqual(
            tracker.observe(sessionKey: session.sessionKey, isAlive: false),
            .suspectedDead
        )
    }

    func testTerminalStateAndMissingProcessAreNotTracked() {
        var tracker = SessionLivenessTracker()
        for state in [AgentState.finished, .failed, .ended] {
            tracker.track(summary(state: state, hasProcess: true))
        }
        tracker.track(summary(state: .working, hasProcess: false))
        XCTAssertTrue(tracker.isEmpty)
    }

    func testProviderQualifiedKeysRemainIndependent() {
        let codex = summary(provider: .codex, state: .working, hasProcess: true)
        let claude = summary(provider: .claude, state: .working, hasProcess: true)
        var tracker = SessionLivenessTracker(sessions: [codex, claude])

        XCTAssertEqual(
            tracker.observe(sessionKey: codex.sessionKey, isAlive: false),
            .suspectedDead
        )
        XCTAssertEqual(
            tracker.observe(sessionKey: codex.sessionKey, isAlive: false),
            .confirmedDead
        )
        XCTAssertEqual(tracker.trackedKeys, [claude.sessionKey])
    }

    private func summary(
        provider: AgentProvider = .codex,
        state: AgentState,
        hasProcess: Bool
    ) -> SessionSummary {
        SessionSummary(
            event: AgentEvent(
                provider: provider,
                state: state,
                hookEventName: "Test",
                sessionID: "same-session",
                turnID: "turn-1",
                cwd: "/tmp",
                projectName: "Project",
                timestamp: Date(),
                notificationType: nil,
                origin: OriginMetadata(
                    agentProcess: hasProcess
                        ? ProcessRecord(
                            pid: 123,
                            parentPID: 1,
                            tty: nil,
                            startIdentifier: "birth",
                            command: provider.rawValue
                        )
                        : nil
                )
            )
        )
    }
}
