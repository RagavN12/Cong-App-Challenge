import SwiftUI

struct LoginView: View {
    @Binding var appTheme: AppTheme
    let isWorking: Bool
    let errorMessage: String?
    let isConfigured: Bool
    let onLogin: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            subtleBackground

            VStack(spacing: 0) {
                Spacer(minLength: 36)

                VStack(spacing: 24) {
                    brand
                    loginCard
                }
                .frame(maxWidth: 390)

                Spacer(minLength: 28)

                Text("By continuing, you agree to use EcoAI responsibly.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 22)
            }

            VStack {
                HStack {
                    Spacer()
                    themeMenu
                }
                Spacer()
            }
            .padding(18)
        }
        .frame(minWidth: 760, minHeight: 640)
    }

    private var subtleBackground: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.045))
                .frame(width: 440, height: 440)
                .blur(radius: 2)
                .offset(x: 300, y: -260)
            Circle()
                .fill(Color.accentColor.opacity(0.035))
                .frame(width: 360, height: 360)
                .offset(x: -340, y: 280)
        }
        .allowsHitTesting(false)
    }

    private var brand: some View {
        VStack(spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 52, height: 52)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 15))

            VStack(spacing: 5) {
                Text("Welcome to EcoAI")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("Sign in to continue your conversations")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loginCard: some View {
        VStack(spacing: 17) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Secure sign in")
                    .font(.system(size: 14, weight: .semibold))

                Text("A secure browser window will open so you can log in or create an account. EcoAI never sees your password.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onLogin) {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(isWorking ? "Opening secure login…" : "Continue to login")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || !isConfigured)
            .opacity(isWorking || !isConfigured ? 0.5 : 1)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Authentication is handled by Auth0 using Authorization Code Flow with PKCE.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.055), radius: 20, y: 8)
    }

    private var themeMenu: some View {
        Menu {
            ForEach(AppTheme.allCases) { theme in
                Button {
                    appTheme = theme
                } label: {
                    Label(theme.title, systemImage: appTheme == theme ? "checkmark" : theme.symbol)
                }
            }
        } label: {
            Image(systemName: appTheme.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.055), in: Circle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Appearance")
    }
}
