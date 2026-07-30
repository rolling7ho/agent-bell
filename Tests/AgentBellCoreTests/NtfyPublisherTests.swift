import XCTest
@testable import AgentBellCore

final class NtfyPublisherTests: XCTestCase {
    func testSecureTopicUsesTwoHundredFiftySixBitsOfDeterministicEntropy() throws {
        let entropy = Array(0..<SecureNtfyTopic.entropyByteCount).map(UInt8.init)
        let topic = try XCTUnwrap(
            SecureNtfyTopic.topic(fromEntropy: entropy)
        )

        XCTAssertEqual(topic.count, SecureNtfyTopic.prefix.count + 64)
        XCTAssertTrue(SecureNtfyTopic.isGeneratedTopic(topic))
        XCTAssertTrue(NtfyRequestBuilder.isValidTopic(topic))
        XCTAssertEqual(
            topic,
            "agentbell-000102030405060708090a0b0c0d0e0f"
                + "101112131415161718191a1b1c1d1e1f"
        )
        XCTAssertNil(
            SecureNtfyTopic.topic(
                fromEntropy: Array(repeating: 0, count: 31)
            )
        )
    }

    func testSecureTopicGeneratorProducesDistinctValidTopics() throws {
        let first = try SecureNtfyTopic.generate()
        let second = try SecureNtfyTopic.generate()

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(SecureNtfyTopic.isGeneratedTopic(first))
        XCTAssertTrue(SecureNtfyTopic.isGeneratedTopic(second))
    }

    func testOnlyFullGeneratedTopicsCanBeMigrated() {
        let generated =
            "agentbell-0123456789abcdef0123456789abcdef"
            + "0123456789abcdef0123456789abcdef"

        XCTAssertEqual(
            SecureNtfyTopic.migratableTopic(generated),
            generated
        )
        XCTAssertNil(
            SecureNtfyTopic.migratableTopic(
                "agentbell-0123456789abcdef"
            )
        )
        XCTAssertNil(
            SecureNtfyTopic.migratableTopic(
                generated.uppercased()
            )
        )
        XCTAssertNil(SecureNtfyTopic.migratableTopic("shared-topic-name"))
        XCTAssertNil(SecureNtfyTopic.migratableTopic(nil))
    }

