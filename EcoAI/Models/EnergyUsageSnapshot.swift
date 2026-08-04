import Foundation

/// A transport-friendly representation of the usage data shown in the sidebar.
/// Populated live from the `usage` / `energy_wh` fields the Worker attaches
/// to the final SSE event of each response (see LLMStreamEvent).
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

    /// Starting state for a fresh session, before any response has streamed back.
    static let zero = EnergyUsageSnapshot(
        tokens: Metric(input: 0, output: 0, total: 0),
        electricityWattHours: Metric(input: 0, output: 0, total: 0),
        analogy: "Send a message to see the energy footprint of your first response.",
        promptRecommendation: EnergyUsageSnapshot.preview.promptRecommendation
    )

    /// Folds one response's usage into the running session snapshot. The
    /// Worker only reports a combined watt-hour estimate, so it's split
    /// between input/output proportionally to each side's token share.
    func adding(promptTokens: Int, completionTokens: Int, wattHours: Double) -> EnergyUsageSnapshot {
        let totalNewTokens = max(promptTokens + completionTokens, 1)
        let inputShare = wattHours * (Double(promptTokens) / Double(totalNewTokens))
        let outputShare = wattHours - inputShare

        let newInputTokens = tokens.input + Double(promptTokens)
        let newOutputTokens = tokens.output + Double(completionTokens)
        let newInputWh = electricityWattHours.input + inputShare
        let newOutputWh = electricityWattHours.output + outputShare
        let newTotalWh = newInputWh + newOutputWh

        return EnergyUsageSnapshot(
            tokens: Metric(
                input: newInputTokens,
                output: newOutputTokens,
                total: newInputTokens + newOutputTokens
            ),
            electricityWattHours: Metric(
                input: newInputWh,
                output: newOutputWh,
                total: newTotalWh
            ),
            analogy: Self.analogy(forWattHours: newTotalWh),
            promptRecommendation: promptRecommendation
        )
    }

    nonisolated private static func analogy(forWattHours wattHours: Double) -> String {
        let ledBulbSeconds = wattHours / (10.0 / 3_600.0) // a 10 W LED bulb
        if ledBulbSeconds < 60 {
            return "That is about the energy needed to keep a 10 W LED bulb on for \(max(Int(ledBulbSeconds.rounded()), 1)) seconds."
        }
        return String(
            format: "That is about the energy needed to keep a 10 W LED bulb on for %.1f minutes.",
            ledBulbSeconds / 60
        )
    }
}