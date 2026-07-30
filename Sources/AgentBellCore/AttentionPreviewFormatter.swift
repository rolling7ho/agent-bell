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

        if eventName == "PreToolUse",
           toolName == "request_user_input" || toolName == "AskUserQuestion"
        {
            return firstQuestion(from: toolInput).map(truncated)
        }

        guard eventName == "PermissionRequest"
                || (eventName == "PreToolUse" && toolName == "ExitPlanMode")
        else {
            return nil
        }

        let actionName = normalizedToolName(toolName)
        let appName = provider.appDisplayName(origin: origin)
        let action = actionDescription(
            from: toolInput,
            cwd: cwd,
            normalizedToolName: actionName
        )
        let value = if let action {
            "\(appName) wants to \(actionName): \(action)"
        } else if toolName == "ExitPlanMode" {
            "\(appName) wants to \(actionName): Review the proposed plan"
        } else {
            "\(appName) wants to \(actionName)"
        }
        return truncated(value)
    }

    public static func redactedContentPreview(
        _ value: String?,
        maximumCharacters: Int
    ) -> String? {
        guard let value else { return nil }
        let safe = AgentBellSafeText.redacted(sanitizedText(value))
        guard !safe.isEmpty else { return nil }
        guard safe.count > maximumCharacters else { return safe }
        return String(safe.prefix(maximumCharacters)) + "…"
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

    private static func firstQuestion(from input: Any?) -> String? {
        guard let dictionary = input as? [String: Any],
              let questions = dictionary["questions"] as? [[String: Any]],
              let question = questions.first?["question"] as? String
        else {
            return nil
        }
        return AgentBellSafeText.redacted(sanitizedText(question))
    }

    private static func actionDescription(
        from input: Any?,
        cwd: String,
        normalizedToolName: String
    ) -> String? {
        guard let dictionary = input as? [String: Any] else { return nil }

        if let command = nonemptyString(dictionary["command"]) {
            return AgentBellSafeText.redacted(sanitizedText(command))
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
            return AgentBellSafeText.redacted(sanitizedText(query))
        }

        if let pattern = nonemptyString(dictionary["pattern"]) {
            return AgentBellSafeText.redacted(sanitizedText(pattern))
        }

        if let url = nonemptyString(dictionary["url"]) {
            return AgentBellSafeText.redacted(sanitizedText(url))
        }

        if let description = nonemptyString(dictionary["description"]) {
            return AgentBellSafeText.redacted(sanitizedText(description))
        }

        if normalizedToolName == "exit_plan_mode" {
            return "Review the proposed plan"
        }
        return nil
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func sanitizedText(_ value: String) -> String {
        AgentBellSafeText.collapsed(value)
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
