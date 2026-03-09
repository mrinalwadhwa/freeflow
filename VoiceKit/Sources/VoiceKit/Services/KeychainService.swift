import Foundation
import Security

/// Store and retrieve session credentials from the macOS Keychain.
///
/// Each item is stored under the service name `com.buildtrust.voice`
/// with a distinct account key. The session token and service URL are
/// stored as separate items so they can be updated independently.
public final class KeychainService: @unchecked Sendable {

    private let service: String

    /// Account keys for distinct Keychain items.
    private enum Account {
        static let sessionToken = "session-token"
        static let serviceURL = "service-url"
    }

    public init(service: String = "com.buildtrust.voice") {
        self.service = service
    }

    // MARK: - Session token

    /// Save a session token to the Keychain.
    ///
    /// Overwrites any existing token. The token is stored as generic
    /// password data, accessible when the device is unlocked.
    @discardableResult
    public func saveSessionToken(_ token: String) -> Bool {
        save(value: token, account: Account.sessionToken)
    }

    /// Retrieve the stored session token, or nil if none exists.
    public func sessionToken() -> String? {
        load(account: Account.sessionToken)
    }

    /// Delete the stored session token.
    @discardableResult
    public func deleteSessionToken() -> Bool {
        delete(account: Account.sessionToken)
    }

    // MARK: - Service URL

    /// Save the service URL to the Keychain.
    @discardableResult
    public func saveServiceURL(_ url: String) -> Bool {
        save(value: url, account: Account.serviceURL)
    }

    /// Retrieve the stored service URL, or nil if none exists.
    public func serviceURL() -> String? {
        load(account: Account.serviceURL)
    }

    /// Delete the stored service URL.
    @discardableResult
    public func deleteServiceURL() -> Bool {
        delete(account: Account.serviceURL)
    }

    // MARK: - Bulk operations

    /// Delete all stored credentials (token and URL).
    public func deleteAll() {
        deleteSessionToken()
        deleteServiceURL()
    }

    // MARK: - Private helpers

    private func save(value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first to avoid errSecDuplicateItem.
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    @discardableResult
    private func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
