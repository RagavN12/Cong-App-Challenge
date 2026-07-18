import Auth0
import Combine
import Foundation

struct AuthenticatedUser: Equatable, Sendable {
    let id: String
    let displayName: String
    let email: String?
    let pictureURL: URL?

    init(profile: UserProfile) {
        id = profile.sub
        displayName = profile.name
            ?? profile.nickname
            ?? profile.preferredUsername
            ?? profile.email
            ?? "EcoAI User"
        email = profile.email
        pictureURL = profile.picture
    }
}

protocol AccessTokenProviding: Sendable {
    func accessToken(minTTL: Int) async throws -> String
}

private struct Auth0Configuration: Sendable {
    let clientID: String
    let domain: String
    let audience: String

    static func load(bundle: Bundle = .main) -> Auth0Configuration? {
        guard let path = bundle.path(forResource: "Auth0", ofType: "plist"),
              let values = NSDictionary(contentsOfFile: path) as? [String: Any],
              let clientID = values["ClientId"] as? String,
              let domain = values["Domain"] as? String,
              let audience = values["Audience"] as? String,
              !clientID.isEmpty,
              !domain.isEmpty,
              !audience.isEmpty else {
            return nil
        }

        return Auth0Configuration(clientID: clientID, domain: domain, audience: audience)
    }
}

enum SessionStoreError: LocalizedError, Sendable {
    case notConfigured
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Auth0 has not been configured for this build."
        case .notAuthenticated:
            "Your session has expired. Please log in again."
        }
    }
}

/// App-scoped owner of Universal Login, Keychain credentials, refresh-token
/// renewal, and the authenticated user profile.
@MainActor
final class SessionStore: ObservableObject, AccessTokenProviding {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isRestoringSession = false
    @Published private(set) var isWorking = false
    @Published private(set) var user: AuthenticatedUser?
    @Published private(set) var errorMessage: String?

    private let configuration: Auth0Configuration?
    private let credentialsManager: CredentialsManager?

    init(bundle: Bundle = .main) {
        let configuration = Auth0Configuration.load(bundle: bundle)
        self.configuration = configuration

        guard let configuration else {
            credentialsManager = nil
            return
        }

        let authentication = Auth0.authentication(
            clientId: configuration.clientID,
            domain: configuration.domain
        )
        let manager = CredentialsManager(
            authentication: authentication,
            storeKey: "ecoai.auth0.credentials"
        )
        credentialsManager = manager
        isRestoringSession = manager.canRenew()
    }

    var isConfigured: Bool {
        configuration != nil && credentialsManager != nil
    }

    func restoreSession() async {
        guard isRestoringSession, let manager = credentialsManager else { return }
        defer { isRestoringSession = false }

        do {
            _ = try await manager.credentials(minTTL: 60)
            user = try manager.userProfile().map(AuthenticatedUser.init)
            isAuthenticated = true
        } catch {
            try? manager.clear()
            user = nil
            isAuthenticated = false
        }
    }

    func logIn() async {
        guard let configuration, let manager = credentialsManager else {
            errorMessage = SessionStoreError.notConfigured.localizedDescription
            return
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            _ = try await Auth0
                .webAuth(clientId: configuration.clientID, domain: configuration.domain)
                .scope("openid profile email offline_access chat:read chat:write usage:read")
                .audience(configuration.audience)
                .useCredentialsManager(manager)
                .start()

            user = try manager.userProfile().map(AuthenticatedUser.init)
            isAuthenticated = true
        } catch WebAuthError.userCancelled {
            return
        } catch WebAuthError.authenticationFailed {
            errorMessage = "Login was not completed. Please check your details and try again."
        } catch WebAuthError.codeExchangeFailed {
            errorMessage = "EcoAI could not finish signing you in. Please check your connection and try again."
        } catch {
            errorMessage = "EcoAI could not sign you in. Please try again."
        }
    }

    func logOut() async {
        guard let configuration, let manager = credentialsManager else {
            resetLocalSession()
            return
        }

        isWorking = true
        errorMessage = nil

        do {
            try await manager.revoke()
        } catch {
            // Local credentials must still be removed when network revocation fails.
            try? manager.clear()
        }

        do {
            try await Auth0
                .webAuth(clientId: configuration.clientID, domain: configuration.domain)
                .logout()
        } catch {
            // The local session is already gone. The next login can still proceed.
        }

        resetLocalSession()
        isWorking = false
    }

    func accessToken(minTTL: Int = 60) async throws -> String {
        guard let manager = credentialsManager, isAuthenticated else {
            throw SessionStoreError.notAuthenticated
        }

        do {
            return try await manager.credentials(minTTL: minTTL).accessToken
        } catch {
            try? manager.clear()
            resetLocalSession()
            throw SessionStoreError.notAuthenticated
        }
    }

    private func resetLocalSession() {
        isAuthenticated = false
        isRestoringSession = false
        user = nil
    }
}
