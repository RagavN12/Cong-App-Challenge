import SwiftUI

private struct TransientNotification: ViewModifier {
    let message: String?
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let message {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: dismiss) {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss notification")
                    }
                    .padding(14)
                    .frame(maxWidth: 360)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(18)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: message)
            .task(id: message) {
                guard message != nil else { return }
                do {
                    try await Task.sleep(for: .seconds(5))
                    try Task.checkCancellation()
                    dismiss()
                } catch { /* A replacement notification gets its own timer. */ }
            }
    }
}

extension View {
    func transientNotification(message: String?, dismiss: @escaping () -> Void) -> some View {
        modifier(TransientNotification(message: message, dismiss: dismiss))
    }
}
