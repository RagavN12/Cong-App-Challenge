import Foundation

nonisolated struct PersistedEnergyUsage: Codable, Sendable {
    let budget: EnergyBudget
    let days: [String: EnergyUsageSnapshot]
    let acknowledgedLimitPeriod: String?

    init(budget: EnergyBudget, days: [String: EnergyUsageSnapshot], acknowledgedLimitPeriod: String? = nil) {
        self.budget = budget
        self.days = days
        self.acknowledgedLimitPeriod = acknowledgedLimitPeriod
    }

    private enum CodingKeys: String, CodingKey { case budget, days, dayKey, snapshot, acknowledgedLimitPeriod }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        budget = try values.decodeIfPresent(EnergyBudget.self, forKey: .budget) ?? EnergyBudget()
        acknowledgedLimitPeriod = try values.decodeIfPresent(String.self, forKey: .acknowledgedLimitPeriod)
        guard budget.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .budget, in: values, debugDescription: "Invalid energy limit")
        }
        if let ledger = try values.decodeIfPresent([String: EnergyUsageSnapshot].self, forKey: .days) {
            days = ledger
        } else {
            // Preserve the old daily snapshot when upgrading an existing account.
            let key = try values.decode(String.self, forKey: .dayKey)
            days = [key: try values.decode(EnergyUsageSnapshot.self, forKey: .snapshot)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(budget, forKey: .budget)
        try values.encode(days, forKey: .days)
        try values.encodeIfPresent(acknowledgedLimitPeriod, forKey: .acknowledgedLimitPeriod)
    }
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
