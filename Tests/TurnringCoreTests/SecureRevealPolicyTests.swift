import XCTest
@testable import TurnringCore

final class SecureRevealPolicyTests: XCTestCase {
    func testRevealDurationIsLimitedToSixtySeconds() {
        XCTAssertEqual(SecureRevealPolicy.maximumDuration, 60)
        XCTAssertEqual(
            SecureRevealPolicy.maximumDurationNanoseconds,
            60_000_000_000
        )
    }
}
