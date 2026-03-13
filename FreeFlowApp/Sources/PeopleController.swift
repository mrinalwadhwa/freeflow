import AppKit
import FreeFlowKit

/// Coordinate the People web page with native services.
///
/// Follows the same pattern as `SettingsController`: owns a bridge
/// and a window, wires bridge actions to native service calls, and
/// pushes state back to the web page via bridge events.
///
/// The People page shows team management: pending invites and people
/// using the FreeFlow. Data comes from two sources: the Autonomy
/// orchestrator (billing state) and the zone admin API (invites and
/// users). All network calls are made from the native side; the web
/// page is a pure UI shell.
@MainActor
final class PeopleController {

    private let bridge: PeopleBridge
    private let config: ServiceConfig
    private let keychain: KeychainService
    private var window: PeopleWindow?

    /// Callback invoked when the user taps "Add credit card" in the
    /// locked state. The AppDelegate should wire this to open the
    /// provisioning billing flow.
    var onOpenBilling: (() -> Void)?

    /// Optional fallback email for the signed-in admin from the
    /// Autonomy account. Used when the zone admin record still has
    /// a placeholder email.
    var adminFallbackEmail: String? {
        keychain.autonomyEmail()
    }

    // MARK: - Initialization

    init(
        config: ServiceConfig = .shared,
        keychain: KeychainService = KeychainService()
    ) {
        self.config = config
        self.keychain = keychain
        self.bridge = PeopleBridge()

        setupBridgeHandlers()
    }

    // MARK: - Window management

    /// Show the People window, creating it if necessary.
    ///
    /// Navigates to the `/people/` page on the zone. If the window
    /// already exists, it brings it to the front and refreshes state.
    func showWindow() {
        if let existingWindow = window {
            existingWindow.navigate(baseURL: config.baseURL)
            existingWindow.present()
            return
        }

        let win = PeopleWindow(bridge: bridge)
        bridge.webView = win.webView
        window = win

        win.navigate(baseURL: config.baseURL)
        win.present()
    }

    /// Close the People window.
    func closeWindow() {
        window?.orderOut(nil)
    }

    /// Whether the People window is currently visible.
    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - Bridge wiring

    private func setupBridgeHandlers() {
        bridge.onGetPeopleState = { [weak self] in
            self?.handleGetPeopleState()
        }

        bridge.onCreateInvite = { [weak self] name, email in
            self?.handleCreateInvite(name: name, email: email)
        }

        bridge.onRevokeInvite = { [weak self] id in
            self?.handleRevokeInvite(id: id)
        }

        bridge.onCopyText = { [weak self] text in
            self?.handleCopyText(text: text)
        }

        bridge.onRemovePerson = { [weak self] id in
            self?.handleRemovePerson(id: id)
        }

        bridge.onOpenBilling = { [weak self] in
            self?.onOpenBilling?()
        }

        bridge.onClosePeople = { [weak self] in
            self?.closeWindow()
        }
    }

    // MARK: - Action: getPeopleState

    private func handleGetPeopleState() {
        Task {
            do {
                // Fetch hasCreditCard from the Autonomy orchestrator.
                let hasCreditCard = await fetchHasCreditCard()

                // Fetch invites and people from the zone admin API.
                let invites = try await fetchInvites()
                let people = try await fetchPeople()

                bridge.pushPeopleState(
                    hasCreditCard: hasCreditCard,
                    invites: invites,
                    people: people
                )
            } catch {
                Log.debug("[PeopleController] getPeopleState failed: \(error)")
                bridge.pushPageError(message: "Failed to load data. Please try again.")
            }
        }
    }

    // MARK: - Action: createInvite

    private func handleCreateInvite(name: String?, email: String?) {
        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedEmail.isEmpty else {
            bridge.pushActionError(message: "Email is required to create an invite.")
            return
        }

        Task {
            do {
                let invite = try await createInvite(name: name, email: normalizedEmail)
                bridge.pushInviteCreated(invite: invite)
            } catch {
                Log.debug("[PeopleController] createInvite failed: \(error)")
                bridge.pushActionError(message: "Failed to create invite. Please try again.")
            }
        }
    }

    // MARK: - Action: revokeInvite

    private func handleRevokeInvite(id: Int) {
        Task {
            do {
                try await revokeInvite(id: id)
                bridge.pushInviteRevoked(id: id)
                bridge.pushToast(message: "Invite revoked")
            } catch {
                Log.debug("[PeopleController] revokeInvite failed: \(error)")
                bridge.pushActionError(message: "Failed to revoke invite. Please try again.")
            }
        }
    }

    // MARK: - Action: copyText

    private func handleCopyText(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        bridge.pushToast(message: "Link copied to clipboard")
    }

    // MARK: - Action: removePerson

    private func handleRemovePerson(id: String) {
        Task {
            do {
                try await removePerson(id: id)
                let people = try await fetchPeople()
                bridge.pushPeopleState(
                    hasCreditCard: await fetchHasCreditCard(),
                    invites: try await fetchInvites(),
                    people: people
                )
                bridge.pushToast(message: "Person removed")
            } catch {
                Log.debug("[PeopleController] removePerson failed: \(error)")
                bridge.pushActionError(message: "Failed to remove person. Please try again.")
            }
        }
    }

    // MARK: - Orchestrator API

