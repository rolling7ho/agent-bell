import XCTest
@testable import AgentBellCore

final class PathsTests: XCTestCase {
    func testCleanupRemovesOnlyOldOwnedRuntimeFileTypes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBellPathsTests-\(UUID().uuidString)")
        let requests = root.appendingPathComponent("focus")
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(
            at: requests,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: scripts,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let oldRequest = requests.appendingPathComponent("old.json")
        let freshRequest = requests.appendingPathComponent("fresh.json")
        let unrelated = requests.appendingPathComponent("keep.txt")
        let oldScript = scripts.appendingPathComponent("old.command")
        for url in [oldRequest, freshRequest, unrelated, oldScript] {
            try Data("test".utf8).write(to: url)
        }
        let now = Date(timeIntervalSince1970: 10_000)
        let old = now.addingTimeInterval(-7_200)
        try FileManager.default.setAttributes(
            [.modificationDate: old],
            ofItemAtPath: oldRequest.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: old],
            ofItemAtPath: unrelated.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: old],
            ofItemAtPath: oldScript.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: freshRequest.path
        )

        let removed = AgentBellPaths.cleanupStaleRuntimeFiles(
            now: now,
            maximumAge: 3_600,
            directories: [
                (requests, "json"),
                (scripts, "command"),
            ]
        )

        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRequest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldScript.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshRequest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCleanupDoesNotFollowSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBellPathsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        let link = root.appendingPathComponent("request.json")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        XCTAssertEqual(
            AgentBellPaths.cleanupStaleRuntimeFiles(
                now: Date.distantFuture,
                maximumAge: 0,
                directories: [(root, "json")]
            ),
            0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }
}
