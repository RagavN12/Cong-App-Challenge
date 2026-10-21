import Combine
import Foundation

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var chats: [ChatThread]
    @Published private(set) var respondingChatIDs: Set<ChatThread.ID> = []
    @Published private(set) var lastError: String?
    @Published private(set) var responseStatuses: [ChatThread.ID: String] = [:]
    @Published private(set) var loadState: StorageLoadState = .notLoaded

    private let accessPoint: CloudflareAccessPoint
    private let repository: ChatLocalRepository
    private let energyUsageStore: EnergyUsageStore
    private let retryPolicy: ResponseRetryPolicy
    private struct ActiveResponse {
        let requestID: UUID
        let messageID: UUID
        let task: Task<Void, Never>
    }
    private var responseTasks: [ChatThread.ID: ActiveResponse] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var isActive = true

    var canSendMessages: Bool {
        isActive && loadState == .loaded && energyUsageStore.isReady && !energyUsageStore.isLimitReached
    }

    init(
        accessPoint: CloudflareAccessPoint,
        repository: ChatLocalRepository,
        energyUsageStore: EnergyUsageStore,
        seedChats: [ChatThread] = ChatStore.sampleChats,
        retryPolicy: ResponseRetryPolicy = .standard
    ) {
        self.accessPoint = accessPoint
        self.repository = repository
        self.energyUsageStore = energyUsageStore
        self.chats = seedChats
        self.retryPolicy = retryPolicy
    }

    deinit {
        responseTasks.values.forEach { $0.task.cancel() }
    }

    func load() async {
        guard isActive, loadState != .loaded, loadState != .loading else { return }
        loadState = .loading
        lastError = nil

        do {
            let persistedChats = try await repository.load()
            guard isActive else { return }
            if let persistedChats {
                chats = persistedChats
            }
            loadState = .loaded
        } catch {
            loadState = .failed
            lastError = "Chat history could not be loaded. Your saved file has been preserved. Retry to continue."
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
        selectedChatID: ChatThread.ID?
    ) -> ChatThread.ID? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        energyUsageStore.refreshPeriod()
        guard canSendMessages, !trimmed.isEmpty else { return nil }

        lastError = nil
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
            messages: thread.messages.map(LLMMessagePayload.init)
        )
        let responseID = UUID()
        append(ChatMessage(id: responseID, role: .assistant, content: ""), to: threadID)
        respondingChatIDs.insert(threadID)
        persistSoon()

        let policy = retryPolicy
        let task = Task { [weak self, accessPoint] in
            do {
                for attempt in 1...max(policy.maximumAttempts, 1) {
                    try Task.checkCancellation()
                    self?.energyUsageStore.refreshPeriod()
                    if self?.energyUsageStore.isLimitReached == true { throw EnergyLimitError.reached }
                    let attemptRequest = LLMStreamRequest(
                        requestID: UUID(), threadID: request.threadID,
                        messages: request.messages
                    )
                    do {
                        let stream = await accessPoint.streamAIResponse(request: attemptRequest)
                        for try await event in stream {
                            try Task.checkCancellation()
                            guard event.requestID == attemptRequest.requestID else { continue }
                            guard self?.responseTasks[threadID]?.requestID == request.requestID else {
                                throw CancellationError()
                            }
                            self?.updateMessage(responseID, in: threadID) { message in
                                message.content += event.delta
                            }
                            if let usage = event.usage {
                                self?.energyUsageStore.recordResponse(usage: usage, energy: event.energy)
                            }
                        }
                        try Task.checkCancellation()
                        break
                    } catch {
                        try Task.checkCancellation()
                        guard attempt < policy.maximumAttempts, policy.shouldRetry(error) else { throw error }
                        guard self?.responseTasks[threadID]?.requestID == request.requestID else {
                            throw CancellationError()
                        }
                        self?.responseStatuses[threadID] = "Connection interrupted. Retrying \(attempt + 1) of \(policy.maximumAttempts)…"
                        self?.updateMessage(responseID, in: threadID) { $0.content = "" }
                        try await Task.sleep(for: policy.delay(after: attempt))
                    }
                }
            } catch is CancellationError {
                self?.removeEmptyMessage(responseID, from: threadID)
            } catch {
                if Task.isCancelled {
                    self?.removeEmptyMessage(responseID, from: threadID)
                } else if self?.responseTasks[threadID]?.requestID == request.requestID {
                    self?.markMessageFailed(responseID, in: threadID, error: error)
                }
            }
            self?.finishResponse(in: threadID, requestID: request.requestID)
        }
        responseTasks[threadID] = ActiveResponse(requestID: request.requestID, messageID: responseID, task: task)
        return threadID
    }

    func delete(_ chatID: ChatThread.ID) {
        guard isActive, loadState == .loaded else { return }
        cancelResponse(in: chatID)
        chats.removeAll { $0.id == chatID }
        persistSoon()
    }

    func cancelResponse(in chatID: ChatThread.ID) {
        guard let response = responseTasks.removeValue(forKey: chatID) else { return }
        response.task.cancel()
        respondingChatIDs.remove(chatID)
        responseStatuses[chatID] = nil
        removeEmptyMessage(response.messageID, from: chatID)
        persistSoon()
    }

    func cancelAllResponses() {
        let activeChatIDs = Array(responseTasks.keys)
        activeChatIDs.forEach(cancelResponse)
    }

    func deactivate() {
        cancelAllResponses()
        isActive = false
    }

    func dismissError() {
        lastError = nil
    }

    func flush() async {
        await persistenceTask?.value
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

    private func finishResponse(in threadID: ChatThread.ID, requestID: UUID) {
        guard responseTasks[threadID]?.requestID == requestID else { return }
        respondingChatIDs.remove(threadID)
        responseStatuses[threadID] = nil
        responseTasks[threadID] = nil
        persistSoon()
    }

    private func title(for prompt: String) -> String {
        let allWords = prompt.split(whereSeparator: \.isWhitespace)
        let title = allWords.prefix(6).joined(separator: " ")
        return allWords.count > 6 ? title + "…" : title
    }

    private func persistSoon() {
        guard isActive, loadState == .loaded else { return }
        let previousSave = persistenceTask
        let snapshot = chats
        persistenceTask = Task { [weak self, repository] in
            await previousSave?.value
            do {
                try await repository.save(snapshot)
            } catch {
                self?.lastError = "Chat history could not be saved."
            }
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
