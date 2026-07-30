import Foundation

public enum AbruptStopReason: String, Sendable {
    case rateLimit = "rate_limit"
    case networkError = "network_error"
    case authenticationFailed = "authentication_failed"
    case billingError = "billing_error"
    case invalidRequest = "invalid_request"
    case overloaded
    case modelNotFound = "model_not_found"
    case serverError = "server_error"
    case maxOutputTokens = "max_output_tokens"
    case unknown

    public init(providerError: String?) {
        switch providerError {
        case "rate_limit":
            self = .rateLimit
        case "network_error":
            self = .networkError
        case "authentication_failed", "oauth_org_not_allowed":
            self = .authenticationFailed
        case "billing_error":
            self = .billingError
        case "invalid_request":
            self = .invalidRequest
        case "overloaded":
            self = .overloaded
        case "model_not_found":
            self = .modelNotFound
        case "server_error":
            self = .serverError
        case "max_output_tokens":
            self = .maxOutputTokens
        default:
            self = .unknown
        }
    }

    public var fallbackPreview: String {
        switch self {
        case .rateLimit:
            "Rate limit reached."
        case .networkError:
            "Network connection was interrupted."
        case .authenticationFailed:
            "Authentication failed."
        case .billingError:
            "The provider stopped because of a billing error."
        case .invalidRequest:
            "The provider rejected the request."
        case .overloaded:
            "The provider is overloaded."
        case .modelNotFound:
            "The requested model was not found."
        case .serverError:
            "The provider stopped because of a server error."
        case .maxOutputTokens:
            "The task reached its output limit."
        case .unknown:
            "The provider stopped because of an API error."
        }
    }
}

public enum AbruptStopClassifier {
    public static func classifyCodexStop(
        message: String?
    ) -> AbruptStopReason? {
        guard let message else { return nil }
        let normalized = AgentBellSafeText.collapsed(
            message,
            maximumCharacters: 300
        ).lowercased()
        guard !normalized.isEmpty else { return nil }

        if hasErrorPrefix(normalized, matching: [
            "rate limit",
            "usage limit",
            "quota exceeded",
            "quota exhausted",
        ]) {
            return .rateLimit
        }
        if hasErrorPrefix(normalized, matching: [
            "network error",
            "connection lost",
            "connection reset",
            "disconnected from",
            "request timed out",
            "connection timed out",
        ]) {
            return .networkError
        }
        if hasErrorPrefix(normalized, matching: [
            "authentication failed",
            "unauthorized",
            "oauth error",
        ]) {
            return .authenticationFailed
        }
        if hasErrorPrefix(normalized, matching: [
            "server error",
            "service unavailable",
            "api overloaded",
        ]) {
            return .serverError
        }
        return nil
    }

    private static func hasErrorPrefix(
        _ message: String,
        matching signals: [String]
    ) -> Bool {
        let prefixes = [
            "",
            "api error: ",
            "error: ",
            "task stopped: ",
            "request failed: ",
        ]
        return signals.contains { signal in
            prefixes.contains { prefix in
                message.hasPrefix(prefix + signal)
            }
        }
    }
}
