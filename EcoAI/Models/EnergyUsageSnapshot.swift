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
    let latestResponseWattHours: Double
    let responseCount: Int
    let analogy: String
    let promptRecommendation: String

    init(
        tokens: Metric,
        electricityWattHours: Metric,
        latestResponseWattHours: Double,
        responseCount: Int = 0,
        analogy: String,
        promptRecommendation: String
    ) {
        self.tokens = tokens
        self.electricityWattHours = electricityWattHours
        self.latestResponseWattHours = latestResponseWattHours
        self.responseCount = responseCount
        self.analogy = analogy
        self.promptRecommendation = promptRecommendation
    }

    private enum CodingKeys: String, CodingKey {
        case tokens
        case electricityWattHours
        case latestResponseWattHours
        case responseCount
        case analogy
        case promptRecommendation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decode(Metric.self, forKey: .tokens)
        electricityWattHours = try container.decode(Metric.self, forKey: .electricityWattHours)
        latestResponseWattHours = try container.decodeIfPresent(Double.self, forKey: .latestResponseWattHours) ?? 0
        responseCount = try container.decodeIfPresent(Int.self, forKey: .responseCount) ?? 0
        analogy = try container.decode(String.self, forKey: .analogy)
        promptRecommendation = try container.decode(String.self, forKey: .promptRecommendation)
    }

    static let preview = EnergyUsageSnapshot(
        tokens: Metric(input: 12_800, output: 5_600, total: 18_400),
        electricityWattHours: Metric(input: 0.053, output: 0.033, total: 0.086),
        latestResponseWattHours: 0.086,
        analogy: "That response used about 0.086 Wh, roughly the energy needed to charge wireless earbuds for a short while.",
        promptRecommendation: "State your goal, essential context, and desired format in one focused prompt. Remove repeated background details and ask for a concise answer first—you can always request more depth afterward."
    )

    /// Starting state for a fresh session, before any response has streamed back.
    static let zero = EnergyUsageSnapshot(
        tokens: Metric(input: 0, output: 0, total: 0),
        electricityWattHours: Metric(input: 0, output: 0, total: 0),
        latestResponseWattHours: 0,
        responseCount: 0,
        analogy: "Send a message to see the energy footprint of your first response.",
        promptRecommendation: EnergyUsageSnapshot.preview.promptRecommendation
    )

    /// Folds one response's usage into the running daily snapshot.
    func adding(usage: LLMUsagePayload, energy: LLMEnergyPayload?) -> EnergyUsageSnapshot {
        if let energy {
            let newInputTokens = tokens.input + Double(usage.promptTokens)
            let newOutputTokens = tokens.output + Double(usage.completionTokens)
            let newInputWh = electricityWattHours.input + energy.input
            let newOutputWh = electricityWattHours.output + energy.output
            let newTotalWh = newInputWh + newOutputWh
            let responseWattHours = max(energy.total, 0)

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
                latestResponseWattHours: responseWattHours,
                responseCount: responseCount + 1,
                analogy: EnergyAnalogyGenerator.text(forWattHours: responseWattHours, responseNumber: responseCount + 1),
                promptRecommendation: promptRecommendation
            )
        }

        return adding(
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            wattHours: 0
        )
    }

    /// Backward-compatible fallback for older Worker events that only reported
    /// one combined watt-hour estimate.
    func adding(promptTokens: Int, completionTokens: Int, wattHours: Double) -> EnergyUsageSnapshot {
        let totalNewTokens = max(promptTokens + completionTokens, 1)
        let inputShare = wattHours * (Double(promptTokens) / Double(totalNewTokens))
        let outputShare = wattHours - inputShare

        let newInputTokens = tokens.input + Double(promptTokens)
        let newOutputTokens = tokens.output + Double(completionTokens)
        let newInputWh = electricityWattHours.input + inputShare
        let newOutputWh = electricityWattHours.output + outputShare
        let newTotalWh = newInputWh + newOutputWh
        let responseWattHours = max(wattHours, 0)

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
            latestResponseWattHours: responseWattHours,
            responseCount: responseCount + 1,
            analogy: EnergyAnalogyGenerator.text(forWattHours: responseWattHours, responseNumber: responseCount + 1),
            promptRecommendation: promptRecommendation
        )
    }

}

private enum EnergyAnalogyGenerator {
    static func text(forWattHours wattHours: Double, responseNumber: Int) -> String {
        let value = String(format: "%.3f", wattHours)
        let templates = [
            "That response used about %@ Wh, roughly the energy needed to charge wireless earbuds for a short while.",
            "That response used about %@ Wh, comparable to powering a Wi-Fi router for about %@ minutes.",
            "That response used about %@ Wh, similar to charging a phone by about %@%%.",
            "That response used about %@ Wh, enough to run a 10 W LED bulb for about %@ minutes.",
            "That response used about %@ Wh, comparable to watching video on a laptop for about %@ minutes.",
            "That response used about %@ Wh, around the energy used by a ceiling fan for about %@ minutes.",
            "That response used about %@ Wh, roughly enough to power a smart speaker for about %@ hours.",
            "That response used about %@ Wh, comparable to a short microwave run of about %@ seconds.",
            "That response used about %@ Wh, similar to charging a laptop by about %@%%.",
            "That response used about %@ Wh, roughly the energy used by a small desk lamp for about %@ minutes."
        ]
        let template = templates[(max(responseNumber, 1) - 1) % templates.count]

        switch (max(responseNumber, 1) - 1) % templates.count {
        case 1: return String(format: template, value, String(format: "%.1f", max(wattHours / (8.0 / 60.0), 1)))
        case 2: return String(format: template, value, String(format: "%.1f", max(wattHours / 12.0 * 100.0, 0.1)))
        case 3: return String(format: template, value, String(format: "%.1f", max(wattHours / (10.0 / 60.0), 0.1)))
        case 4: return String(format: template, value, String(format: "%.1f", max(wattHours / (45.0 / 60.0), 0.1)))
        case 5: return String(format: template, value, String(format: "%.1f", max(wattHours / (35.0 / 60.0), 0.1)))
        case 6: return String(format: template, value, String(format: "%.2f", max(wattHours / 0.8, 0.01)))
        case 7: return String(format: template, value, String(format: "%.0f", max(wattHours / (900.0 / 3_600.0), 1)))
        case 8: return String(format: template, value, String(format: "%.1f", max(wattHours / 45.0 * 100.0, 0.1)))
        case 9: return String(format: template, value, String(format: "%.1f", max(wattHours / (7.0 / 60.0), 0.1)))
        default: return String(format: template, value)
        }
    }
}
