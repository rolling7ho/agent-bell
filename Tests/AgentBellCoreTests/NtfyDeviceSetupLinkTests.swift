import XCTest
@testable import AgentBellCore

final class NtfyDeviceSetupLinkTests: XCTestCase {
    func testBuildsHTTPSTopicURL() {
        let url = NtfyDeviceSetupLink.makeURL(
            serverURL: "https://ntfy.sh",
            topic: "agentbell-AbCd1234_-"
        )

        XCTAssertEqual(
            url?.absoluteString,
            "https://ntfy.sh/agentbell-AbCd1234_-"
        )
    }

    func testRejectsInsecureOrCredentialedServers() {
        XCTAssertNil(
            NtfyDeviceSetupLink.makeURL(
                serverURL: "http://ntfy.sh",
                topic: "agentbell-AbCd1234_-"
            )
        )
        XCTAssertNil(
            NtfyDeviceSetupLink.makeURL(
                serverURL: "https://token@ntfy.sh",
                topic: "agentbell-AbCd1234_-"
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
