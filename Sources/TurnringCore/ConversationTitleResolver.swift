import Foundation

public struct ConversationTitleResolver: Sendable {
    private static let transcriptWindowBytes = 512 * 1_024
    private static let codexIndexWindowBytes = 1 * 1_024 * 1_024
    private static let maximumTitleCharacters = 80

    private let codexSessionIndexURL: URL
    private let claudeProjectsURL: URL

    public init(homeDirectory: URL = TurnringPaths.homeDirectory) {
        codexSessionIndexURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("session_index.jsonl")
        claudeProjectsURL = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    public init(codexSessionIndexURL: URL, claudeProjectsURL: URL) {
        self.codexSessionIndexURL = codexSessionIndexURL
        self.claudeProjectsURL = claudeProjectsURL
    }

    public func title(
        provider: AgentProvider,
        sessionID: String,
        cwd: String
    ) -> String? {
        guard TurnringValidation.isValidSessionID(sessionID) else { return nil }
        switch provider {
        case .codex:
            return codexTitle(sessionID: sessionID)
        case .claude:
            return claudeTitle(sessionID: sessionID, cwd: cwd)
        }
    }

    private func codexTitle(sessionID: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: codexSessionIndexURL)
        else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(Self.codexIndexWindowBytes)
            ? size - UInt64(Self.codexIndexWindowBytes)
            : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Self.codexIndexWindowBytes),
              let contents = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        var lines = contents.split(separator: "\n")
        if start > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        for line in lines.reversed() {
            guard let object = decodeObject(String(line)),
                  object["id"] as? String == sessionID,
                  let title = normalizedTitle(object["thread_name"] as? String)
            else {
                continue
            }
            return title
        }
        return nil
    }

    private func claudeTitle(sessionID: String, cwd: String) -> String? {
        let fileName = "\(sessionID).jsonl"
        let directProjectName = cwd.replacingOccurrences(of: "/", with: "-")
        let directURL = claudeProjectsURL
            .appendingPathComponent(directProjectName, isDirectory: true)
            .appendingPathComponent(fileName)

        if FileManager.default.isReadableFile(atPath: directURL.path) {
            return titleFromClaudeTranscript(directURL)
        }

        guard let projectDirectories = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for directory in projectDirectories.prefix(1_000) {
            let candidate = directory.appendingPathComponent(fileName)
            if FileManager.default.isReadableFile(atPath: candidate.path),
               let title = titleFromClaudeTranscript(candidate)
            {
                return title
            }
        }
        return nil
    }

    private func titleFromClaudeTranscript(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let tailStart = size > UInt64(Self.transcriptWindowBytes)
            ? size - UInt64(Self.transcriptWindowBytes)
            : 0
        try? handle.seek(toOffset: tailStart)
        if let tail = try? handle.read(upToCount: Self.transcriptWindowBytes),
           let title = latestClaudeTitle(in: tail, discardFirstPartialLine: tailStart > 0)
        {
            return title
        }

        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: Self.transcriptWindowBytes) else {
            return nil
        }
        return latestClaudeTitle(in: head, discardFirstPartialLine: false)
    }

    private func latestClaudeTitle(
        in data: Data,
        discardFirstPartialLine: Bool
    ) -> String? {
        guard let contents = String(data: data, encoding: .utf8) else { return nil }
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        if discardFirstPartialLine, !lines.isEmpty {
            lines.removeFirst()
        }

        for line in lines.reversed() {
            guard let object = decodeObject(String(line)),
                  let type = object["type"] as? String
            else {
                continue
            }
            if type == "custom-title",
               let title = normalizedTitle(object["customTitle"] as? String)
            {
                return title
            }
            if type == "ai-title",
               let title = normalizedTitle(object["aiTitle"] as? String)
            {
                return title
            }
        }
        return nil
    }

    private func decodeObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        return object as? [String: Any]
    }

    private func normalizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = TurnringSafeText.redacted(
            TurnringSafeText.collapsed(value)
        )
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > Self.maximumTitleCharacters else { return normalized }
        return String(normalized.prefix(Self.maximumTitleCharacters)) + "…"
    }
}
