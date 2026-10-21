import SwiftUI

struct EnergyLimitsSettingsView: View {
    @ObservedObject var store: EnergyUsageStore
    @State private var limitText = ""

    private var parsedLimit: Double? {
        let text = limitText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let value = Double(text), EnergyBudget.isValidLimit(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Set your energy budget")
                    .font(.system(size: 18, weight: .semibold))
                Text("Choose how much estimated electricity EcoAI can use. New messages pause when your limit is reached.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Budget period").font(.system(size: 13, weight: .semibold))
                Picker("Budget period", selection: Binding(
                    get: { store.budget.period }, set: { store.setPeriod($0) }
                )) {
                    ForEach(EnergyBudgetPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(store.budget.period == .daily
                     ? "Resets every day at midnight in your local time."
                     : "Resets every Monday at midnight in your local time.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("\(store.budget.period.title) energy limit")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 10) {
                    TextField("Energy limit", text: $limitText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onSubmit(saveLimit)
                        .accessibilityLabel("Energy limit in watt-hours")
                    Text("Wh").foregroundStyle(.secondary)
                    Spacer()
                    Button("Save limit", action: saveLimit)
                        .buttonStyle(.borderedProminent)
                        .disabled(parsedLimit == nil || parsedLimit == store.budget.limitWattHours || !store.isReady)
                }
                if parsedLimit == nil {
                    Text("Enter a value from 0.001 to 1,000,000 Wh.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                Text("Daily and weekly limits are saved separately. Switching periods keeps your recorded usage.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(store.budget.period.sidebarTitle) so far")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(store.usedFraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                ProgressView(value: store.progress)
                    .tint(store.isLimitReached ? .orange : .green)
                Text("\(store.usedWattHours.formatted(.number.precision(.fractionLength(3)))) of \(store.budget.limitWattHours.formatted(.number.precision(.fractionLength(3)))) Wh used")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Resets \(store.nextReset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if store.isLimitReached {
                    Label("Limit reached. Increase it or wait for the next period to send more messages.", systemImage: "pause.circle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            Text("Electricity use is estimated from model token usage. A response already in progress can finish and may take the total slightly over your limit.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!store.isReady)
        .onChange(of: store.budget, initial: true) { _, budget in
            limitText = budget.limitWattHours.formatted(.number.grouping(.never).precision(.fractionLength(0...3)))
        }
    }

    private func saveLimit() {
        guard let value = parsedLimit else { return }
        store.setLimit(wattHours: value)
    }
}
