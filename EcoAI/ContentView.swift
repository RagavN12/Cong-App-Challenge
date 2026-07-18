import SwiftUI

struct ContentView: View {
    @ObservedObject var chatStore: ChatStore
    let user: AuthenticatedUser?

    @State private var selectedChatID: ChatThread.ID?
    @State private var draft = ""
    @State private var selectedModel = AIModel.defaultModel
    @State private var energy = 72.0
    @State private var showAttachmentNotice = false
    @State private var chatPendingDeletion: ChatThread?
    @State private var showSettings = false

    @Binding var appTheme: AppTheme
    @Binding var showChatHistory: Bool
    @Binding var showEnergyUsage: Bool
    let onLogout: () -> Void

    init(
        chatStore: ChatStore,
        user: AuthenticatedUser? = nil,
        appTheme: Binding<AppTheme> = .constant(.system),
        showChatHistory: Binding<Bool> = .constant(true),
        showEnergyUsage: Binding<Bool> = .constant(true),
        onLogout: @escaping () -> Void = {}
    ) {
        self.chatStore = chatStore
        self.user = user
        _appTheme = appTheme
        _showChatHistory = showChatHistory
        _showEnergyUsage = showEnergyUsage
        self.onLogout = onLogout
    }

    var body: some View {
        HSplitView {
            if showChatHistory {
                LeftSidebar(
                    user: user,
                    chats: chatStore.chats,
                    selectedChatID: $selectedChatID,
                    onRequestDelete: { chatPendingDeletion = $0 },
                    onOpenSettings: { showSettings = true },
                    onLogout: onLogout
                )
                    .frame(minWidth: 200, idealWidth: 252, maxWidth: 400)
            }

            ChatArea(
                selectedChat: selectedChat,
                messages: selectedChat?.messages ?? [],
                draft: $draft,
                selectedModel: $selectedModel,
                showAttachmentNotice: $showAttachmentNotice,
                isResponding: chatStore.isResponding(in: selectedChatID),
                onSend: sendMessage,
                onRequestDelete: {
                    if let selectedChat { chatPendingDeletion = selectedChat }
                }
            )
            .frame(minWidth: 480, maxWidth: .infinity)

            if showEnergyUsage {
                EnergySidebar(energy: $energy)
                    .frame(minWidth: 200, idealWidth: 248, maxWidth: 400)
            }
        }
        .frame(minWidth: 760, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await chatStore.load()
            if selectedChatID == nil { selectedChatID = chatStore.chats.first?.id }
        }
        .onChange(of: chatStore.chats.map(\.id)) { _, chatIDs in
            if let selectedChatID, !chatIDs.contains(selectedChatID) {
                self.selectedChatID = chatIDs.first
            }
        }
        .alert(
            "Permanently delete this chat?",
            isPresented: deletionAlertIsPresented,
            presenting: chatPendingDeletion
        ) { chat in
            Button("Delete", role: .destructive) {
                delete(chat)
            }
            Button("Cancel", role: .cancel) {}
        } message: { chat in
            Text("“\(chat.title)” will be removed from your history. This action cannot be undone.")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                user: user,
                appTheme: $appTheme,
                showChatHistory: $showChatHistory,
                showEnergyUsage: $showEnergyUsage,
                selectedModel: $selectedModel,
                onLogout: {
                    showSettings = false
                    onLogout()
                }
            )
        }
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { chatPendingDeletion != nil },
            set: { if !$0 { chatPendingDeletion = nil } }
        )
    }

    private var selectedChat: ChatThread? {
        chatStore.chat(withID: selectedChatID)
    }

    private func sendMessage() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let threadID = chatStore.sendMessage(
            trimmed,
            model: selectedModel,
            selectedChatID: selectedChatID
        ) {
            selectedChatID = threadID
            draft = ""
        }
    }

    private func delete(_ chat: ChatThread) {
        withAnimation(.easeInOut(duration: 0.18)) {
            chatStore.delete(chat.id)
            if selectedChatID == chat.id {
                selectedChatID = chatStore.chats.first?.id
            }
            chatPendingDeletion = nil
        }
    }
}

