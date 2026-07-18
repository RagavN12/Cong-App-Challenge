import Foundation

/// Atomic on-device persistence that can remain as an offline cache after
/// Cloudflare-backed chat synchronization is introduced.
actor ChatLocalRepository {
    private let storageURL: URL
    private let legacyDefaults: UserDefaults
    private let legacyStorageKey = "ecoai.chat-history.v1"

    init(
        storageURL: URL? = nil,
        legacyDefaults: UserDefaults = .standard
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.legacyDefaults = legacyDefaults
    }

    func load() throws -> [ChatThread]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if FileManager.default.fileExists(atPath: storageURL.path) {
            let data = try Data(contentsOf: storageURL)
            return try decoder.decode([ChatThread].self, from: data)
        }

        // One-time migration from the original UserDefaults implementation.
        if let legacyData = legacyDefaults.data(forKey: legacyStorageKey) {
            let chats = try decoder.decode([ChatThread].self, from: legacyData)
            try save(chats)
            legacyDefaults.removeObject(forKey: legacyStorageKey)
            return chats
        }

        return nil
    }

    func save(_ chats: [ChatThread]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(chats)

        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: storageURL, options: .atomic)
    }

    nonisolated private static func defaultStorageURL() -> URL {
        let fileManager = FileManager.default
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        return applicationSupport
            .appendingPathComponent("EcoAI", isDirectory: true)
            .appendingPathComponent("chat-history.json")
    }
}
