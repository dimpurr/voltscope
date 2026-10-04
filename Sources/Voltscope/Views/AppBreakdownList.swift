import SwiftUI
import VoltscopeCore

struct AppBreakdownList: View {
    let entries: [HistoryDatabase.AppBreakdownEntry]
    /// Precomputed sparklines for every recorded app in the selected toolbar range.
    let sparklines: [String: [SparkPoint]]
    let groupSystem: Bool
    let energyAvailable: Bool
    let range: ClosedRange<Date>
    let bucketSeconds: Int

    var body: some View {
        // No internal ScrollView — HistoryWindow wraps the whole panel in a
        // ScrollView so we don't need a nested one (which scrolls
        // independently and feels awkward).
        VStack(alignment: .leading, spacing: 4) {
            Text("Apps")
                .help("Percentages are shares of recorded App CPU energy for the selected toolbar range, not whole-device battery drain.")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            ForEach(userEntries) { entry in
                AppRow(
                    entry: entry,
                    sparkline: sparklines[entry.id] ?? [],
                    totalAll: totalEnergyNJ,
                    muted: false,
                    energyAvailable: energyAvailable,
                    range: range,
                    bucketSeconds: bucketSeconds
                )
            }

            if !systemEntries.isEmpty {
                if groupSystem {
                    SystemGroupSection(
                        entries: systemEntries,
                        sparklines: sparklines,
                        totalAll: totalEnergyNJ,
                        energyAvailable: energyAvailable,
                        range: range,
                        bucketSeconds: bucketSeconds
                    )
                } else {
                    ForEach(systemEntries) { entry in
                        AppRow(
                            entry: entry,
                            sparkline: sparklines[entry.id] ?? [],
                            totalAll: totalEnergyNJ,
                            muted: true,
                            energyAvailable: energyAvailable,
                            range: range,
                            bucketSeconds: bucketSeconds
                        )
                    }
                }
            }

            if entries.isEmpty {
                Text("No app energy in this range.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
        }
    }

    private var userEntries: [HistoryDatabase.AppBreakdownEntry] {
        entries.filter { !$0.isSystem }
    }

    private var systemEntries: [HistoryDatabase.AppBreakdownEntry] {
        entries.filter { $0.isSystem }
    }

    private var totalEnergyNJ: Int64 {
        entries.reduce(0) { $0 + $1.totalEnergyNJ }
    }
}

private struct AppRow: View {
    let entry: HistoryDatabase.AppBreakdownEntry
    let sparkline: [SparkPoint]
    let totalAll: Int64
    let muted: Bool
    let energyAvailable: Bool
    let range: ClosedRange<Date>
    let bucketSeconds: Int

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(path: entry.path, bundleId: entry.bundleIdentifier, size: 16)
                .opacity(muted ? 0.55 : 1)
            Text(entry.processName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(muted ? Color.secondary : Color.primary)
            Spacer(minLength: 8)
            Text(energyAvailable ? joulesText : cpuText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(muted ? Color.secondary : Color.primary)
                .frame(width: 70, alignment: .trailing)
            Text(percentText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
            SparklineMini(
                points: sparkline,
                color: muted ? .secondary : .accentColor,
                width: 80,
                height: 18
            )
        }
        .help(entry.bundleIdentifier ?? entry.processName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.processName)
        .accessibilityValue(accessibilityValue)
        .accessibilityChartDescriptor(chartDescriptor)
        .accessibilityIdentifier(AccessibilityIdentifiers.historyAppRow(appIdentity: entry.id))
    }

    private var chartDescriptor: HistoryAXChartDescriptor {
        let points = energyAvailable ? sparkline : []
        let series = HistoryAXSeries(name: "\(entry.processName) recorded CPU energy", points: points.map {
            AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.value, label: $0.date.formatted(date: .abbreviated, time: .shortened))
        }, isContinuous: false)
        let values = points.map(\.value)
        let maximum = max(values.max() ?? 0, 0.01)
        return HistoryAXChartDescriptor(title: "\(entry.processName) CPU energy trend", summary: accessibilityValue,
                                        xTitle: "Time", yTitle: energyAvailable ? "Joules" : "Seconds CPU",
                                        xRange: range.lowerBound.timeIntervalSince1970...range.upperBound.timeIntervalSince1970,
                                        yRange: 0...maximum, series: [series])
    }

    private var accessibilityValue: String {
        let value = energyAvailable
            ? "\(joulesText) recorded CPU energy"
            : "\(String(format: "%.1f", Double(entry.totalCPUNS) / 1_000_000_000)) seconds CPU time; per-process energy is unavailable"
        let share = energyAvailable && totalAll > 0 ? ", \(percentText) of recorded App CPU energy" : ""
        let points = energyAvailable ? sparkline.map { HistoryChartAccessibility.Point(date: $0.date, value: $0.value) } : []
        let trend = energyAvailable
            ? HistoryChartAccessibility.summary(title: "\(entry.processName) trend", range: range,
                                                points: points, unit: "joules", bucketSeconds: bucketSeconds)
            : "Trend unavailable because per-process energy is not provided on this Mac."
        return "\(value)\(share). \(trend)"
    }

    private var joulesText: String {
        let j = Double(entry.totalEnergyNJ) / 1_000_000_000.0
        if j >= 100 { return String(format: "%.0f J", j) }
        if j >= 10 { return String(format: "%.1f J", j) }
        return String(format: "%.2f J", j)
    }

    private var cpuText: String { String(format: "%.1f s", Double(entry.totalCPUNS) / 1_000_000_000) }

    private var percentText: String {
        guard energyAvailable, totalAll > 0 else { return "—" }
        let pct = Double(entry.totalEnergyNJ) / Double(totalAll) * 100
        return pct >= 1 ? String(format: "%.0f%%", pct) : "<1%"
    }
}

private struct SystemGroupSection: View {
    let entries: [HistoryDatabase.AppBreakdownEntry]
    let sparklines: [String: [SparkPoint]]
    let totalAll: Int64
    let energyAvailable: Bool
    let range: ClosedRange<Date>
    let bucketSeconds: Int
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries) { entry in
                    AppRow(
                        entry: entry,
                        sparkline: sparklines[entry.id] ?? [],
                        totalAll: totalAll,
                        muted: true,
                        energyAvailable: energyAvailable,
                        range: range,
                        bucketSeconds: bucketSeconds
                    )
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text("System")
                    .font(.callout.bold())
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(.top, 6)
        .accessibilityLabel("System processes, \(summary)")
        .accessibilityIdentifier(AccessibilityIdentifiers.historySystemProcesses)
    }

    private var summed: Int64 {
        entries.reduce(0) { $0 + $1.totalEnergyNJ }
    }

    private var summary: String {
        guard energyAvailable else { return "(\(entries.count) procs · ranked by CPU time)" }
        let j = Double(summed) / 1_000_000_000.0
        let pct: String = {
            guard totalAll > 0 else { return "—" }
            return String(format: "%.0f%%", Double(summed) / Double(totalAll) * 100)
        }()
        return String(format: "(%d procs · %.1f J · %@)", entries.count, j, pct)
    }
}
