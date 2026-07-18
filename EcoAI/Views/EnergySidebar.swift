import SwiftUI

struct EnergySidebar: View {
    @Binding var energy: Double
    let usage: EnergyUsageSnapshot

    @State private var showPromptTip = false

    init(energy: Binding<Double>, usage: EnergyUsageSnapshot = .preview) {
        _energy = energy
        self.usage = usage
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Energy usage")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Today")
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
                        title: "Daily tokens",
                        icon: "text.word.spacing",
                        tint: .blue,
                        metric: usage.tokens,
                        formatter: Self.formatTokens
                    )

                    UsageMetricCard(
                        title: "Daily electricity",
                        icon: "bolt.fill",
                        tint: .orange,
                        metric: usage.electricityWattHours,
                        formatter: Self.formatElectricity
                    )

                    analogyCard
                    promptCoach
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
                    .trim(from: 0, to: energy / 100)
                    .stroke(
                        AngularGradient(colors: [.green, .mint, .green], center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.25), value: energy)

                VStack(spacing: 1) {
                    Text("\(Int(energy))%")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("available")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 116, height: 116)

            Slider(value: $energy, in: 1...100, step: 1)
                .tint(.green)
                .accessibilityLabel("Available energy")
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

    private var promptCoach: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.11))
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Prompt smarter")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Use less energy")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPromptTip.toggle()
                    }
                } label: {
                    Image(systemName: showPromptTip ? "chevron.up" : "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 27, height: 27)
                        .foregroundStyle(.secondary)
                        .background(Color.primary.opacity(0.055), in: Circle())
                }
                .buttonStyle(.plain)
                .help(showPromptTip ? "Hide recommendation" : "Show recommendation")
            }

            if showPromptTip {
                Divider()
                Text(usage.promptRecommendation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
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
