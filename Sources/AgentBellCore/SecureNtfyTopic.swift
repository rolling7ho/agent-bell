import Foundation
import Security

public enum SecureNtfyTopicError: LocalizedError, Equatable {
    case randomGenerationFailed(OSStatus)

    public var errorDescription: String? {
        "AgentBell could not generate a secure ntfy topic."
    }
}

public enum SecureNtfyTopic {
    public static let entropyByteCount = 32
    public static let prefix = "agentbell-"

    public static func generate() throws -> String {
        var entropy = [UInt8](repeating: 0, count: entropyByteCount)
        let status = entropy.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(
                kSecRandomDefault,
                buffer.count,
                buffer.baseAddress!
            )
        }
        guard status == errSecSuccess else {
            throw SecureNtfyTopicError.randomGenerationFailed(status)
        }
        return topic(fromEntropy: entropy)!
    }

    public static func topic(fromEntropy entropy: [UInt8]) -> String? {
        guard entropy.count == entropyByteCount else { return nil }
        return prefix + entropy.map {
            String(format: "%02x", $0)
        }.joined()
    }

    public static func migratableTopic(_ value: String?) -> String? {
        guard let value, isGeneratedTopic(value) else { return nil }
        return value
    }

    public static func isGeneratedTopic(_ value: String) -> Bool {
        guard value.hasPrefix(prefix),
              value.utf8.count == prefix.utf8.count + entropyByteCount * 2
        else {
            return false
        }
        return value.dropFirst(prefix.count).allSatisfy {
            $0.isNumber || ("a"..."f").contains(String($0))
        }
    }
}
