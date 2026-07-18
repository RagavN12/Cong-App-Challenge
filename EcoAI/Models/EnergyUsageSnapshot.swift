import Foundation

/// A transport-friendly representation of the usage data shown in the sidebar.
/// The same shape can later be decoded directly from a Worker API response.
nonisolated struct EnergyUsageSnapshot: Codable, Equatable, Sendable {
    nonisolated struct Metric: Codable, Equatable, Sendable {
        let input: Double
        let output: Double
        let total: Double
    }

    let tokens: Metric
    let electricityWattHours: Metric
    let analogy: String
    let promptRecommendation: String

    static let preview = EnergyUsageSnapshot(
        tokens: Metric(input: 12_800, output: 5_600, total: 18_400),
        electricityWattHours: Metric(input: 0.053, output: 0.033, total: 0.086),
        analogy: "That is about the energy needed to keep a 10 W LED bulb on for 31 seconds.",
        promptRecommendation: "State your goal, essential context, and desired format in one focused prompt. Remove repeated background details and ask for a concise answer first—you can always request more depth afterward."
    )
}
