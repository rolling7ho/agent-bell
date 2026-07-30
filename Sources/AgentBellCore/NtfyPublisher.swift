import CryptoKit
import Foundation

public enum NtfyPriority: Int, Codable, Sendable {
    case `default` = 3
    case high = 4
    case urgent = 5
}

public struct NtfyMessage: Codable, Equatable, Sendable {
    public var title: String
    public var message: String
    public var priority: NtfyPriority
    public var tags: [String]
    public var sequenceID: String?

    public init(
        title: String,
        message: String,
        priority: NtfyPriority,
        tags: [String],
        sequenceID: String? = nil
    ) {
        self.title = Self.cleaned(title, limit: 160)
        self.message = Self.cleaned(message, limit: 240)
        self.priority = priority
        self.tags = tags.prefix(4).compactMap {
            let safe = Self.cleaned($0, limit: 32)
            return safe.isEmpty ? nil : safe
        }
        self.sequenceID = sequenceID.flatMap(Self.safeSequenceID)
    }

    private static func cleaned(_ value: String, limit: Int) -> String {
        AgentBellSafeText.redacted(
            AgentBellSafeText.collapsed(
                value,
                maximumCharacters: limit
            )
        )
    }

    public static func opaqueSequenceID(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "agentbell-" + digest.prefix(16).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func safeSequenceID(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
        return value.allSatisfy {
            $0.isLetter || $0.isNumber || "._:-".contains($0)
        } ? value : nil
    }
}

public enum NtfyPublishError: LocalizedError, Equatable {
    case invalidServerURL
    case invalidTopic
    case invalidAccessToken
    case invalidResponse
    case rejected(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "The ntfy server URL is invalid."
        case .invalidTopic:
            "The ntfy topic is invalid."
        case .invalidAccessToken:
            "The ntfy access token is invalid."
        case .invalidResponse:
            "The ntfy server returned an invalid response."
        case .rejected(let statusCode):
            "The ntfy server rejected the alert (HTTP \(statusCode))."
        }
    }
}

public enum NtfyRequestBuilder {
    private struct Payload: Encodable {
        var topic: String
        var title: String
        var message: String
        var priority: Int
        var tags: [String]
        var sequenceID: String?

        enum CodingKeys: String, CodingKey {
            case topic
            case title
            case message
            case priority
            case tags
            case sequenceID = "sequence_id"
        }
    }

    public static func makeRequest(
        serverURL: String,
        topic: String,
        message: NtfyMessage,
        accessToken: String? = nil
    ) throws -> URLRequest {
        let trimmedServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedServerURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw NtfyPublishError.invalidServerURL
        }
        if components.path.isEmpty {
            components.path = "/"
        } else if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        guard let url = components.url else {
            throw NtfyPublishError.invalidServerURL
        }
        guard isValidTopic(topic) else {
            throw NtfyPublishError.invalidTopic
        }
        if let accessToken,
           !isValidAccessToken(accessToken)
        {
            throw NtfyPublishError.invalidAccessToken
        }

        let payload = Payload(
            topic: topic,
            title: message.title,
            message: message.message,
            priority: message.priority.rawValue,
            tags: message.tags,
            sequenceID: message.sequenceID
        )
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue(
                "Bearer \(accessToken)",
                forHTTPHeaderField: "Authorization"
            )
        }
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    public static func isValidTopic(_ topic: String) -> Bool {
        guard (16...64).contains(topic.utf8.count) else { return false }
        return topic.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    public static func isValidAccessToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.utf8.count <= 512 else { return false }
        return token.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }
}

public actor NtfyPublisher {
    public init() {}

    public static func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NtfyPublishError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NtfyPublishError.rejected(statusCode: httpResponse.statusCode)
        }
    }

    public func publish(
        serverURL: String,
        topic: String,
        message: NtfyMessage,
        accessToken: String? = nil
    ) async throws {
        let request = try NtfyRequestBuilder.makeRequest(
            serverURL: serverURL,
            topic: topic,
            message: message,
            accessToken: accessToken
        )
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response)
    }
}
