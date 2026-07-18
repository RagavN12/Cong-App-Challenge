import SwiftUI

struct LoginView: View {
    @Binding var appTheme: AppTheme
    let onLogin: (String, String) -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
    }

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
        .onAppear { focusedField = .email }
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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Email")
                    .font(.system(size: 11, weight: .medium))
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .email)
                    .onSubmit { focusedField = .password }
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Password")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Forgot password?") {}
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(true)
                }

                HStack(spacing: 6) {
                    Group {
                        if showPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .password)
                    .onSubmit(logIn)

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(showPassword ? "Hide password" : "Show password")
                }
                .padding(.horizontal, 11)
                .frame(height: 38)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            }

            Button(action: logIn) {
                Text("Log in")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canLogIn)
            .opacity(canLogIn ? 1 : 0.45)

            HStack(spacing: 4) {
                Text("New to EcoAI?")
                    .foregroundStyle(.secondary)
                Button("Create an account") {}
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(true)
            }
            .font(.system(size: 10))
            .frame(maxWidth: .infinity)
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

    private var canLogIn: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func logIn() {
        guard canLogIn else { return }
        onLogin(email.trimmingCharacters(in: .whitespacesAndNewlines), password)
    }
}
