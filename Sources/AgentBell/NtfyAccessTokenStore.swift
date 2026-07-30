import AgentBellCore
import Foundation
import Security

enum NtfyAccessTokenStoreError: LocalizedError {
    case invalidToken
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            "The ntfy access token contains unsupported characters."
        case .keychain:
            "AgentBell could not update the ntfy token in macOS Keychain."
        }
    }
}

final class NtfyAccessTokenStore {
    private let service = "com.agentbell.app.ntfy"
    private let account = "publish-access-token"

    func loadToken() throws -> String? {
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
              let token = String(data: data, encoding: .utf8),
              NtfyRequestBuilder.isValidAccessToken(token)
        else {
            throw NtfyAccessTokenStoreError.keychain(status)
        }
        return token
    }

    func hasToken() -> Bool {
        (try? loadToken()) != nil
    }

    func saveToken(_ value: String) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NtfyRequestBuilder.isValidAccessToken(token),
              let data = token.data(using: .utf8)
        else {
            throw NtfyAccessTokenStoreError.invalidToken
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw NtfyAccessTokenStoreError.keychain(updateStatus)
        }

        var item = baseQuery
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NtfyAccessTokenStoreError.keychain(addStatus)
        }
    }

    func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NtfyAccessTokenStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