private struct LeftSidebar: View {
    let user: AuthenticatedUser?
    let chats: [ChatThread]
    @Binding var selectedChatID: ChatThread.ID?
    let onRequestDelete: (ChatThread) -> Void
    let onOpenSettings: () -> Void
    let onLogout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Menu {
                Button("Settings", systemImage: "gearshape", action: onOpenSettings)
                Divider()
                Button(
                    "Log out",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    role: .destructive,
                    action: onLogout
                )
            } label: {
                HStack(spacing: 10) {
                    AccountAvatar(user: user, size: 36)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(user?.displayName ?? "EcoAI User")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(user?.email ?? "View account")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 14)

            Button {
                selectedChatID = nil
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(groupedSections, id: \.self) { section in
                        Text(section)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 5)

                        ForEach(chats.filter { $0.section == section }) { chat in
                            HStack(spacing: 4) {
                                Button {
                                    selectedChatID = chat.id
                                } label: {
                                    Text(chat.title)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Menu {
                                    Button("Delete chat", systemImage: "trash", role: .destructive) {
                                        onRequestDelete(chat)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .menuIndicator(.hidden)
                                .buttonStyle(.plain)
                            }
                            .padding(.leading, 12)
                            .padding(.trailing, 6)
                            .padding(.vertical, 5)
                            .background(
                                selectedChatID == chat.id ? Color.primary.opacity(0.075) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .padding(.horizontal, 6)
                        }
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    private var groupedSections: [String] {
        chats.reduce(into: [String]()) { result, chat in
            if !result.contains(chat.section) { result.append(chat.section) }
        }
    }
}

struct AccountAvatar: View {
    let user: AuthenticatedUser?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let pictureURL = user?.pictureURL {
                AsyncImage(url: pictureURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initials
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(user?.displayName ?? "Account")
    }

    private var initials: some View {
        Text(initialsText)
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(.white)
    }

    private var initialsText: String {
        let words = (user?.displayName ?? "EcoAI User")
            .split(whereSeparator: \.isWhitespace)
        let characters = words.prefix(2).compactMap(\.first)
        return String(characters).uppercased()
    }
}

private struct ChatArea: View {
    let selectedChat: ChatThread?
    let messages: [ChatMessage]
    @Binding var draft: String
    @Binding var selectedModel: AIModel
    @Binding var showAttachmentNotice: Bool
    let isResponding: Bool
    let onSend: () -> Void
    let onRequestDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selectedChat?.title ?? "New chat")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Menu {
                    Button("Delete chat", systemImage: "trash", role: .destructive) {
                        onRequestDelete()
                    }
                    .disabled(selectedChat == nil)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)

            if messages.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 25))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                    Text("How can I help?")
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text("Ask anything, explore an idea, or start a new plan.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            ForEach(messages) { message in
                                MessageRow(message: message)
                                    .id(message.id)
                            }
                        }
                        .frame(maxWidth: 720)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 20)
                    }
                    .onChange(of: messages) { _, updatedMessages in
                        guard let lastID = updatedMessages.last?.id else { return }
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }

            VStack(spacing: 8) {
                if showAttachmentNotice {
                    Text("Attachments are coming soon")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                VStack(spacing: 5) {
                    TextField("Message EcoAI", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineLimit(1...6)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 7)
                        .onSubmit(onSend)

                    HStack {
                        Button {
                            withAnimation { showAttachmentNotice.toggle() }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.055), in: Circle())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Menu {
                            ForEach(AIModel.allCases) { model in
                                Button {
                                    selectedModel = model
                                } label: {
                                    if selectedModel == model {
                                        Label(model.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(model.displayName)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedModel.displayName)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 25)
                            .background(Color.primary.opacity(0.045), in: Capsule())
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)

                        Spacer()

                        Button(action: onSend) {
                            Group {
                                if isResponding {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(canSend ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                                }
                            }
                            .frame(width: 30, height: 30)
                            .background(canSend ? Color.primary : Color.primary.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                    }
                }
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 12, y: 4)

                Text("LLMs can make mistakes. Check important information.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 28)
            .padding(.bottom, 18)
        }
    }

    private var canSend: Bool {
        !isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user { Spacer(minLength: 72) }

            if message.role == .assistant {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 27, height: 27)
                    .background(Color.green.opacity(0.1), in: Circle())
            }

            Group {
                if message.content.isEmpty {
                    HStack(spacing: 4) {
                        Circle().frame(width: 4, height: 4)
                        Circle().frame(width: 4, height: 4)
                        Circle().frame(width: 4, height: 4)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 9)
                } else {
                    Text(message.content)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, message.role == .user ? 15 : 0)
            .padding(.vertical, message.role == .user ? 10 : 3)
            .background(
                message.role == .user ? Color.primary.opacity(0.07) : .clear,
                in: RoundedRectangle(cornerRadius: 16)
            )

            if message.role == .assistant { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(
            chatStore: ChatStore(
                accessPoint: CloudflareAccessPoint(
                    configuration: .preview,
                    tokenProvider: PreviewAccessTokenProvider()
                ),
                repository: ChatLocalRepository(
                    storageURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("ecoai-preview-chat-history.json")
                )
            ),
            appTheme: .constant(.system),
            showChatHistory: .constant(true),
            showEnergyUsage: .constant(true)
        )
            .frame(width: 1200, height: 760)
    }
}
