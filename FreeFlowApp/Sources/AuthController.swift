import AuthenticationServices

/// Manage the Autonomy Account login flow using ASWebAuthenticationSession.
///
/// Opens a system browser sheet for Autonomy Account signup/login. The Autonomy
/// callback redirects to `freeflow://auth/ready?token=<base64_token>`,
/// which ASWebAuthenticationSession intercepts and returns via its
/// completion handler.
///
/// Usage:
///   let controller = AuthController()
///   let token = try await controller.login()
@MainActor
final class AuthController: NSObject, ASWebAuthenticationPresentationContextProviding {

    /// The active authentication session, retained to prevent deallocation.
    private var authSession: ASWebAuthenticationSession?

    /// Base URL of the Autonomy service that hosts the sign-in page.
    private let autonomyURL: String

    /// Create an auth controller.
    ///
    /// - Parameter autonomyURL: Override the Autonomy base URL for
    ///   testing against a local stub server.
    init(autonomyURL: String = "https://my.autonomy.computer") {
        self.autonomyURL = autonomyURL
        super.init()
    }

    // MARK: - Login

    /// Start the Autonomy Account login flow and return the session token.
    ///
    /// Opens a system browser sheet where the user signs in with their
    /// Autonomy Account (email or GitHub OAuth). On success, Autonomy redirects to
    /// `freeflow://auth/ready?token=...` and the session token is
    /// extracted from the callback URL.
    ///
    /// - Returns: The Autonomy session token (base64-encoded).
    /// - Throws: `AuthControllerError` on cancellation, failure, or
    ///   invalid callback.
    func login() async throws -> String {
        guard let url = URL(string: "\(autonomyURL)/signin?state=app%3Dfreeflow") else {
            throw AuthControllerError.authFailed("Invalid Autonomy URL")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "freeflow"
            ) { [weak self] callbackURL, error in
                // Clear the retained session reference.
                self?.authSession = nil

                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                        nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                    {
                        continuation.resume(throwing: AuthControllerError.userCancelled)
                    } else {
                        continuation.resume(
                            throwing: AuthControllerError.authFailed(error.localizedDescription)
                        )
                    }
                    return
                }

                guard let callbackURL = callbackURL else {
                    continuation.resume(throwing: AuthControllerError.invalidCallback)
                    return
                }

                guard
                    let components = URLComponents(
                        url: callbackURL,
                        resolvingAgainstBaseURL: false
                    )
                else {
                    continuation.resume(throwing: AuthControllerError.invalidCallback)
                    return
                }

                guard components.scheme == "freeflow",
                    components.host == "auth"
                else {
                    continuation.resume(throwing: AuthControllerError.invalidCallback)
                    return
                }

                guard
                    let token = components.queryItems?
                        .first(where: { $0.name == "token" })?.value,
                    !token.isEmpty
                else {
                    continuation.resume(throwing: AuthControllerError.invalidCallback)
                    return
                }

                continuation.resume(returning: token)
            }

            session.presentationContextProvider = self
            // Preserve cookies so returning users stay logged in.
            // Override with FREEFLOW_EPHEMERAL_AUTH=1 to force a fresh
            // login screen every time (useful for testing).
            #if DEBUG
                let ephemeral =
                    ProcessInfo.processInfo.environment["FREEFLOW_EPHEMERAL_AUTH"] == "1"
                session.prefersEphemeralWebBrowserSession = ephemeral
            #endif

            self.authSession = session

            if !session.start() {
                self.authSession = nil
                continuation.resume(
                    throwing: AuthControllerError.authFailed(
                        "Failed to start authentication session"
                    )
                )
            }
        }
    }

    /// Cancel any in-progress authentication session.
    func cancel() {
        authSession?.cancel()
        authSession = nil
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        // Attach the browser sheet to the key window (the onboarding
        // window) or fall back to any available window.
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - Errors

/// Errors from the Autonomy Account login flow.
enum AuthControllerError: Error, LocalizedError {
    /// The user dismissed the login sheet.
    case userCancelled
    /// Autonomy returned an error.
    case authFailed(String)
    /// The callback URL was missing or did not contain a valid token.
    case invalidCallback

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Login was cancelled"
        case .authFailed(let message):
            return "Login failed: \(message)"
        case .invalidCallback:
            return "Invalid login response"
        }
    }
}
