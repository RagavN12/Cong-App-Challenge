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
    @StateObject private var chatStore: ChatStore
    @StateObject private var sessionStore: SessionStore
    @AppStorage("appearance.theme") private var appTheme = AppTheme.system
    @AppStorage("panels.chatHistory.visible") private var showChatHistory = true
    @AppStorage("panels.energyUsage.visible") private var showEnergyUsage = true

    init() {
        let accessPoint = CloudflareAccessPoint(configuration: .preview)
        let repository = ChatLocalRepository()
        _chatStore = StateObject(
            wrappedValue: ChatStore(
                accessPoint: accessPoint,
                repository: repository
            )
        )
        _sessionStore = StateObject(wrappedValue: SessionStore())
    }

    var body: some Scene {
        WindowGroup {
            AppThemeHost(theme: appTheme) {
                Group {
                    if sessionStore.isAuthenticated {
                        ContentView(
                            chatStore: chatStore,
                            appTheme: $appTheme,
                            showChatHistory: $showChatHistory,
                            showEnergyUsage: $showEnergyUsage,
                            onLogout: {
                                chatStore.cancelAllResponses()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    sessionStore.logOut()
                                }
                            }
                        )
                        .transition(.opacity)
                    } else {
                        LoginView(appTheme: $appTheme) { email, password in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sessionStore.logIn(email: email, password: password)
                            }
                        }
                        .transition(.opacity)
                    }
                }
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
