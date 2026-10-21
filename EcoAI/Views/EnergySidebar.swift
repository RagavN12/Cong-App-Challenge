import SwiftUI

struct EnergySidebar: View {
    let usage: EnergyUsageSnapshot
    let budget: EnergyBudget

    private var fraction: Double { max(usage.electricityWattHours.total, 0) / budget.limitWattHours }
    private var limitReached: Bool { fraction >= 1 }
    private var gaugeColor: Color { limitReached ? .orange : .green }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Energy usage")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(budget.period.sidebarTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.055), in: Capsule())
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            ScrollView {
                VStack(spacing: 12) {
                    energyGauge

                    UsageMetricCard(
                        title: "\(budget.period.title) tokens",
                        icon: "text.word.spacing",
                        tint: .blue,
                        metric: usage.tokens,
                        formatter: Self.formatTokens
                    )

                    UsageMetricCard(
                        title: "\(budget.period.title) electricity",
                        icon: "bolt.fill",
                        tint: .orange,
                        metric: usage.electricityWattHours,
                        formatter: Self.formatElectricity
                    )

                    analogyCard
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
            }
        }
        .background(Color.primary.opacity(0.018))
    }

    private var energyGauge: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.07), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: min(fraction, 1))
                    .stroke(
                        AngularGradient(colors: [gaugeColor, gaugeColor.opacity(0.65), gaugeColor], center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.25), value: fraction)

                VStack(spacing: 1) {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("of limit used")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 116, height: 116)

            VStack(spacing: 7) {
                ProgressView(value: min(fraction, 1))
                    .tint(gaugeColor)
                    .accessibilityLabel("Energy limit used")
                Text("\(Self.formatElectricity(usage.electricityWattHours.total)) of \(Self.formatElectricity(budget.limitWattHours))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if limitReached {
                    Text("Limit reached — new messages paused")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var analogyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.max.fill")
                .font(.system(size: 13))
                .foregroundStyle(.yellow)
                .frame(width: 28, height: 28)
                .background(Color.yellow.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("Put into perspective")
                    .font(.system(size: 11, weight: .semibold))
                Text(usage.analogy)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    nonisolated private static func formatTokens(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.1fK", value / 1_000) : String(Int(value))
    }

    nonisolated private static func formatElectricity(_ value: Double) -> String {
        String(format: "%.3f Wh", value)
    }
}

private struct UsageMetricCard: View {
    let title: String
    let icon: String
    let tint: Color
    let metric: EnergyUsageSnapshot.Metric
    let formatter: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 23, height: 23)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 0) {
                MetricValue(label: "Input", value: formatter(metric.input))
                Divider().frame(height: 27)
                MetricValue(label: "Output", value: formatter(metric.output))
                Divider().frame(height: 27)
                MetricValue(label: "Total", value: formatter(metric.total), emphasized: true)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

private struct MetricValue: View {
    let label: String
    let value: String
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: emphasized ? .semibold : .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 7)
    }
}
