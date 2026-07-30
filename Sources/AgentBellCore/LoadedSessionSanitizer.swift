import Foundation

enum LoadedSessionSanitizer {
    static func sanitize(_ value: SessionSummary) -> SessionSummary? {
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
        summary.origin = sanitizedOrigin(value.origin)
        return summary
    }

    private static func sanitizedOrigin(
        _ value: OriginMetadata
    ) -> OriginMetadata {
        OriginMetadata(
            agentProcess: sanitizedProcess(value.agentProcess),
            shellProcess: sanitizedProcess(value.shellProcess),
            hostProcess: sanitizedProcess(value.hostProcess),
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

    private static func sanitizedProcess(
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

    private static func safeOpaque(
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
}
