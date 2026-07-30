import Foundation

public enum EventNormalizerError: Error, Equatable {
    case oversizedPayload
    case invalidJSON
    case missingEventName
    case invalidSessionID
    case invalidWorkingDirectory
    case unsupportedEvent
}

public enum EventNormalizer {
    public static let maximumPayloadBytes = 1_048_576

    public static func normalize(
        data: Data,
        provider: AgentProvider,
        origin: OriginMetadata,
        codexApprovalReviewer: CodexApprovalReviewer? = nil,
        now: Date = Date()
    ) throws -> AgentEvent {
        guard data.count <= maximumPayloadBytes else {
            throw EventNormalizerError.oversizedPayload
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else {
            throw EventNormalizerError.invalidJSON
        }

        guard let hookEventName = payload["hook_event_name"] as? String,
              !hookEventName.isEmpty
        else {
            throw EventNormalizerError.missingEventName
        }

        guard let sessionID = payload["session_id"] as? String,
              AgentBellValidation.isValidSessionID(sessionID)
        else {
            throw EventNormalizerError.invalidSessionID
        }

        guard let rawCWD = payload["cwd"] as? String,
              let cwd = AgentBellValidation.normalizedAbsolutePath(rawCWD)
        else {
            throw EventNormalizerError.invalidWorkingDirectory
        }

        let notificationType = payload["notification_type"] as? String
        let toolName = payload["tool_name"] as? String
        if provider == .codex, hookEventName == "PermissionRequest" {
            let reviewer = codexApprovalReviewer ?? CodexApprovalReviewer(
                hookValue: payload["approvals_reviewer"] as? String
            )
            guard CodexApprovalNotificationPolicy.shouldNotify(
                permissionMode: payload["permission_mode"] as? String,
                reviewer: reviewer
            ) else {
                throw EventNormalizerError.unsupportedEvent
            }
        }
        var state = try state(
            for: hookEventName,
            provider: provider,
            notificationType: notificationType,
            toolName: toolName
        )
        var failureReason: AbruptStopReason?
        if hookEventName == "StopFailure" {
            failureReason = AbruptStopReason(
                providerError: payload["error"] as? String
            )
        } else if provider == .codex, hookEventName == "Stop" {
            failureReason = AbruptStopClassifier.classifyCodexStop(
                message: payload["last_assistant_message"] as? String
            )
            if failureReason != nil {
                state = .failed
            }
        }
        let turnID = sanitizedOptionalIdentifier(payload["turn_id"] as? String)
        let contentPreview: String?
        switch hookEventName {
        case "Stop", "StopFailure":
            contentPreview =
                AttentionPreviewFormatter.redactedContentPreview(
                    payload["last_assistant_message"] as? String,
                    maximumCharacters:
                        AttentionPreviewFormatter.maximumCharacters
                )
                ?? failureReason?.fallbackPreview
        case "Notification":
            contentPreview = AttentionPreviewFormatter.redactedContentPreview(
                payload["message"] as? String,
                maximumCharacters:
                    AttentionPreviewFormatter.maximumCharacters
            )
        case "PermissionRequest", "PreToolUse":
            contentPreview = AttentionPreviewFormatter.preview(
                provider: provider,
                origin: origin,
                eventName: hookEventName,
                toolName: toolName,
                toolInput: payload["tool_input"],
                cwd: cwd
            )
        default:
            contentPreview = nil
        }

        return AgentEvent(
            provider: provider,
            state: state,
            hookEventName: hookEventName,
            sessionID: sessionID,
            turnID: turnID,
            cwd: cwd,
            projectName: AgentBellValidation.projectName(for: cwd),
            timestamp: now,
            notificationType: sanitizedNotificationType(
                notificationType
                    ?? failureReason?.rawValue
                    ?? (hookEventName == "PreToolUse" ? toolName : nil)
            ),
            displayTitle: nil,
            contentPreview: contentPreview,
            origin: origin
        )
    }

    private static func state(
        for event: String,
        provider: AgentProvider,
        notificationType: String?,
        toolName: String?
    ) throws -> AgentState {
        switch event {
        case "SessionStart":
            return .started
        case "UserPromptSubmit":
            return .working
        case "PermissionRequest":
            return .attention
        case "PreToolUse" where provider == .codex && toolName == "request_user_input":
            return .attention
        case "PreToolUse" where provider == .claude
            && (toolName == "AskUserQuestion" || toolName == "ExitPlanMode"):
            return .attention
        case "Notification" where provider == .claude:
            if notificationType == "idle_prompt" {
                return .finished
            }
            return .attention
        case "Stop":
            return .finished
        case "StopFailure":
            return .failed
        case "SessionEnd":
            return .ended
        default:
            throw EventNormalizerError.unsupportedEvent
        }
    }

    private static func sanitizedOptionalIdentifier(_ value: String?) -> String? {
        guard let value,
              AgentBellValidation.isValidOptionalIdentifier(value)
        else {
            return nil
        }
        return value
    }

    private static func sanitizedNotificationType(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 80 else { return nil }
        return value.allSatisfy({ $0.isLetter || $0.isNumber || "_-".contains($0) })
            ? value
            : nil
    }

}