    /// Fetch the `has_credit_card` flag from the Autonomy orchestrator.
    ///
    /// Uses the Autonomy token stored in the Keychain. Returns false
    /// if the token is missing or the request fails.
    private func fetchHasCreditCard() async -> Bool {
        guard let token = keychain.autonomyToken() else {
            Log.debug("[PeopleController] No Autonomy token, assuming no credit card")
            return false
        }

        let client = AutonomyClient(token: token)
        do {
            let status = try await client.status()
            return status.hasCreditCard ?? false
        } catch {
            Log.debug("[PeopleController] Failed to fetch Autonomy status: \(error)")
            return false
        }
    }

    // MARK: - Zone Admin API

    /// Fetch the invite list from the zone admin API.
    ///
    /// Returns an array of invite dictionaries suitable for passing
    /// through the bridge to JavaScript.
    private func fetchInvites() async throws -> [[String: Any]] {
        let data = try await zoneAdminRequest(method: "GET", path: "/admin/api/invites")

        guard let invites = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        // Normalize field names for JS (camelCase).
        // The server now provides invite_url and status directly.
        return invites.map { inv -> [String: Any] in
            var result = inv

            // Map invite_url to inviteUrl for JS.
            if let inviteUrl = inv["invite_url"] as? String {
                result["inviteUrl"] = inviteUrl
            } else {
                result["inviteUrl"] = ""
            }

            // Server provides status; copy it if present.
            // (status is already a string, no conversion needed)

            // Normalize snake_case to camelCase for JS.
            result["maxUses"] = inv["max_uses"] as? Int ?? 1
            result["useCount"] = inv["use_count"] as? Int ?? 0
            result["createdAt"] = inv["created_at"]
            result["expiresAt"] = inv["expires_at"]

            return result
        }
    }

    /// Fetch the people list from the zone admin API.
    private func fetchPeople() async throws -> [[String: Any]] {
        let data = try await zoneAdminRequest(method: "GET", path: "/admin/api/users")

        guard let users = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        // Normalize field names for JS (camelCase) and improve admin identity
        // display when the zone admin still has a placeholder email.
        return users.map { user -> [String: Any] in
            var result = user
            let isAdmin = user["is_admin"] as? Bool ?? false
            let hasEmail = user["has_email"] as? Bool ?? false
            let currentEmail = user["email"] as? String
            let currentName = user["name"] as? String

            if isAdmin, !hasEmail, let fallbackEmail = adminFallbackEmail, !fallbackEmail.isEmpty {
                result["email"] = fallbackEmail
                result["has_email"] = true
                if currentName == nil || currentName == "Admin" {
                    result["name"] = fallbackEmail
                }
            } else if isAdmin, let currentEmail, !currentEmail.isEmpty,
                currentName == nil || currentName == "Admin"
            {
                result["name"] = currentEmail
            }

            result["hasEmail"] = result["has_email"]
            result["isAdmin"] = result["is_admin"]
            result["createdAt"] = result["created_at"]
            return result
        }
    }

    /// Create an invite via the zone admin API.
    ///
    /// Returns the created invite dictionary including the token and
    /// derived invite URL.
    private func createInvite(name: String?, email: String?) async throws -> [String: Any] {
        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedEmail.isEmpty else {
            throw PeopleError.missingInviteEmail
        }

        var body: [String: Any] = [
            "max_uses": 1,
            "email": normalizedEmail,
        ]
        if let name, !name.isEmpty {
            body["label"] = name
        }

        let responseData = try await zoneAdminRequest(
            method: "POST",
            path: "/admin/api/invites",
            body: body
        )

        guard var invite = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else {
            throw PeopleError.invalidResponse
        }

        // Server now provides invite_url directly; map to camelCase.
        if let inviteUrl = invite["invite_url"] as? String {
            invite["inviteUrl"] = inviteUrl
        }

        // Echo back the name and email we sent.
        invite["name"] = name
        invite["email"] = email
        invite["createdAt"] = ISO8601DateFormatter().string(from: Date())
        invite["maxUses"] = 1
        invite["useCount"] = 0
        invite["revoked"] = false
        invite["status"] = "pending"

        return invite
    }

    /// Revoke an invite via the zone admin API.
    private func revokeInvite(id: Int) async throws {
        _ = try await zoneAdminRequest(
            method: "DELETE",
            path: "/admin/api/invites/\(id)"
        )
    }

    /// Remove a person via the zone admin API.
    private func removePerson(id: String) async throws {
        _ = try await zoneAdminRequest(
            method: "DELETE",
            path: "/admin/api/users/\(id)"
        )
    }

    // MARK: - Network helpers

    /// Make an authenticated request to a zone admin API endpoint.
    ///
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, DELETE).
    ///   - path: The API path (e.g. "/admin/api/invites").
    ///   - body: Optional JSON body dictionary.
    /// - Returns: The response data.
    /// - Throws: `PeopleError` on failure.
    @discardableResult
    private func zoneAdminRequest(
        method: String,
        path: String,
        body: [String: Any]? = nil
    ) async throws -> Data {
        let urlString = "\(config.baseURL)\(path)"
        guard let url = URL(string: urlString) else {
            throw PeopleError.invalidURL
        }

        guard let token = config.sessionToken, !token.isEmpty else {
            throw PeopleError.noSession
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PeopleError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            Log.debug(
                "[PeopleController] \(method) \(path) -> \(httpResponse.statusCode): \(detail)")
            throw PeopleError.serverError(statusCode: httpResponse.statusCode)
        }

        return data
    }

    // MARK: - Errors

    enum PeopleError: Error {
        case invalidURL
        case noSession
        case invalidResponse
        case missingInviteEmail
        case serverError(statusCode: Int)
    }
}
