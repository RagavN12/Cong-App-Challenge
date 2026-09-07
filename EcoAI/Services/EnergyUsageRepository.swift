import Foundation

nonisolated struct PersistedEnergyUsage: Codable, Sendable {
    let dayKey: String
    let snapshot: EnergyUsageSnapshot
}

/// Atomic on-device persistence for the daily energy panel. This can later be
/// replaced or backed by Worker sync without changing the sidebar UI.
actor EnergyUsageRepository {
    private let storageURL: URL

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
    }

    func load() throws -> PersistedEnergyUsage? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: storageURL)
        return try decoder.decode(PersistedEnergyUsage.self, from: data)
    }

    func save(_ usage: PersistedEnergyUsage) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(usage)

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
            .appendingPathComponent("energy-usage.json")
    }
}
