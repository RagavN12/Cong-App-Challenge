import Foundation

nonisolated struct EnergyLimitNotice: Identifiable {
    let id = UUID()
    let periodKey: String
}

/// A comparison based on the whole budget period, rather than the last reply.
nonisolated struct EnergyLimitContext {
    let wattHours: Double

    var lightBulbSeconds: Double { max(wattHours, 0) / 10 * 3_600 }

    var duration: String {
        let seconds = lightBulbSeconds
        if seconds < 1 { return "less than 1 second" }
        let value: Double
        let unit: String
        if seconds < 60 { value = seconds; unit = "second" }
        else if seconds < 3_600 { value = seconds / 60; unit = "minute" }
        else if seconds < 86_400 { value = seconds / 3_600; unit = "hour" }
        else { value = seconds / 86_400; unit = "day" }
        let rounded = (value * 10).rounded() / 10
        return "about \(rounded.formatted(.number.precision(.fractionLength(0...1)))) \(unit)\(rounded == 1 ? "" : "s")"
    }

    var analogy: String {
        "That’s roughly enough to power a 10 W LED bulb for \(duration)."
    }
}
