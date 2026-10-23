import Foundation
import Security

/// The GitHub token, as one generic-password item in the data-protection keychain, in the
/// keychain access group both the app and the widget carry in their entitlements. The item's
/// comment records where the token came from ("pasted" or "gh").
enum TokenStore {
    static let accessGroup = "R9KR5T3WZB.com.jashvantsewmangal.prwatch"
    static let service = "PR Watch GitHub token"
    static let account = "github"

    struct Stored {
        let token: String
        let source: String
    }

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain: \(text) (\(status))"
        }
    }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// Nil when no token is stored; throws when the keychain refuses (an entitlement problem).
    static func load() throws -> Stored? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return Stored(token: token, source: dict[kSecAttrComment as String] as? String ?? "pasted")
    }

    static func save(token: String, source: String) throws {
        try delete()
        var attributes = base
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = "PR Watch (GitHub)"
        attributes[kSecAttrComment as String] = source
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// "keychain: pasted", "keychain: gh", "keychain: empty" or the error, for the diagnostics line.
    static var diagnostics: String {
        do {
            guard let stored = try load() else { return "keychain: empty" }
            return "keychain: \(stored.source)"
        } catch {
            return error.localizedDescription
        }
    }
}
