import Combine
import Foundation

@MainActor
final class EnergyUsageStore: ObservableObject {
    @Published private(set) var snapshot: EnergyUsageSnapshot = .zero
    @Published private(set) var lastError: String?

    private let repository: EnergyUsageRepository
    private var hasLoaded = false
    private var dayKey: String

    init(repository: EnergyUsageRepository) {
        self.repository = repository
        self.dayKey = Self.todayKey()
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        do {
            if let persisted = try await repository.load(), persisted.dayKey == Self.todayKey() {
                dayKey = persisted.dayKey
                snapshot = persisted.snapshot
            } else {
                resetForToday()
                await persist()
            }
        } catch {
            lastError = "Energy usage could not be loaded."
        }
    }

    func recordResponse(usage: LLMUsagePayload, energy: LLMEnergyPayload?) {
        refreshDayIfNeeded()
        snapshot = snapshot.adding(usage: usage, energy: energy)

        Task { [weak self, repository, dayKey, snapshot] in
            do {
                try await repository.save(
                    PersistedEnergyUsage(dayKey: dayKey, snapshot: snapshot)
                )
            } catch {
                await MainActor.run {
                    self?.lastError = "Energy usage could not be saved."
                }
            }
        }
    }

    func resetToday() {
        resetForToday()
        Task {
            await persist()
        }
    }

    private func refreshDayIfNeeded() {
        guard dayKey != Self.todayKey() else { return }
        resetForToday()
    }

    private func resetForToday() {
        dayKey = Self.todayKey()
        snapshot = .zero
    }

    private func persist() async {
        do {
            try await repository.save(
                PersistedEnergyUsage(dayKey: dayKey, snapshot: snapshot)
            )
        } catch {
            lastError = "Energy usage could not be saved."
        }
    }

    nonisolated private static func todayKey(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
