import Foundation

nonisolated enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

/// Free-tier OpenRouter models the Worker is allowed to route to. The
/// rawValue is what's sent to the Worker as `model` — it must match a key in
/// the Worker's `FREE_MODELS` map in src/index.js. Keep these two in sync.
nonisolated enum AIModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case qwen3Coder = "qwen3-coder"
    case gptOss20b = "gpt-oss-20b"
    case google = "google"
    case inclusionAILing = "inclusionAI: Ling 3.0 Flash Sante (free)"
    case poolsideLaguna = "Poolside: Laguna S 2.1 (free)"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto (free)"
        case .qwen3Coder: "Qwen3 Reranker 8B"
        case .gptOss20b: "Nemotron 3.5 Lightning"
        case .google: "Nemotron 3.5 Content Safety"
        case .inclusionAILing: "Ling 3.0 Flash Sante"
        case .poolsideLaguna: "Laguna S 2.1"
        }
    }
}

nonisolated struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

nonisolated struct ChatThread: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var section: String
    var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        title: String,
        section: String,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.section = section
        self.messages = messages
    }
}

/// The stable wire contract sent to the Cloudflare Worker.
nonisolated struct LLMMessagePayload: Codable, Sendable {
    let id: UUID
    let role: ChatRole
    let content: String
    let createdAt: Date

    init(message: ChatMessage) {
        id = message.id
        role = message.role
        content = message.content
        createdAt = message.createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case createdAt = "created_at"
    }
}

nonisolated struct LLMStreamRequest: Codable, Sendable {
    let requestID: UUID
    let threadID: UUID
    let model: AIModel
    let messages: [LLMMessagePayload]

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case threadID = "thread_id"
        case model
        case messages
    }
}

nonisolated struct PromptCoachRequest: Codable, Sendable {
    let requestID: UUID
    let threadID: UUID
    let messages: [LLMMessagePayload]

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case threadID = "thread_id"
        case messages
    }
}

nonisolated struct PromptCoachResponse: Codable, Sendable {
    let advice: String
}

/// Token counts the Worker reports back once OpenRouter's streamed usage
/// chunk arrives (typically alongside the final `finish_reason`).
nonisolated struct LLMUsagePayload: Codable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

/// Estimated electricity use for one response. This mirrors the token split so
/// the client does not have to guess how to divide one combined watt-hour value.
nonisolated struct LLMEnergyPayload: Codable, Sendable {
    let input: Double
    let output: Double
    let total: Double
}

/// A decoded event from the Worker's streaming response.
nonisolated struct LLMStreamEvent: Codable, Sendable {
    let requestID: UUID
    let delta: String
    let finishReason: String?
    let usage: LLMUsagePayload?
    let energy: LLMEnergyPayload?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case delta
        case finishReason = "finish_reason"
        case usage
        case energy = "energy_wh"
    }

    init(
        requestID: UUID,
        delta: String,
        finishReason: String?,
        usage: LLMUsagePayload? = nil,
        energy: LLMEnergyPayload? = nil
    ) {
        self.requestID = requestID
        self.delta = delta
        self.finishReason = finishReason
        self.usage = usage
        self.energy = energy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        delta = try container.decode(String.self, forKey: .delta)
        finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
        usage = try container.decodeIfPresent(LLMUsagePayload.self, forKey: .usage)

        if let structuredEnergy = try? container.decodeIfPresent(LLMEnergyPayload.self, forKey: .energy) {
            energy = structuredEnergy
        } else if let legacyTotal = try? container.decodeIfPresent(Double.self, forKey: .energy) {
            energy = LLMEnergyPayload(input: 0, output: legacyTotal, total: legacyTotal)
        } else {
            energy = nil
        }
    }
}
