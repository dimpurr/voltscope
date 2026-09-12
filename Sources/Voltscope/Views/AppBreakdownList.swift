import SwiftUI
import VoltscopeCore

struct AppBreakdownList: View {
    let entries: [AppDatabase.AppBreakdownEntry]
    /// Precomputed sparklines for every recorded app in the selected toolbar range.
    let sparklines: [String: [SparkPoint]]
    let groupSystem: Bool

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
                    muted: false
                )
            }

            if !systemEntries.isEmpty {
                if groupSystem {
                    SystemGroupSection(
                        entries: systemEntries,
                        sparklines: sparklines,
                        totalAll: totalEnergyNJ
                    )
                } else {
                    ForEach(systemEntries) { entry in
                        AppRow(
                            entry: entry,
                            sparkline: sparklines[entry.id] ?? [],
                            totalAll: totalEnergyNJ,
                            muted: false
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

    private var userEntries: [AppDatabase.AppBreakdownEntry] {
        entries.filter { !$0.isSystem }
    }

    private var systemEntries: [AppDatabase.AppBreakdownEntry] {
        entries.filter { $0.isSystem }
    }

    private var totalEnergyNJ: Int64 {
        entries.reduce(0) { $0 + $1.totalEnergyNJ }
    }
}

private struct AppRow: View {
    let entry: AppDatabase.AppBreakdownEntry
    let sparkline: [SparkPoint]
    let totalAll: Int64
    let muted: Bool

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(path: entry.path, bundleId: entry.bundleIdentifier, size: 16)
                .opacity(muted ? 0.55 : 1)
            Text(entry.processName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(muted ? Color.secondary : Color.primary)
            Spacer(minLength: 8)
            Text(joulesText)
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
    }

    private var joulesText: String {
        let j = Double(entry.totalEnergyNJ) / 1_000_000_000.0
        if j >= 100 { return String(format: "%.0f J", j) }
        if j >= 10 { return String(format: "%.1f J", j) }
        return String(format: "%.2f J", j)
    }

    private var percentText: String {
        guard totalAll > 0 else { return "—" }
        let pct = Double(entry.totalEnergyNJ) / Double(totalAll) * 100
        return pct >= 1 ? String(format: "%.0f%%", pct) : "<1%"
    }
}

private struct SystemGroupSection: View {
    let entries: [AppDatabase.AppBreakdownEntry]
    let sparklines: [String: [SparkPoint]]
    let totalAll: Int64
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries) { entry in
                    AppRow(
                        entry: entry,
                        sparkline: sparklines[entry.id] ?? [],
                        totalAll: totalAll,
                        muted: true
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
    }

    private var summed: Int64 {
        entries.reduce(0) { $0 + $1.totalEnergyNJ }
    }

    private var summary: String {
        let j = Double(summed) / 1_000_000_000.0
        let pct: String = {
            guard totalAll > 0 else { return "—" }
            return String(format: "%.0f%%", Double(summed) / Double(totalAll) * 100)
        }()
        return String(format: "(%d procs · %.1f J · %@)", entries.count, j, pct)
    }
}
