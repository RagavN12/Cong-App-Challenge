import SwiftUI

struct EnergyLimitReachedView: View {
    @ObservedObject var store: EnergyUsageStore
    let onDismiss: () -> Void

    private var period: String { store.budget.period == .daily ? "today" : "this week" }
    private var comparison: EnergyLimitContext { EnergyLimitContext(wattHours: store.usedWattHours) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close energy summary")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.green)
                        .frame(width: 78, height: 78)
                        .background(Color.green.opacity(0.1), in: Circle())

                    VStack(spacing: 8) {
                        Text("A little pause for the planet")
                            .font(.system(size: 25, weight: .semibold, design: .rounded))
                        Text("You’ve reached your \(store.budget.period.title.lowercased()) energy limit.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(store.usedWattHours, format: .number.precision(.significantDigits(1...5)))
                                .font(.system(size: 54, weight: .semibold, design: .rounded))
                                .contentTransition(.numericText())
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            Text("Wh")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text("estimated energy used \(period)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 12) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text("Put into perspective")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(comparison.analogy)
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(22)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))

                    VStack(spacing: 6) {
                        Text("New messages are paused")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Your next \(store.budget.period == .daily ? "day" : "week") starts \(store.nextReset.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Text("Energy use is an estimate. This comparison assumes a 10 W LED bulb.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 38)
                .padding(.top, 2)
                .padding(.bottom, 22)
            }

            Button("Got it", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 26)
        }
        .frame(width: 580, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
