import Foundation

public final class SessionStore: @unchecked Sendable {
    public static let maximumSessions = 50
    private static let maximumDedupeKeys = 2_000

    private let lock = NSLock()
    private var sessionsByKey: [String: SessionSummary] = [:]
    private var recentDedupeKeys: [String: Date] = [:]
    private let stateURL: URL

    private struct PersistedState: Codable {
        var version: Int
        var sessions: [SessionSummary]
        var recentDedupeKeys: [String: Date]
    }

    public init(stateURL: URL = AgentBellPaths.stateFile) {
        self.stateURL = stateURL
        load()
    }

    public func apply(
        _ event: AgentEvent,
        processedAt: Date = Date()
    ) -> (summary: SessionSummary, shouldNotify: Bool, didApply: Bool) {
        lock.lock()
        defer { lock.unlock() }

        recentDedupeKeys = recentDedupeKeys.filter {
            let lifetime: TimeInterval = $0.key.contains(":no-turn:") ? 5 : 300
            return abs(processedAt.timeIntervalSince($0.value)) < lifetime
        }
        let isDuplicate = recentDedupeKeys[event.deduplicationKey] != nil
        recentDedupeKeys[event.deduplicationKey] = processedAt
        trimDedupeKeysLocked()

        if isDuplicate, var existing = sessionsByKey[event.sessionKey] {
            if let title = event.displayTitle,
               title != existing.displayTitle
            {
                existing.displayTitle = title
                sessionsByKey[event.sessionKey] = existing
            }
            saveLocked()
            return (existing, false, false)
        }

        var suppressFinishedDuplicate = false
        if let existing = sessionsByKey[event.sessionKey],
           existing.state == .finished,
           event.state == .finished,
           existing.turnID == event.turnID
        {
            suppressFinishedDuplicate = true
        }

        if let existing = sessionsByKey[event.sessionKey],
           !shouldApply(event, to: existing)
        {
            saveLocked()
            return (existing, false, false)
        }

        let existingSummary = sessionsByKey[event.sessionKey]
        var summary: SessionSummary
        if let existingSummary {
            summary = existingSummary
            let effectiveTimestamp = max(
                event.timestamp,
                existingSummary.updatedAt.addingTimeInterval(0.001)
            )
            summary.apply(event, effectiveTimestamp: effectiveTimestamp)
        } else {
            summary = SessionSummary(event: event)
            if summary.runStartedAt == nil,
               let inheritedStart = inheritedRunStartLocked(for: event)
            {
                summary.runStartedAt = inheritedStart
            }
        }
        sessionsByKey[event.sessionKey] = summary
        trimLocked()
        saveLocked()
        return (
            summary,
            event.state.shouldNotify && !suppressFinishedDuplicate,
            true
        )
    }

