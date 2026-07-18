import Foundation

nonisolated enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

nonisolated enum AIModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case defaultModel = "default"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .defaultModel: "Default"
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

/// A decoded event from the Worker's streaming response.
nonisolated struct LLMStreamEvent: Codable, Sendable {
    let requestID: UUID
    let delta: String
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case delta
        case finishReason = "finish_reason"
    }
}