    func testBuildsHTTPSJSONRequestWithoutRoutingMetadata() throws {
        let message = NtfyMessage(
            title: "Codex Desktop • Build app",
            message: "Codex Desktop wants to read_file: README.md",
            priority: .high,
            tags: ["bell", "warning"],
            sequenceID: "agentbell-sequence-123"
        )

        let request = try NtfyRequestBuilder.makeRequest(
            serverURL: "https://ntfy.sh",
            topic: "agentbell-0123456789abcdef0123456789abcdef",
            message: message
        )

        XCTAssertEqual(request.url?.absoluteString, "https://ntfy.sh/")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json; charset=utf-8"
        )

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(
            payload["topic"] as? String,
            "agentbell-0123456789abcdef0123456789abcdef"
        )
        XCTAssertEqual(payload["title"] as? String, "Codex Desktop • Build app")
        XCTAssertEqual(
            payload["message"] as? String,
            "Codex Desktop wants to read_file: README.md"
        )
        XCTAssertEqual(payload["priority"] as? Int, 4)
        XCTAssertEqual(payload["sequence_id"] as? String, "agentbell-sequence-123")
        XCTAssertNil(payload["sessionID"])
        XCTAssertNil(payload["cwd"])
        XCTAssertNil(payload["provider"])
    }

    func testAccessTokenUsesAuthorizationHeaderAndNeverURLOrBody() throws {
        let token = "tk_example-private-token"
        let message = NtfyMessage(
            title: "AgentBell",
            message: "AgentBell is connected.",
            priority: .default,
            tags: []
        )

        let request = try NtfyRequestBuilder.makeRequest(
            serverURL: "https://ntfy.sh",
            topic: "agentbell-0123456789abcdef",
            message: message,
            accessToken: token
        )

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(token)"
        )
        XCTAssertFalse(request.url?.absoluteString.contains(token) == true)
        XCTAssertFalse(
            String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)?
                .contains(token) == true
        )
    }

    func testRejectsUnsafeAccessTokens() {
        let message = NtfyMessage(
            title: "AgentBell",
            message: "Connected",
            priority: .default,
            tags: []
        )
        for token in ["", "token with spaces", "token\nheader", String(repeating: "x", count: 513)] {
            XCTAssertThrowsError(
                try NtfyRequestBuilder.makeRequest(
                    serverURL: "https://ntfy.sh",
                    topic: "agentbell-0123456789abcdef",
                    message: message,
                    accessToken: token
                )
            ) { error in
                XCTAssertEqual(
                    error as? NtfyPublishError,
                    .invalidAccessToken
                )
            }
        }
    }

    func testRejectsInsecureOrCredentialedServerURLs() {
        let message = NtfyMessage(
            title: "Title",
            message: "Message",
            priority: .default,
            tags: []
        )
        let topic = "agentbell-0123456789abcdef"

        for serverURL in [
            "http://ntfy.sh",
            "https://user:password@ntfy.sh",
            "https://ntfy.sh/?token=secret",
            "not a url",
        ] {
            XCTAssertThrowsError(
                try NtfyRequestBuilder.makeRequest(
                    serverURL: serverURL,
                    topic: topic,
                    message: message
                )
            ) { error in
                XCTAssertEqual(error as? NtfyPublishError, .invalidServerURL)
            }
        }
    }

    func testRejectsShortOrUnsafeTopics() {
        XCTAssertFalse(NtfyRequestBuilder.isValidTopic("short"))
        XCTAssertFalse(NtfyRequestBuilder.isValidTopic("agentbell/topic with spaces"))
        XCTAssertTrue(
            NtfyRequestBuilder.isValidTopic("agentbell-0123456789abcdef")
        )
    }

    func testMessageCollapsesWhitespaceAndTruncatesUnicodeSafely() {
        let message = NtfyMessage(
            title: "  AgentBell \n phone test  ",
            message: String(repeating: "😀", count: 300),
            priority: .default,
            tags: Array(repeating: "bell", count: 8)
        )

        XCTAssertEqual(message.title, "AgentBell phone test")
        XCTAssertEqual(message.message.count, 240)
        XCTAssertEqual(message.message.last, "😀")
        XCTAssertEqual(message.tags.count, 4)
    }

    func testOpaqueSequenceIDIsStableAndDoesNotExposeInput() {
        let first = NtfyMessage.opaqueSequenceID(
            for: "codex:private-session:finished:123"
        )
        let second = NtfyMessage.opaqueSequenceID(
            for: "codex:private-session:finished:123"
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("agentbell-"))
        XCTAssertFalse(first.contains("private-session"))
        XCTAssertEqual(first.count, 42)
    }

    func testResponseValidationAcceptsSuccessAndRejectsRateLimitsAndServerErrors() throws {
        let url = try XCTUnwrap(URL(string: "https://ntfy.sh/"))
        let success = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        XCTAssertNoThrow(try NtfyPublisher.validate(response: success))

        for status in [400, 401, 403, 404, 429, 500, 503] {
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            XCTAssertThrowsError(
                try NtfyPublisher.validate(response: response)
            ) { error in
                XCTAssertEqual(
                    error as? NtfyPublishError,
                    .rejected(statusCode: status)
                )
            }
        }
    }

    func testResponseValidationRejectsNonHTTPResponse() throws {
        let url = try XCTUnwrap(URL(string: "https://ntfy.sh/"))
        XCTAssertThrowsError(
            try NtfyPublisher.validate(
                response: URLResponse(
                    url: url,
                    mimeType: nil,
                    expectedContentLength: 0,
                    textEncodingName: nil
                )
            )
        ) { error in
            XCTAssertEqual(error as? NtfyPublishError, .invalidResponse)
        }
    }
}
