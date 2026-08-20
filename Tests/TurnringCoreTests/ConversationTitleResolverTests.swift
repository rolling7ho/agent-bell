import XCTest
@testable import TurnringCore

final class ConversationTitleResolverTests: XCTestCase {
    func testReadsCodexConversationTitleBySessionID() throws {
        let root = temporaryDirectory()
        let index = root.appendingPathComponent("session_index.jsonl")
        let claudeProjects = root.appendingPathComponent("claude-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeProjects, withIntermediateDirectories: true)
        let contents = """
        {"id":"other-session","thread_name":"Other title"}
        {"id":"codex-session","thread_name":"  Build   macOS\\ntracker app  "}
        """
        try Data(contents.utf8).write(to: index)

        let resolver = ConversationTitleResolver(
            codexSessionIndexURL: index,
            claudeProjectsURL: claudeProjects
        )

        XCTAssertEqual(
            resolver.title(
                provider: .codex,
                sessionID: "codex-session",
                cwd: root.path
            ),
            "Build macOS tracker app"
        )
    }

    func testReadsClaudeAITitleWithoutUsingPromptText() throws {
        let root = temporaryDirectory()
        let index = root.appendingPathComponent("session_index.jsonl")
        try Data().write(to: index)
        let claudeProjects = root.appendingPathComponent("claude-projects", isDirectory: true)
        let project = claudeProjects.appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("claude-session.jsonl")
        let contents = """
        {"type":"user","sessionId":"claude-session","message":{"content":"raw prompt must not become title"}}
        {"type":"ai-title","aiTitle":"Create site","sessionId":"claude-session"}
        """
        try Data(contents.utf8).write(to: transcript)

        let resolver = ConversationTitleResolver(
            codexSessionIndexURL: index,
            claudeProjectsURL: claudeProjects
        )

        XCTAssertEqual(
            resolver.title(
                provider: .claude,
                sessionID: "claude-session",
                cwd: "/tmp/project"
            ),
            "Create site"
        )
    }

    func testReadsRecentCodexTitleFromLargeIndexTail() throws {
        let root = temporaryDirectory()
        let index = root.appendingPathComponent("session_index.jsonl")
        let filler = String(
            repeating: #"{"id":"old","thread_name":"Old"}"# + "\n",
            count: 40_000
        )
        let recent = #"{"id":"recent-session","thread_name":"Recent\u0000 title"}"# + "\n"
        try Data((filler + recent).utf8).write(to: index)
        let claudeProjects = root.appendingPathComponent(
            "claude-projects",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: claudeProjects,
            withIntermediateDirectories: true
        )
        let resolver = ConversationTitleResolver(
            codexSessionIndexURL: index,
            claudeProjectsURL: claudeProjects
        )

        XCTAssertEqual(
            resolver.title(
                provider: .codex,
                sessionID: "recent-session",
                cwd: root.path
            ),
            "Recent title"
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurnringTitleTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
