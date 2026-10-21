import CryptoKit
import Foundation

nonisolated enum StorageLoadState {
    case notLoaded, loading, loaded, failed
}

/// Account paths never read or migrate the old, unowned shared history files.
nonisolated enum AccountStorage {
    static func directory(for userID: String, root: URL? = nil) -> URL {
        let support = root ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("EcoAI", isDirectory: true)
        let digest = SHA256.hash(data: Data(userID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return support.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }
}
