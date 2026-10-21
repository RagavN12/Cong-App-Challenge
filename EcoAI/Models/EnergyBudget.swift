import Foundation

nonisolated enum EnergyBudgetPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case daily, weekly
    var id: String { rawValue }
    var title: String { self == .daily ? "Daily" : "Weekly" }
    var sidebarTitle: String { self == .daily ? "Today" : "This week" }
}

nonisolated struct EnergyBudget: Codable, Equatable, Sendable {
    var period: EnergyBudgetPeriod = .daily
    var dailyWattHours: Double = 5
    var weeklyWattHours: Double = 35

    var limitWattHours: Double { period == .daily ? dailyWattHours : weeklyWattHours }

    static func isValidLimit(_ value: Double) -> Bool {
        value.isFinite && value >= 0.001 && value <= 1_000_000
    }

    var isValid: Bool {
        Self.isValidLimit(dailyWattHours) && Self.isValidLimit(weeklyWattHours)
    }
}

nonisolated enum EnergyLimitError: LocalizedError {
    case reached
    var errorDescription: String? {
        "Your energy limit has been reached. New messages resume when the next period starts."
    }
}
