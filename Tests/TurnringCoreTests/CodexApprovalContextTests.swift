import XCTest
@testable import TurnringCore

final class CodexApprovalContextTests: XCTestCase {
    func testReadsOnlyReviewerMetadataForMatchingTurn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = root.appendingPathComponent("session.jsonl")
        let unrelated = """
        {"type":"turn_context","payload":{"turn_id":"other","approvals_reviewer":"user"}}
        """
        let matching = """
        {"type":"turn_context","payload":{"turn_id":"turn-1","approvals_reviewer":"auto_review","prompt":"NEVER_RETAIN"}}
        """
        try Data("\(unrelated)\n\(matching)\n".utf8).write(to: transcript)

        let hookPayload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "turn_id": "turn-1",
            "transcript_path": transcript.path,
        ]
        let reviewer = CodexApprovalContextResolver.reviewer(
            fromHookPayload: try JSONSerialization.data(withJSONObject: hookPayload),
            allowedTranscriptRoots: [root]
        )

        XCTAssertEqual(reviewer, .automatic)
    }

    func testRejectsTranscriptOutsideAllowedRoots() throws {
        let allowedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: allowedRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: allowedRoot)
            try? FileManager.default.removeItem(at: outsideRoot)
        }

        let transcript = outsideRoot.appendingPathComponent("session.jsonl")
        try Data("""
        {"type":"turn_context","payload":{"turn_id":"turn-1","approvals_reviewer":"user"}}
        """.utf8).write(to: transcript)
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "turn_id": "turn-1",
            "transcript_path": transcript.path,
        ]

        XCTAssertNil(
            CodexApprovalContextResolver.reviewer(
                fromHookPayload: try JSONSerialization.data(withJSONObject: payload),
                allowedTranscriptRoots: [allowedRoot]
            )
        )
    }

    func testDirectReviewerTakesPrecedenceWithoutTranscriptRead() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "approvals_reviewer": "user",
            "turn_id": "turn-1",
            "transcript_path": "/not/allowed/session.jsonl",
        ]

        XCTAssertEqual(
            CodexApprovalContextResolver.reviewer(
                fromHookPayload: try JSONSerialization.data(withJSONObject: payload),
                allowedTranscriptRoots: []
            ),
            .user
        )
    }
}
