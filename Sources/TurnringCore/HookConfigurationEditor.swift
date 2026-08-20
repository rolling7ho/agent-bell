import Foundation

struct HookConfigurationEditor {
    private let fileManager: FileManager
    private let hookExecutablePath: String
    private let files: ConfigurationFileStore

    init(
        fileManager: FileManager,
        hookExecutablePath: String,
        files: ConfigurationFileStore
    ) {
        self.fileManager = fileManager
        self.hookExecutablePath = hookExecutablePath
        self.files = files
    }

    @discardableResult
    func mergeHooks(at url: URL, provider: AgentProvider) throws -> URL? {
        var root = try files.readJSONObject(at: url)
        let original = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let desiredEvents = hookEvents(for: provider)

        for (eventName, matcher) in desiredEvents {
            var groups = hooks[eventName] as? [[String: Any]] ?? []
            groups = removeOwnedHandlers(from: groups)

            let handler: [String: Any] = [
                "type": "command",
                "command": hookCommand(provider: provider),
                "timeout": 2,
                "statusMessage": "Updating Turnring",
                "turnringOwner": "com.turnring.app",
            ]

            var group: [String: Any] = ["hooks": [handler]]
            if let matcher {
                group["matcher"] = matcher
            }
            groups.append(group)
            hooks[eventName] = groups
        }

        root["hooks"] = hooks
        guard !files.jsonObjectsEqual(original, root) else { return nil }
        let backup = try files.backupIfPresent(url)
        try files.writeJSONObject(root, to: url)
        return backup
    }

    func removeOwnedHooks(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        var root = try files.readJSONObject(at: url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        var changed = false

        for eventName in Array(hooks.keys) {
            guard let groups = hooks[eventName] as? [[String: Any]] else {
                continue
            }
            let cleaned = removeOwnedHandlers(from: groups)
            if !files.jsonObjectsEqual(groups, cleaned) {
                changed = true
            }
            if cleaned.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = cleaned
            }
        }

        guard changed else { return }
        root["hooks"] = hooks
        _ = try files.backupIfPresent(url)
        try files.writeJSONObject(root, to: url)
    }

    func containsOwnedHook(at url: URL) -> Bool {
        guard let root = try? files.readJSONObject(at: url),
              let hooks = root["hooks"] as? [String: Any]
        else {
            return false
        }
        return hooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    return false
                }
                return handlers.contains(where: isOwnedHandler)
            }
        }
    }

    func missingHookEvents(
        at url: URL,
        provider: AgentProvider
    ) -> [String] {
        guard fileManager.isExecutableFile(atPath: hookExecutablePath),
              let root = try? files.readJSONObject(at: url),
              let hooks = root["hooks"] as? [String: Any]
        else {
            return hookEvents(for: provider).map { $0.0 }
        }
        let expectedCommand = hookCommand(provider: provider)
        return hookEvents(for: provider).compactMap { eventName, expectedMatcher in
            guard let groups = hooks[eventName] as? [[String: Any]] else {
                return eventName
            }
            let hasExactHandler = groups.contains { group in
                guard group["matcher"] as? String == expectedMatcher else {
                    return false
                }
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    return false
                }
                return handlers.contains { handler in
                    isOwnedHandler(handler)
                        && handler["type"] as? String == "command"
                        && handler["command"] as? String == expectedCommand
                }
            }
            return hasExactHandler ? nil : eventName
        }
    }

    private func hookEvents(
        for provider: AgentProvider
    ) -> [(String, String?)] {
        switch provider {
        case .codex:
            [
                ("SessionStart", "startup|resume|clear|compact"),
                ("UserPromptSubmit", nil),
                ("PermissionRequest", nil),
                ("PreToolUse", "^request_user_input$"),
                ("Stop", nil),
                ("SessionEnd", nil),
            ]
        case .claude:
            [
                ("SessionStart", "startup|resume|clear|compact"),
                ("UserPromptSubmit", nil),
                ("PermissionRequest", nil),
                ("PreToolUse", "^(AskUserQuestion|ExitPlanMode)$"),
                ("Notification", "idle_prompt|elicitation_dialog|agent_needs_input"),
                ("Stop", nil),
                ("StopFailure", nil),
                ("SessionEnd", nil),
            ]
        }
    }

    private func removeOwnedHandlers(
        from groups: [[String: Any]]
    ) -> [[String: Any]] {
        groups.compactMap { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else {
                return group
            }
            let filtered = handlers.filter { !isOwnedHandler($0) }
            guard !filtered.isEmpty else { return nil }
            var updated = group
            updated["hooks"] = filtered
            return updated
        }
    }

    private func isOwnedHandler(_ handler: [String: Any]) -> Bool {
        if handler["turnringOwner"] as? String == "com.turnring.app" {
            return true
        }
        guard let command = handler["command"] as? String else { return false }
        let pattern = #"^"[^"]*/TurnringHook"\s+--provider\s+(codex|claude)$"#
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    private func hookCommand(provider: AgentProvider) -> String {
        let quotedPath = "'"
            + hookExecutablePath.replacingOccurrences(
                of: "'",
                with: "'\"'\"'"
            )
            + "'"
        return "\(quotedPath) --provider \(provider.rawValue)"
    }
}
