import Foundation
import Security

/// Store and retrieve the OpenAI API key from the macOS Keychain.
///
/// The key is stored as a generic password under the service name
/// `freeflow.app` with account `openai-api-key`, accessible when the
/// device is unlocked.
public final class KeychainService: @unchecked Sendable {

    private let service: String

    private enum Account {
        static let openAIAPIKey = "openai-api-key"
    }

    public init(service: String = "freeflow.app") {
        self.service = service
    }

    // MARK: - OpenAI API key

    /// Save the OpenAI API key to the Keychain, overwriting any existing value.
    @discardableResult
    public func saveOpenAIAPIKey(_ key: String) -> Bool {
        save(value: key, account: Account.openAIAPIKey)
    }

    /// Retrieve the stored OpenAI API key, or nil if none exists.
    public func openAIAPIKey() -> String? {
        load(account: Account.openAIAPIKey)
    }

    /// Delete the stored OpenAI API key.
    @discardableResult
    public func deleteOpenAIAPIKey() -> Bool {
        delete(account: Account.openAIAPIKey)
    }

    // MARK: - Legacy cleanup

    /// Delete any Keychain items left behind by the v0.1.0 server-backed
    /// build. The old build stored session tokens, zone URLs, and email
    /// addresses under the service name `computer.autonomy.freeflow`.
    /// None of those items are read by the current build, so they serve
    /// no purpose beyond cluttering the user's Keychain.
    public func purgeLegacyV01Items() {
        let legacyService = "computer.autonomy.freeflow"
        let legacyAccounts = [
            "session-token",
            "service-url",
            "autonomy-token",
            "user-email",
            "autonomy-email",
        ]
        for account in legacyAccounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account,
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
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
