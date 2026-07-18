import SwiftUI

struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case data = "Data & Privacy"
        case account = "Account"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .data: "hand.raised"
            case .account: "person.crop.circle"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    let user: AuthenticatedUser?
    @Binding var appTheme: AppTheme
    @Binding var showChatHistory: Bool
    @Binding var showEnergyUsage: Bool
    @Binding var selectedModel: AIModel
    let onLogout: () -> Void

    @State private var selectedPane = Pane.general
    @State private var showDeleteAccountWarning = false

    var body: some View {
        HStack(spacing: 0) {
            navigation
                .frame(width: 168)

            Divider()

            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    paneContent
                        .frame(maxWidth: 560, alignment: .topLeading)
                        .padding(28)
                }
            }
        }
        .frame(width: 700, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Delete your account?", isPresented: $showDeleteAccountWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) {
                // Frontend-only confirmation. Account deletion will be wired later.
            }
        } message: {
            Text("This will permanently delete your account, chat history, and usage data. This action cannot be undone.")
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 18, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 20)
                .padding(.bottom, 16)

            ForEach(Pane.allCases) { pane in
                Button {
                    selectedPane = pane
                } label: {
                    Label(pane.rawValue, systemImage: pane.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            selectedPane == pane ? Color.primary.opacity(0.075) : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()

            Text("EcoAI for macOS")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(14)
        }
        .background(Color.primary.opacity(0.025))
    }

    private var header: some View {
        HStack {
            Text(selectedPane.rawValue)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close settings")
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .general:
            generalPane
        case .data:
            dataPane
        case .account:
            accountPane
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection(
                title: "Appearance",
                description: "Choose how EcoAI looks on this Mac."
            ) {
                HStack(spacing: 10) {
                    ForEach(AppTheme.allCases) { theme in
                        Button {
                            appTheme = theme
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: theme.symbol)
                                    .font(.system(size: 18, weight: .medium))
                                Text(theme.title)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(appTheme == theme ? Color.accentColor : Color.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 70)
                            .background(
                                appTheme == theme ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.025),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(
                                        appTheme == theme ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            SettingsSection(
                title: "Panels",
                description: "Choose which supporting panels remain visible."
            ) {
                VStack(spacing: 0) {
                    SettingsToggleRow(
                        title: "Chat history",
                        subtitle: "Show your conversations on the left",
                        isOn: $showChatHistory
                    )
                    Divider().padding(.leading, 38)
                    SettingsToggleRow(
                        title: "Energy usage",
                        subtitle: "Show token and electricity estimates",
                        isOn: $showEnergyUsage
                    )
                }
                .settingsCard()
            }

            SettingsSection(
                title: "Default model",
                description: "The model selected when starting a conversation."
            ) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(AIModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: 180, alignment: .leading)
            }
        }
    }

    private var dataPane: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(
                title: "Chat history",
                description: "Your conversations are currently stored locally on this Mac. Cloud synchronization can be added when your account is connected."
            ) {
                Label("Stored on this Mac", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsCard()
            }

            SettingsSection(
                title: "Export data",
                description: "Download a copy of your chats and usage information."
            ) {
                Button("Export data") {}
                    .disabled(true)
                Text("Coming soon")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var accountPane: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 14) {
                AccountAvatar(user: user, size: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(user?.displayName ?? "EcoAI User")
                        .font(.system(size: 15, weight: .semibold))
                    Text(user?.email ?? "Personal account")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(
                title: "Account access",
                description: "Authentication and account details will be managed through your connected EcoAI account."
            ) {
                Button("Log out") {
                    dismiss()
                    onLogout()
                }
            }

            Divider()

            SettingsSection(
                title: "Delete account",
                description: "Permanently remove your account and all associated data."
            ) {
                Button("Delete account", role: .destructive) {
                    showDeleteAccountWarning = true
                }
            }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }
}

private extension View {
    func settingsCard() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}
