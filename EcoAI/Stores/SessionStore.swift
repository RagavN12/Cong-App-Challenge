import Combine
import Foundation

/// Owns the app's authentication lifecycle. The current implementation is a
/// local mock; token exchange and refresh can replace these methods later.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var isAuthenticated: Bool

    private let defaults: UserDefaults
    private let authenticationKey = "session.isAuthenticated"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isAuthenticated = defaults.object(forKey: authenticationKey) as? Bool ?? false
    }

    func logIn(email: String, password: String) {
        guard !email.isEmpty, !password.isEmpty else { return }
        isAuthenticated = true
        defaults.set(true, forKey: authenticationKey)
    }

    func logOut() {
        isAuthenticated = false
        defaults.set(false, forKey: authenticationKey)
    }
}
