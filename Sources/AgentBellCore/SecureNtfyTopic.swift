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
    public static let encodedEntropyCharacterCount = 43

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
        let encodedEntropy = Data(entropy)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "=")
            )
        guard encodedEntropy.utf8.count == encodedEntropyCharacterCount else {
            return nil
        }
        return prefix + encodedEntropy
    }

    public static func migratableTopic(_ value: String?) -> String? {
        guard let value, isGeneratedTopic(value) else { return nil }
        return value
    }

    public static func isGeneratedTopic(_ value: String) -> Bool {
        guard value.hasPrefix(prefix),
              value.utf8.count
                == prefix.utf8.count + encodedEntropyCharacterCount
        else {
            return false
        }

        let encodedEntropy = String(value.dropFirst(prefix.count))
        guard encodedEntropy.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }) else {
            return false
        }

        let base64 = encodedEntropy
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(
                repeating: "=",
                count: (4 - encodedEntropy.utf8.count % 4) % 4
            )
        guard let entropy = Data(base64Encoded: base64),
              entropy.count == entropyByteCount
        else {
            return false
        }
        return topic(fromEntropy: Array(entropy)) == value
    }
}
