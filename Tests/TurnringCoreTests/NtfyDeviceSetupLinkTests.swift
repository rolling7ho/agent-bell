import XCTest
@testable import TurnringCore

final class NtfyDeviceSetupLinkTests: XCTestCase {
    func testBuildsHTTPSTopicURLForGeneratedTopic() throws {
        let topic = try XCTUnwrap(
            SecureNtfyTopic.topic(
                fromEntropy: Array(
                    repeating: 0,
                    count: SecureNtfyTopic.entropyByteCount
                )
            )
        )
        let url = NtfyDeviceSetupLink.makeURL(
            serverURL: "https://ntfy.sh",
            topic: topic
        )

        XCTAssertEqual(
            url?.absoluteString,
            "https://ntfy.sh/turnring-"
                + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
    }

    func testRejectsInsecureOrCredentialedServers() {
        XCTAssertNil(
            NtfyDeviceSetupLink.makeURL(
                serverURL: "http://ntfy.sh",
                topic: "turnring-AbCd1234_-"
            )
        )
        XCTAssertNil(
            NtfyDeviceSetupLink.makeURL(
                serverURL: "https://token@ntfy.sh",
                topic: "turnring-AbCd1234_-"
            )
        )
    }

    func testRejectsInvalidTopic() {
        XCTAssertNil(
            NtfyDeviceSetupLink.makeURL(
                serverURL: "https://ntfy.sh",
                topic: "contains spaces"
            )
        )
    }
}
