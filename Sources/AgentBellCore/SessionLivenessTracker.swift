import Foundation

public struct SessionLivenessTracker: Sendable {
    public enum Observation: Equatable, Sendable {
        case alive
        case suspectedDead
        case confirmedDead
        case untracked
    }

    private let requiredDeadObservations: Int
    private var activeKeys: Set<String>
    private var deadObservations: [String: Int]

    public init(
        sessions: [SessionSummary] = [],
        requiredDeadObservations: Int = 2
    ) {
        self.requiredDeadObservations = max(1, requiredDeadObservations)
        activeKeys = []
        deadObservations = [:]
        for session in sessions {
            track(session)
        }
    }

    public var trackedKeys: Set<String> {
        activeKeys
    }

    public var isEmpty: Bool {
        activeKeys.isEmpty
    }

    public mutating func track(_ session: SessionSummary) {
        switch session.state {
        case .started, .working, .attention:
            guard session.origin.agentProcess != nil else {
                remove(session.sessionKey)
                return
            }
            activeKeys.insert(session.sessionKey)
            deadObservations.removeValue(forKey: session.sessionKey)
        case .finished, .failed, .ended:
            remove(session.sessionKey)
        }
    }

    public mutating func remove(_ sessionKey: String) {
        activeKeys.remove(sessionKey)
        deadObservations.removeValue(forKey: sessionKey)
    }

    public mutating func removeAll() {
        activeKeys.removeAll()
        deadObservations.removeAll()
    }

    public mutating func resetDeadObservations() {
        deadObservations.removeAll()
    }

    public mutating func observe(
        sessionKey: String,
        isAlive: Bool
    ) -> Observation {
        guard activeKeys.contains(sessionKey) else { return .untracked }
        if isAlive {
            deadObservations.removeValue(forKey: sessionKey)
            return .alive
        }

        let count = (deadObservations[sessionKey] ?? 0) + 1
        guard count >= requiredDeadObservations else {
            deadObservations[sessionKey] = count
            return .suspectedDead
        }
        remove(sessionKey)
        return .confirmedDead
    }
}