    public func allSessions() -> [SessionSummary] {
        lock.lock()
        defer { lock.unlock() }
        return sessionsByKey.values.sorted { lhs, rhs in
            if lhs.state == .attention && rhs.state != .attention { return true }
            if rhs.state == .attention && lhs.state != .attention { return false }
            if lhs.state == .working && rhs.state != .working { return true }
            if rhs.state == .working && lhs.state != .working { return false }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public func session(provider: AgentProvider, sessionID: String) -> SessionSummary? {
        lock.lock()
        defer { lock.unlock() }
        return sessionsByKey["\(provider.rawValue):\(sessionID)"]
    }

    @discardableResult
    public func updateDisplayTitle(
        provider: AgentProvider,
        sessionID: String,
        title: String
    ) -> SessionSummary? {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(provider.rawValue):\(sessionID)"
        guard var summary = sessionsByKey[key] else { return nil }
        guard summary.displayTitle != title else { return summary }
        summary.displayTitle = title
        sessionsByKey[key] = summary
        saveLocked()
        return summary
    }

    public func markUnexpectedExit(
        sessionKey: String,
        at date: Date = Date(),
        preview: String = "Agent process exited before completing."
    ) -> SessionSummary? {
        lock.lock()
        defer { lock.unlock() }
        guard var summary = sessionsByKey[sessionKey],
              summary.state == .working
                || summary.state == .started
                || summary.state == .attention
        else {
            return nil
        }
        summary.state = .failed
        summary.updatedAt = max(
            date,
            summary.updatedAt.addingTimeInterval(0.001)
        )
        summary.observedActivityAt = summary.updatedAt
        let safePreview = AgentBellSafeText.collapsed(
            preview,
            maximumCharacters: 120,
            appendEllipsisWhenTruncated: true
        )
        summary.contentPreview = safePreview.isEmpty ? nil : safePreview
        summary.lastHookEventName = "UnexpectedExit"
        sessionsByKey[sessionKey] = summary
        saveLocked()
        return summary
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        sessionsByKey.removeAll()
        recentDedupeKeys.removeAll()
        try? FileManager.default.removeItem(at: stateURL)
    }

    @discardableResult
    public func remove(
        sessionKey: String,
        ifUpdatedAt expectedUpdatedAt: Date? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = sessionsByKey[sessionKey],
              expectedUpdatedAt == nil || existing.updatedAt == expectedUpdatedAt
        else {
            return false
        }
        sessionsByKey.removeValue(forKey: sessionKey)
        let dedupePrefix = "\(sessionKey):"
        recentDedupeKeys = recentDedupeKeys.filter {
            !$0.key.hasPrefix(dedupePrefix)
        }
        saveLocked()
        return true
    }

    private func trimLocked() {
        let sorted = sessionsByKey.values.sorted { $0.updatedAt > $1.updatedAt }
        let active = sorted.filter(\.isActiveForRetention)
        let inactiveLimit = max(0, Self.maximumSessions - active.count)
        let retained = active + sorted
            .filter { !$0.isActiveForRetention }
            .prefix(inactiveLimit)
        sessionsByKey = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.sessionKey, $0) }
        )
    }

    private func trimDedupeKeysLocked() {
        guard recentDedupeKeys.count > Self.maximumDedupeKeys else { return }
        recentDedupeKeys = Dictionary(
            uniqueKeysWithValues: recentDedupeKeys
                .sorted { $0.value > $1.value }
                .prefix(Self.maximumDedupeKeys)
                .map { ($0.key, $0.value) }
        )
    }

    private func shouldApply(
        _ event: AgentEvent,
        to existing: SessionSummary
    ) -> Bool {
        let turnsConflict = event.turnID != nil
            && existing.turnID != nil
            && event.turnID != existing.turnID

        switch event.hookEventName {
        case "SessionStart":
            return !existing.isActiveForRetention
        case "UserPromptSubmit":
            if turnsConflict {
                return true
            }
            return existing.state != .ended
                || event.timestamp > existing.updatedAt
        case "Notification" where event.state == .finished:
            guard existing.state != .ended else { return false }
            return !turnsConflict
        case "PermissionRequest", "PreToolUse", "Notification":
            guard existing.isActiveForRetention else { return false }
            return !turnsConflict
        case "Stop", "StopFailure":
            guard existing.state != .ended else { return false }
            return !turnsConflict
        case "SessionEnd":
            guard !turnsConflict else { return false }
            if event.turnID == nil && event.timestamp < existing.updatedAt {
                return false
            }
            return true
        default:
            return event.timestamp >= existing.updatedAt
        }
    }

    private func inheritedRunStartLocked(for event: AgentEvent) -> Date? {
        guard event.state == .finished || event.state == .failed,
              let process = event.origin.agentProcess
        else {
            return nil
        }
        return sessionsByKey.values
            .filter { summary in
                guard summary.provider == event.provider,
                      summary.isActiveForRetention,
                      let candidate = summary.origin.agentProcess
                else {
                    return false
                }
                return candidate.pid == process.pid
                    && candidate.startIdentifier == process.startIdentifier
                    && summary.updatedAt <= event.timestamp
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?
            .runStartedAt
    }

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: stateURL) else {
            return
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(
            upToCount: 8 * 1_024 * 1_024 + 1
        ) else {
            return
        }
        guard data.count <= 8 * 1_024 * 1_024 else {
            quarantineCorruptStateLocked()
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summaries: [SessionSummary]
        if let persisted = try? decoder.decode(PersistedState.self, from: data) {
            summaries = persisted.sessions
            recentDedupeKeys = persisted.recentDedupeKeys
        } else if let legacy = try? decoder.decode([SessionSummary].self, from: data) {
            summaries = legacy
        } else {
            quarantineCorruptStateLocked()
            return
        }
        sessionsByKey = [:]
        for summary in summaries {
            guard let validated = validatedLoadedSummary(summary) else {
                continue
            }
            if let existing = sessionsByKey[validated.sessionKey],
               existing.updatedAt >= validated.updatedAt
            {
                continue
            }
            sessionsByKey[validated.sessionKey] = validated
        }
        trimLocked()
        trimDedupeKeysLocked()
    }

    private func validatedLoadedSummary(
        _ value: SessionSummary
    ) -> SessionSummary? {
        guard AgentBellValidation.isValidSessionID(value.sessionID),
              value.sessionKey
                == "\(value.provider.rawValue):\(value.sessionID)",
              let cwd = AgentBellValidation.normalizedAbsolutePath(value.cwd),
              value.updatedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            return nil
        }
        var summary = value
        if let runStartedAt = value.runStartedAt,
           runStartedAt.timeIntervalSinceReferenceDate.isFinite,
           ![AgentState.finished, .failed, .ended].contains(value.state)
                || runStartedAt < value.updatedAt
        {
            summary.runStartedAt = runStartedAt
        } else {
            summary.runStartedAt = nil
        }
        if let observedActivityAt = value.observedActivityAt,
           observedActivityAt.timeIntervalSinceReferenceDate.isFinite
        {
            summary.observedActivityAt = observedActivityAt
        } else if value.isTest
                    || value.displayTitle != nil
                    || value.contentPreview != nil
                    || !["SessionStart", "SessionEnd"].contains(
                        value.lastHookEventName ?? ""
                    )
        {
            summary.observedActivityAt = value.updatedAt
        } else {
            summary.observedActivityAt = nil
        }
        summary.cwd = cwd
        summary.projectName = AgentBellSafeText.collapsed(
            value.projectName,
            maximumCharacters: 100
        )
        if summary.projectName.isEmpty {
            summary.projectName = AgentBellValidation.projectName(for: cwd)
        }
        summary.displayTitle = value.displayTitle.flatMap {
            let safe = AgentBellSafeText.collapsed(
                $0,
                maximumCharacters: 81,
                appendEllipsisWhenTruncated: true
            )
            return safe.isEmpty ? nil : safe
        }
        summary.contentPreview = value.contentPreview.flatMap {
            let safe = AgentBellSafeText.collapsed(
                $0,
                maximumCharacters: 120,
                appendEllipsisWhenTruncated: true
            )
            return safe.isEmpty ? nil : safe
        }
        summary.testDisplayName = value.testDisplayName.flatMap {
            let safe = AgentBellSafeText.collapsed(
                $0,
                maximumCharacters: 100
            )
            return safe.isEmpty ? nil : safe
        }
        summary.turnID = value.turnID.flatMap {
            AgentBellValidation.isValidOptionalIdentifier($0) ? $0 : nil
        }
        summary.lastHookEventName = value.lastHookEventName.flatMap {
            let safe = AgentBellSafeText.collapsed(
                $0,
                maximumCharacters: 100
            )
            return safe.isEmpty ? nil : safe
        }
        summary.origin = sanitizedLoadedOrigin(value.origin)
        return summary
    }

    private func sanitizedLoadedOrigin(
        _ value: OriginMetadata
    ) -> OriginMetadata {
        OriginMetadata(
            agentProcess: sanitizedLoadedProcess(value.agentProcess),
            shellProcess: sanitizedLoadedProcess(value.shellProcess),
            hostProcess: sanitizedLoadedProcess(value.hostProcess),
            hostBundleIdentifier: safeOpaque(value.hostBundleIdentifier),
            executablePath: value.executablePath.flatMap(
                AgentBellValidation.normalizedAbsolutePath
            ),
            termProgram: safeOpaque(value.termProgram),
            cmuxWindowID: safeOpaque(value.cmuxWindowID),
            cmuxWorkspaceID: safeOpaque(value.cmuxWorkspaceID),
            cmuxPaneID: safeOpaque(value.cmuxPaneID),
            cmuxSurfaceID: safeOpaque(value.cmuxSurfaceID),
            ghosttyTerminalID: safeOpaque(value.ghosttyTerminalID)
        )
    }

    private func sanitizedLoadedProcess(
        _ value: ProcessRecord?
    ) -> ProcessRecord? {
        guard let value,
              value.pid > 1,
              value.parentPID >= 0,
              !value.startIdentifier.isEmpty,
              value.startIdentifier.utf8.count <= 128,
              !value.command.isEmpty,
              value.command.utf8.count <= 4_096
        else {
            return nil
        }
        return ProcessRecord(
            pid: value.pid,
            parentPID: value.parentPID,
            tty: safeOpaque(value.tty, maximumBytes: 128),
            startIdentifier: AgentBellSafeText.collapsed(
                value.startIdentifier,
                maximumCharacters: 128
            ),
            command: AgentBellSafeText.collapsed(
                value.command,
                maximumCharacters: 4_096
            )
        )
    }

    private func safeOpaque(
        _ value: String?,
        maximumBytes: Int = 256
    ) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.allSatisfy({
                  $0.isLetter || $0.isNumber || "._:/-".contains($0)
              })
        else {
            return nil
        }
        return value
    }

    private func quarantineCorruptStateLocked() {
        let corruptURL = stateURL.deletingLastPathComponent()
            .appendingPathComponent(
                "sessions.corrupt-\(UUID().uuidString).json"
            )
        try? FileManager.default.moveItem(at: stateURL, to: corruptURL)
    }

    private func saveLocked() {
        do {
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
                    version: 3,
                    sessions: sessionsByKey.values.sorted { $0.updatedAt > $1.updatedAt },
                    recentDedupeKeys: recentDedupeKeys
                )
            )
            try data.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateURL.path
            )
        } catch {
            // Session history is best-effort; hooks and agent work must never be affected.
        }
    }
}

private extension SessionSummary {
    var isActiveForRetention: Bool {
        switch state {
        case .started, .working, .attention:
            true
        case .finished, .failed, .ended:
            false
        }
    }
}
