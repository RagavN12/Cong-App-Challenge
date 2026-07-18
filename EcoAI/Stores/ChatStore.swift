import Combine
import Foundation

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var chats: [ChatThread]
    @Published private(set) var respondingChatIDs: Set<ChatThread.ID> = []
    @Published private(set) var lastError: String?

    private let accessPoint: CloudflareAccessPoint
    private let repository: ChatLocalRepository
    private var responseTasks: [ChatThread.ID: Task<Void, Never>] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var hasLoaded = false

    init(
        accessPoint: CloudflareAccessPoint,
        repository: ChatLocalRepository,
        seedChats: [ChatThread] = ChatStore.sampleChats
    ) {
        self.accessPoint = accessPoint
        self.repository = repository
        self.chats = seedChats
    }

    deinit {
        responseTasks.values.forEach { $0.cancel() }
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        do {
            if let persistedChats = try await repository.load() {
                chats = persistedChats
            } else {
                await persist()
            }
        } catch {
            lastError = "Chat history could not be loaded."
        }
    }

    func chat(withID id: ChatThread.ID?) -> ChatThread? {
        guard let id else { return nil }
        return chats.first { $0.id == id }
    }

    func isResponding(in chatID: ChatThread.ID?) -> Bool {
        guard let chatID else { return false }
        return respondingChatIDs.contains(chatID)
    }

    @discardableResult
    func sendMessage(
        _ prompt: String,
        model: AIModel,
        selectedChatID: ChatThread.ID?
    ) -> ChatThread.ID? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let threadID: ChatThread.ID
        if let selectedChatID,
           chats.contains(where: { $0.id == selectedChatID }),
           !respondingChatIDs.contains(selectedChatID) {
            threadID = selectedChatID
        } else if selectedChatID == nil {
            let thread = ChatThread(title: title(for: trimmed), section: "Today")
            chats.insert(thread, at: 0)
            threadID = thread.id
        } else {
            return nil
        }

        append(ChatMessage(role: .user, content: trimmed), to: threadID)
        guard let thread = chat(withID: threadID) else { return nil }

        let request = LLMStreamRequest(
            requestID: UUID(),
            threadID: threadID,
            model: model,
            messages: thread.messages.map(LLMMessagePayload.init)
        )
        let responseID = UUID()
        append(ChatMessage(id: responseID, role: .assistant, content: ""), to: threadID)
        respondingChatIDs.insert(threadID)
        persistSoon()

        let task = Task { [weak self, accessPoint] in
            do {
                let stream = await accessPoint.streamAIResponse(request: request)
                for try await event in stream {
                    guard event.requestID == request.requestID else { continue }
                    self?.updateMessage(responseID, in: threadID) { message in
                        message.content += event.delta
                    }
                }
            } catch is CancellationError {
                self?.removeEmptyMessage(responseID, from: threadID)
            } catch {
                self?.markMessageFailed(responseID, in: threadID, error: error)
            }

            self?.finishResponse(in: threadID)
        }
        responseTasks[threadID] = task
        return threadID
    }

    func delete(_ chatID: ChatThread.ID) {
        cancelResponse(in: chatID)
        chats.removeAll { $0.id == chatID }
        persistSoon()
    }

    func cancelResponse(in chatID: ChatThread.ID) {
        responseTasks[chatID]?.cancel()
        responseTasks[chatID] = nil
        respondingChatIDs.remove(chatID)
    }

    func cancelAllResponses() {
        let activeChatIDs = Array(responseTasks.keys)
        activeChatIDs.forEach(cancelResponse)
    }

    private func append(_ message: ChatMessage, to threadID: ChatThread.ID) {
        guard let index = chats.firstIndex(where: { $0.id == threadID }) else { return }
        chats[index].messages.append(message)
    }

    private func updateMessage(
        _ messageID: ChatMessage.ID,
        in threadID: ChatThread.ID,
        update: (inout ChatMessage) -> Void
    ) {
        guard let threadIndex = chats.firstIndex(where: { $0.id == threadID }),
              let messageIndex = chats[threadIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
        update(&chats[threadIndex].messages[messageIndex])
    }

    private func removeEmptyMessage(_ messageID: ChatMessage.ID, from threadID: ChatThread.ID) {
        guard let index = chats.firstIndex(where: { $0.id == threadID }) else { return }
        chats[index].messages.removeAll { $0.id == messageID && $0.content.isEmpty }
    }

    private func markMessageFailed(_ messageID: ChatMessage.ID, in threadID: ChatThread.ID, error: Error) {
        updateMessage(messageID, in: threadID) { message in
            let explanation = error.localizedDescription
            if message.content.isEmpty {
                message.content = "I couldn’t load a response. \(explanation)"
            } else {
                message.content += "\n\n[The response was interrupted: \(explanation)]"
            }
        }
        lastError = error.localizedDescription
    }

    private func finishResponse(in threadID: ChatThread.ID) {
        respondingChatIDs.remove(threadID)
        responseTasks[threadID] = nil
        persistSoon()
    }

    private func title(for prompt: String) -> String {
        let allWords = prompt.split(whereSeparator: \.isWhitespace)
        let title = allWords.prefix(6).joined(separator: " ")
        return allWords.count > 6 ? title + "…" : title
    }

    private func persistSoon() {
        persistenceTask?.cancel()
        let snapshot = chats
        persistenceTask = Task { [weak self, repository] in
            do {
                try Task.checkCancellation()
                try await repository.save(snapshot)
            } catch is CancellationError {
                return
            } catch {
                self?.lastError = "Chat history could not be saved."
            }
        }
    }

    private func persist() async {
        do {
            try await repository.save(chats)
        } catch {
            lastError = "Chat history could not be saved."
        }
    }

    nonisolated static let sampleChats = [
        ChatThread(title: "Designing a greener home", section: "Today"),
        ChatThread(title: "Weekly energy summary", section: "Today"),
        ChatThread(title: "Solar panel questions", section: "Previous 7 days"),
        ChatThread(title: "Reduce standby power", section: "Previous 7 days"),
        ChatThread(title: "Sustainable travel ideas", section: "Previous 30 days")
    ]
}
