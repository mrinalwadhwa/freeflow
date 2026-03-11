import Foundation
import Security

/// Store and retrieve session credentials from the macOS Keychain.
///
/// Each item is stored under the service name `computer.autonomy.freeflow`
/// with a distinct account key. The session token and service URL are
/// stored as separate items so they can be updated independently.
public final class KeychainService: @unchecked Sendable {

    private let service: String

    /// Account keys for distinct Keychain items.
    private enum Account {
        static let sessionToken = "session-token"
        static let serviceURL = "service-url"
        static let autonomyToken = "autonomy-token"
    }

    public init(service: String = "computer.autonomy.freeflow") {
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

    // MARK: - Autonomy token

    /// Save the Autonomy session token to the Keychain.
    ///
    /// This token authenticates against the central Autonomy service
    /// (my.autonomy.computer) for provisioning and trial status checks.
    /// It is separate from the zone session token used for dictation.
    @discardableResult
    public func saveAutonomyToken(_ token: String) -> Bool {
        save(value: token, account: Account.autonomyToken)
    }

    /// Retrieve the stored Autonomy session token, or nil if none exists.
    public func autonomyToken() -> String? {
        load(account: Account.autonomyToken)
    }

    /// Delete the stored Autonomy session token.
    @discardableResult
    public func deleteAutonomyToken() -> Bool {
        delete(account: Account.autonomyToken)
    }

    // MARK: - Bulk operations

    /// Delete all stored credentials (tokens and URL).
    public func deleteAll() {
        deleteSessionToken()
        deleteServiceURL()
        deleteAutonomyToken()
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
