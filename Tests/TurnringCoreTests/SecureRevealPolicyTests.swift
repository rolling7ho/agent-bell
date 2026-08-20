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

    func testRecognizesKnownCaptureApplications() {
        XCTAssertTrue(
            SecureRevealPolicy.isKnownCaptureBundleIdentifier(
                "com.obsproject.obs-studio"
            )
        )
        XCTAssertTrue(
            SecureRevealPolicy.isKnownCaptureBundleIdentifier(
                "com.apple.screencaptureui"
            )
        )
        XCTAssertFalse(
            SecureRevealPolicy.isKnownCaptureBundleIdentifier(
                "com.turnring.app"
            )
        )
    }

    func testRecognizesMacScreenshotShortcuts() {
        XCTAssertTrue(
            SecureRevealPolicy.isScreenshotShortcut(
                command: true,
                shift: true,
                keyCode: 20
            )
        )
        XCTAssertFalse(
            SecureRevealPolicy.isScreenshotShortcut(
                command: true,
                shift: false,
                keyCode: 20
            )
        )
    }
}
