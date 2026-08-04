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
    case deepseekR1 = "deepseek-r1"
    case llama70b = "llama-3.3-70b"
    case qwen3Coder = "qwen3-coder"
    case gptOss20b = "gpt-oss-20b"
    case gemma312b = "gemma-3-12b"
    case mistralSmall = "mistral-small"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto (free)"
        case .deepseekR1: "DeepSeek R1"
        case .llama70b: "Llama 3.3 70B"
        case .qwen3Coder: "Qwen3 Coder"
        case .gptOss20b: "GPT-OSS 20B"
        case .gemma312b: "Gemma 3 12B"
        case .mistralSmall: "Mistral Small 3.1"
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

/// A decoded event from the Worker's streaming response.
nonisolated struct LLMStreamEvent: Codable, Sendable {
    let requestID: UUID
    let delta: String
    let finishReason: String?
    let usage: LLMUsagePayload?
    let energyWattHours: Double?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case delta
        case finishReason = "finish_reason"
        case usage
        case energyWattHours = "energy_wh"
    }
}