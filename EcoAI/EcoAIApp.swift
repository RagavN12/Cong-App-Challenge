//
//  EcoAIApp.swift
//  EcoAI
//
//  Created by Ragav Naresh on 7/18/26.
//

import AppKit
import SwiftUI

@main
struct EcoAIApp: App {
    @StateObject private var accountDataStore: AccountDataStore
    @StateObject private var sessionStore: SessionStore
    @AppStorage("appearance.theme") private var appTheme = AppTheme.system
    @AppStorage("panels.chatHistory.visible") private var showChatHistory = true
    @AppStorage("panels.energyUsage.visible") private var showEnergyUsage = true

    init() {
        let sessionStore = SessionStore()
        let accessPoint = CloudflareAccessPoint(
            configuration: .production(),
            tokenProvider: sessionStore
        )
        _accountDataStore = StateObject(wrappedValue: AccountDataStore(accessPoint: accessPoint))
        _sessionStore = StateObject(wrappedValue: sessionStore)
    }

    var body: some Scene {
        WindowGroup {
            AppThemeHost(theme: appTheme) {
                Group {
                    if sessionStore.isRestoringSession {
                        ProgressView("Restoring your session…")
                            .controlSize(.small)
                            .frame(minWidth: 760, minHeight: 640)
                    } else if sessionStore.isAuthenticated {
                        if let account = accountDataStore.account,
                           account.userID == sessionStore.user?.id {
                            AccountContentView(
                                chatStore: account.chats,
                                energyUsageStore: account.energy,
                                user: sessionStore.user,
                                appTheme: $appTheme,
                                showChatHistory: $showChatHistory,
                                showEnergyUsage: $showEnergyUsage,
                                onLogout: {
                                    accountDataStore.activate(userID: nil)
                                    Task { await sessionStore.logOut() }
                                }
                            )
                            .id(account.userID)
                        } else {
                            ProgressView("Opening your account…")
                                .frame(minWidth: 760, minHeight: 640)
                        }
                    } else {
                        LoginView(
                            appTheme: $appTheme,
                            isWorking: sessionStore.isWorking,
                            errorMessage: sessionStore.errorMessage,
                            isConfigured: sessionStore.isConfigured
                        ) {
                            Task {
                                await sessionStore.logIn()
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: sessionStore.isAuthenticated)
            }
            .task {
                await sessionStore.restoreSession()
            }
            .onChange(of: sessionStore.isAuthenticated && !sessionStore.isWorking ? sessionStore.user?.id : nil, initial: true) { _, userID in
                accountDataStore.activate(userID: userID)
            }
        }
        .defaultSize(width: 1200, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .sidebar) {
                Toggle("Chat History", isOn: $showChatHistory)
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Toggle("Energy Usage", isOn: $showEnergyUsage)
                    .keyboardShortcut("2", modifiers: [.command, .option])
            }
        }
    }
}

private struct AccountContentView: View {
    @ObservedObject var chatStore: ChatStore
    @ObservedObject var energyUsageStore: EnergyUsageStore
    let user: AuthenticatedUser?
    @Binding var appTheme: AppTheme
    @Binding var showChatHistory: Bool
    @Binding var showEnergyUsage: Bool
    let onLogout: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ContentView(
                chatStore: chatStore,
                user: user,
                energyUsageStore: energyUsageStore,
                appTheme: $appTheme,
                showChatHistory: $showChatHistory,
                showEnergyUsage: $showEnergyUsage,
                onLogout: onLogout,
                onRetryStorage: chatStore.loadState == .failed || energyUsageStore.loadState == .failed ? {
                    Task {
                        await energyUsageStore.load()
                        await chatStore.load()
                    }
                } : nil
            )
        }
        .task { await energyUsageStore.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { energyUsageStore.refreshPeriod() }
        }
        .transientNotification(message: chatStore.lastError ?? energyUsageStore.lastError) {
            if chatStore.lastError != nil { chatStore.dismissError() }
            else { energyUsageStore.dismissError() }
        }
    }
}

private struct AppThemeHost<Content: View>: View {
    // Observing this value causes a refresh when macOS changes appearance.
    @Environment(\.colorScheme) private var environmentColorScheme

    let theme: AppTheme
    @ViewBuilder let content: Content

    private var resolvedColorScheme: ColorScheme {
        guard theme == .system else { return theme.colorScheme ?? .light }

        _ = environmentColorScheme
        let systemStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        return systemStyle == "Dark" ? .dark : .light
    }

    var body: some View {
        content
            .environment(\.colorScheme, resolvedColorScheme)
            .preferredColorScheme(theme.colorScheme)
    }
}
