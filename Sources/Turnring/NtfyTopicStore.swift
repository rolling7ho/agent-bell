import TurnringCore
import Foundation
import Security

enum NtfyTopicStoreError: LocalizedError {
    case invalidStoredTopic
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredTopic:
            "The private ntfy topic stored in Keychain is invalid."
        case .keychain:
            "Turnring could not access the private ntfy topic in Keychain."
        }
    }
}

final class NtfyTopicStore {
    private let service = "com.turnring.app.ntfy"
    private let account = "private-topic"

    func loadOrCreate(migrating legacyTopic: String?) throws -> String {
        for attempt in 0..<3 {
            if let existing = try loadStoredTopic() {
                if SecureNtfyTopic.isGeneratedTopic(existing) {
                    return existing
                }
                try deleteTopic()
            }

            let candidate = try (
                attempt == 0
                    ? SecureNtfyTopic.migratableTopic(legacyTopic)
                        ?? SecureNtfyTopic.generate()
                    : SecureNtfyTopic.generate()
            )
            guard let data = candidate.data(using: .utf8) else {
                throw NtfyTopicStoreError.invalidStoredTopic
            }

            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecSuccess {
                return candidate
            }
            guard status == errSecDuplicateItem else {
                throw NtfyTopicStoreError.keychain(status)
            }
        }
        throw NtfyTopicStoreError.invalidStoredTopic
    }

    func deleteTopic() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NtfyTopicStoreError.keychain(status)
        }
    }

    private func loadStoredTopic() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let topic = String(data: data, encoding: .utf8)
        else {
            if status == errSecSuccess {
                throw NtfyTopicStoreError.invalidStoredTopic
            }
            throw NtfyTopicStoreError.keychain(status)
        }
        return topic
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
