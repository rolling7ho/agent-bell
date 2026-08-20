import XCTest
@testable import TurnringCore

final class SingleInstanceLockTests: XCTestCase {
    func testOnlyOneExclusiveInstanceCanOwnLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurnringLockTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("instance.lock")
        defer { try? FileManager.default.removeItem(at: directory) }

        var first: SingleInstanceLock? = SingleInstanceLock(url: url)
        XCTAssertNotNil(first)
        XCTAssertNil(SingleInstanceLock(url: url))

        first = nil
        XCTAssertNotNil(SingleInstanceLock(url: url))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
