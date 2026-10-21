import Foundation
import LocalAuthentication
import Security

nonisolated struct CredentialVaultError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Secure credential storage is unavailable (\(status))." }
}

/// Uses the Data Protection keychain for team-signed apps. Unsigned/ad-hoc
/// development builds keep credentials only in memory, never in plaintext files.
/// The old login-keychain item is intentionally never read or migrated.
nonisolated final class CredentialVault: @unchecked Sendable {
    struct Operations {
        var read: ([String: Any]) -> (OSStatus, Data?)
        var update: ([String: Any], [String: Any]) -> OSStatus
        var add: ([String: Any]) -> OSStatus
        var delete: ([String: Any]) -> OSStatus
        var makeContext: () -> LAContext = { LAContext() }

        static let system = Operations(
            read: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result as? Data)
            },
            update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            delete: { SecItemDelete($0 as CFDictionary) }
        )
    }

    private let service: String
    private let persistent: Bool
    private let operations: Operations
    private let lock = NSLock()
    private var cache: [String: Data] = [:]

    init(
        service: String = "ecoai.auth0.session.v2",
        persistent: Bool = CredentialVault.hasPersistentKeychainAccess,
        operations: Operations = .system
    ) {
        self.service = service
        self.persistent = persistent
        self.operations = operations
    }

    static var hasPersistentKeychainAccess: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = entitlements["keychain-access-groups"] as? [String] else { return false }
        return !team.isEmpty && groups.contains { !$0.isEmpty }
    }

    private func query(key: String? = nil) throws -> [String: Any] {
        let context = operations.makeContext()
        context.interactionNotAllowed = true
        // Fail closed if the LocalAuthentication service cannot honor this
        // setting (for example, in a headless process).
        guard context.interactionNotAllowed else {
            throw CredentialVaultError(status: errSecInteractionNotAllowed)
        }
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        if let key { result[kSecAttrAccount as String] = key }
        return result
    }

    func getEntry(forKey key: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let data = cache[key] { return data }
        guard persistent else { throw CredentialVaultError(status: errSecItemNotFound) }
        var query = try query(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = operations.read(query)
        guard status == errSecSuccess, let data else { throw CredentialVaultError(status: status) }
        cache[key] = data
        return data
    }

    func setEntry(_ data: Data, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if persistent {
            var query = try query(key: key)
            var status = operations.update(query, [kSecValueData as String: data])
            if status == errSecItemNotFound {
                query[kSecValueData as String] = data
                query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = operations.add(query)
            }
            guard status == errSecSuccess else { throw CredentialVaultError(status: status) }
        }
        cache[key] = data
    }

    func deleteEntry(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: key)
        if persistent { try checkDeletion(operations.delete(query(key: key))) }
    }

    func deleteAllEntries() throws {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        if persistent { try checkDeletion(operations.delete(query())) }
    }

    private func checkDeletion(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError(status: status)
        }
    }
}
