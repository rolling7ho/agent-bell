import Foundation

public enum AttentionPreviewFormatter {
    public static let maximumCharacters = 120

    public static func preview(
        provider: AgentProvider,
        origin: OriginMetadata,
        eventName: String,
        toolName: String?,
        toolInput: Any?,
        cwd: String
    ) -> String? {
        guard let toolName else { return nil }
        let appName = provider.appDisplayName(origin: origin)

        if eventName == "PreToolUse",
           toolName == "request_user_input" || toolName == "AskUserQuestion"
        {
            guard let question = questionSummary(from: toolInput) else {
                return "\(appName) is waiting for your answer."
            }
            let lead = question.count == 1
                ? "\(appName) has a question"
                : "\(appName) has \(question.count) questions. First"
            return truncated("\(lead): \(question.first)")
        }

        guard eventName == "PermissionRequest"
                || (eventName == "PreToolUse" && toolName == "ExitPlanMode")
        else {
            return nil
        }

        if toolName == "ExitPlanMode" {
            return truncated(
                "\(appName) wants you to review its plan and choose Approve or Reject."
            )
        }

        let actionName = normalizedToolName(toolName)
        let action = actionDescription(
            from: toolInput,
            cwd: cwd,
            normalizedToolName: actionName
        )
        let phrase = permissionPhrase(
            normalizedToolName: actionName,
            detail: action
        )
        let value = "\(appName) wants permission to \(phrase)."
        return truncated(value)
    }

    public static func redactedContentPreview(
        _ value: String?,
        maximumCharacters: Int
    ) -> String? {
        guard let value else { return nil }
        let safe = TurnringSafeText.redacted(sanitizedText(value))
        guard !safe.isEmpty else { return nil }
        guard safe.count > maximumCharacters else { return safe }
        return String(safe.prefix(maximumCharacters)) + "…"
    }

    public static func notificationPreview(
        provider: AgentProvider,
        origin: OriginMetadata,
        notificationType: String?,
        message: String?
    ) -> String? {
        let appName = provider.appDisplayName(origin: origin)
        let safeMessage = redactedContentPreview(
            message,
            maximumCharacters: maximumCharacters
        )
        let lead: String
        switch notificationType {
        case "elicitation_dialog":
            lead = "\(appName) has a question"
        case "agent_needs_input":
            lead = "\(appName) is waiting for your input"
        case "permission_prompt":
            lead = "\(appName) is waiting for permission"
        default:
            return safeMessage
        }
        guard let safeMessage, !safeMessage.isEmpty else {
            return lead + "."
        }
        return truncated("\(lead): \(safeMessage)")
    }

    public static func normalizedToolName(_ value: String) -> String {
        let finalComponent = value.hasPrefix("mcp__")
            ? value.split(separator: "__").last.map(String.init) ?? value
            : value
        switch finalComponent.lowercased() {
        case "bash", "exec_command":
            return "run_command"
        case "read", "read_file":
            return "read_file"
        case "write", "write_file":
            return "write_file"
        case "edit", "apply_patch":
            return "edit_file"
        case "glob":
            return "search_files"
        case "grep":
            return "search_text"
        default:
            return snakeCase(finalComponent)
        }
    }

    private static func questionSummary(
        from input: Any?
    ) -> (first: String, count: Int)? {
        guard let dictionary = input as? [String: Any] else { return nil }
        if let questions = dictionary["questions"] as? [[String: Any]],
           let firstQuestion = questions.first?["question"] as? String
        {
            let safe = TurnringSafeText.redacted(
                sanitizedText(firstQuestion)
            )
            guard !safe.isEmpty else { return nil }
            return (safe, max(1, questions.count))
        }
        guard let directQuestion = dictionary["question"] as? String else {
            return nil
        }
        let safe = TurnringSafeText.redacted(sanitizedText(directQuestion))
        return safe.isEmpty ? nil : (safe, 1)
    }

    private static func permissionPhrase(
        normalizedToolName: String,
        detail: String?
    ) -> String {
        let action: String
        switch normalizedToolName {
        case "run_command": action = "run a command"
        case "read_file": action = "read a file"
        case "write_file": action = "write to a file"
        case "edit_file": action = "edit a file"
        case "search_files": action = "search files"
        case "search_text": action = "search text"
        case "web_fetch": action = "open a web page"
        case "web_search": action = "search the web"
        default:
            action = "use \(humanizedToolName(normalizedToolName))"
        }
        guard let detail, !detail.isEmpty else { return action }
        return "\(action): \(detail)"
    }

    private static func humanizedToolName(_ value: String) -> String {
        value.split(separator: "_")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func actionDescription(
        from input: Any?,
        cwd: String,
        normalizedToolName: String
    ) -> String? {
        guard let dictionary = input as? [String: Any] else { return nil }

        if let command = nonemptyString(dictionary["command"]) {
            return TurnringSafeText.redacted(sanitizedText(command))
        }

        if normalizedToolName == "search_files" || normalizedToolName == "search_text",
           let pattern = nonemptyString(dictionary["pattern"])
        {
            let sanitizedPattern = sanitizedText(pattern)
            if let path = nonemptyString(dictionary["path"]) {
                return "\(sanitizedPattern) in \(sanitizedPath(path, cwd: cwd))"
            }
            return sanitizedPattern
        }

        if let filePath = nonemptyString(dictionary["file_path"])
            ?? nonemptyString(dictionary["path"])
        {
            return sanitizedPath(filePath, cwd: cwd)
        }

        if let query = nonemptyString(dictionary["query"]) {
            return TurnringSafeText.redacted(sanitizedText(query))
        }

        if let pattern = nonemptyString(dictionary["pattern"]) {
            return TurnringSafeText.redacted(sanitizedText(pattern))
        }

        if let url = nonemptyString(dictionary["url"]) {
            return TurnringSafeText.redacted(sanitizedText(url))
        }

        if let description = nonemptyString(dictionary["description"]) {
            return TurnringSafeText.redacted(sanitizedText(description))
        }

        return nil
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func sanitizedText(_ value: String) -> String {
        TurnringSafeText.collapsed(value)
    }

    private static func sanitizedPath(_ value: String, cwd: String) -> String {
        let normalized = sanitizedText(value)
        guard normalized.hasPrefix("/") else {
            return normalized.hasPrefix("./") ? String(normalized.dropFirst(2)) : normalized
        }

        let root = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let path = URL(fileURLWithPath: normalized).standardizedFileURL.path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(rootPrefix) {
            return String(path.dropFirst(rootPrefix.count))
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func snakeCase(_ value: String) -> String {
        var result = ""
        var previousWasLowercaseOrNumber = false

        for character in value {
            if character.isLetter || character.isNumber {
                if character.isUppercase && previousWasLowercaseOrNumber && !result.hasSuffix("_") {
                    result.append("_")
                }
                result.append(contentsOf: character.lowercased())
                previousWasLowercaseOrNumber = character.isLowercase || character.isNumber
            } else if !result.isEmpty && !result.hasSuffix("_") {
                result.append("_")
                previousWasLowercaseOrNumber = false
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "use_tool" : trimmed
    }

    private static func truncated(_ value: String) -> String {
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters - 1)) + "…"
    }
}
