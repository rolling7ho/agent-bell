import XCTest
@testable import AgentBellCore

final class SafeTextTests: XCTestCase {
    func testCentralRedactionRemovesCredentialsHomePathsAndEmail() {
        let value = AgentBellSafeText.redacted(
            "Authorization: Bearer tk_private /Users/ivan/Client /etc/passwd alice@example.com"
        )

        XCTAssertFalse(value.contains("tk_private"))
        XCTAssertFalse(value.contains("/Users/ivan/"))
        XCTAssertFalse(value.contains("/etc/passwd"))
        XCTAssertFalse(value.contains("alice@example.com"))
        XCTAssertTrue(value.contains("Authorization: Bearer ••••"))
        XCTAssertTrue(value.contains("~/Client"))
        XCTAssertTrue(value.contains("[email]"))
    }

    func testControlCharactersBecomeBoundariesInsteadOfJoiningWords() {
        XCTAssertEqual(
            AgentBellSafeText.collapsed("Build\u{0}macOS\napp\tcarefully"),
            "Build macOS app carefully"
        )
    }

    func testBidirectionalOverridesAreRemoved() {
        XCTAssertEqual(
            AgentBellSafeText.collapsed("safe\u{202E}gpj.exe\u{202C} name"),
            "safegpj.exe name"
        )
    }

    func testTruncationIsCharacterSafe() {
        XCTAssertEqual(
            AgentBellSafeText.collapsed(
                String(repeating: "😀", count: 6),
                maximumCharacters: 5,
                appendEllipsisWhenTruncated: true
            ),
            "😀😀😀😀…"
        )
    }
}
