import SwiftUI
import VoltscopeCore

/// Original v0.6.2 hardware column; independent channels are not battery shares.
struct EnergyBreakdownSection: View {
    let summaries: [AppDatabase.BucketSummary]
    let totalDrainJ: Double
    let bucketSeconds: Int
    let bucketSamplerAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if !bucketSamplerAvailable {
                unavailableNotice
            } else if summaries.isEmpty {
                Text("Collecting hardware bucket samples…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 24)
            } else {
                ForEach(summaries) { summary in
                    BucketRow(
                        summary: summary,
                        totalJ: largestChannelJ,
                        bucketSeconds: bucketSeconds
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Energy breakdown")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
            Text(headerSubtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }.help(String(format: "Independent hardware channels, potentially overlapping. Observed battery discharge: %.2f Wh; charging, supply transitions and sampling gaps excluded.", totalDrainJ / 3600))
    }

    private var headerSubtitle: String { "· hardware" }

    private var unavailableNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Hardware bucket sampling unavailable on this system")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            Text("No hardware energy channels were returned. App CPU attribution remains available separately.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 8)
    }

    private var largestChannelJ: Double {
        max(0.5, summaries.map { Double($0.totalEnergyNJ) / 1e9 }.max() ?? 0)
    }
}

private struct BucketRow: View {
    let summary: AppDatabase.BucketSummary
    let totalJ: Double
    let bucketSeconds: Int

    var body: some View {
        let joules = Double(summary.totalEnergyNJ) / 1_000_000_000.0
        let percent = totalJ > 0 ? (joules / totalJ * 100) : 0
        let color = bucketColor(summary.bucketName)
        HStack(spacing: 8) {
            Image(systemName: bucketIcon(summary.bucketName))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(summary.bucketName)
                .lineLimit(1)
                .help(summary.bucketName)
            Spacer(minLength: 8)
            BucketBar(percent: percent, color: color)
                .help("Relative channel magnitude; the largest channel fills the bar. Channels may overlap and are not percentages of battery drain.")
            Text(joulesText(joules))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 70, alignment: .trailing)
            BucketSparkline(
                points: summary.sparkline.map {
                    SparkPoint(date: $0.bucketStart,
                               value: Double($0.energyNJ) / 1_000_000_000.0)
                },
                color: color
            )
        }
    }

    private func bucketColor(_ name: String) -> Color {
        switch name {
        case "CPU":         return .blue
        case "GPU":         return .purple
        case "ANE":         return .red
        case "Video":       return .pink
        case "Camera":      return .yellow
        case "DRAM":        return .brown
        case "Fabric":      return .green
        case "Display":     return .orange
        case "PCIe":        return .cyan
        case "Wi-Fi":       return .teal
        case "Power Mgmt":  return .indigo
        case "SoC Other":   return .secondary
        default:            return .gray
        }
    }

    private func bucketIcon(_ name: String) -> String {
        switch name {
        case "CPU":         return "cpu"
        case "GPU":         return "memorychip"
        case "ANE":         return "brain"
        case "Video":       return "play.rectangle"
        case "Camera":      return "camera"
        case "DRAM":        return "memorychip.fill"
        case "Fabric":      return "circle.grid.cross"
        case "Display":     return "display"
        case "PCIe":        return "bolt.horizontal"
        case "Wi-Fi":       return "wifi"
        case "Power Mgmt":  return "bolt.shield"
        case "SoC Other":   return "questionmark.circle"
        default:            return "circle"
        }
    }

    private func joulesText(_ j: Double) -> String {
        if j >= 100 { return String(format: "%.0f J", j) }
        if j >= 10 { return String(format: "%.1f J", j) }
        if j >= 0.1 { return String(format: "%.2f J", j) }
        return String(format: "%.0f mJ", j * 1000)
    }
}

private struct BucketBar: View {
    let percent: Double
    let color: Color
    var opacity: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(opacity))
                    .frame(width: max(0, min(geo.size.width, geo.size.width * percent / 100)))
            }
        }
        .frame(width: 80, height: 6)
    }
}

private struct BucketSparkline: View {
    let points: [SparkPoint]
    let color: Color

    var body: some View {
        SparklineMini(points: points, color: color, width: 80, height: 18)
    }
}
