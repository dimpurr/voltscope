import SwiftUI
import AppKit
import VoltscopeCore

struct MenuBarPanel: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var systemExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chargeHeader
            Divider()
            healthSection
            Divider()
            topAppsSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: - Charge header

    private var chargeHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: chargeSymbol)
                    .foregroundStyle(chargeColor)
                Text(chargeStateText)
                    .font(.headline)
                Spacer()
                Text(percentText)
                    .font(.headline.monospacedDigit())
            }
            ProgressView(value: (appState.lastBattery?.levelPercent ?? 0) / 100.0)
                .progressViewStyle(.linear)
                .tint(chargeColor)
            HStack {
                Text(timeRemainingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(appState.statusText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var chargeSymbol: String {
        guard let battery = appState.lastBattery else { return "bolt.slash" }
        if battery.isCharging { return "bolt.fill" }
        if battery.isACPlugged { return "powerplug.fill" }
        return "battery.50"
    }

    private var chargeColor: Color {
        guard let battery = appState.lastBattery, let level = battery.levelPercent else { return .secondary }
        if battery.isCharging || battery.isACPlugged { return .green }
        if level < 20 { return .red }
        if level < 40 { return .orange }
        return .green
    }

    private var chargeStateText: String {
        guard let battery = appState.lastBattery else { return "Battery" }
        if battery.isCharging { return "Charging" }
        if battery.isACPlugged { return "Battery Is Charged" }
        return "On Battery"
    }

    private var percentText: String {
        guard let level = appState.lastBattery?.levelPercent else { return "—" }
        return "\(Int(level.rounded()))%"
    }

    private var timeRemainingText: String {
        guard let battery = appState.lastBattery, let minutes = battery.timeRemainingMin, minutes > 0 else {
            return "—"
        }
        let h = minutes / 60
        let m = minutes % 60
        let suffix = battery.isCharging ? "until full" : "until empty"
        if h > 0 {
            return String(format: "%dh %02dm %@", h, m, suffix)
        }
        return String(format: "%dm %@", m, suffix)
    }

    // MARK: - Health section

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Health").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(healthPercentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HealthBar(healthRatio: healthRatio ?? 0)
            HStack(spacing: 16) {
                LabeledMetric(label: "Cycles", value: cycleText)
                LabeledMetric(label: "Condition", value: conditionText)
                Spacer()
                Text(temperatureText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
    }

    private var healthRatio: Double? {
        guard let battery = appState.lastBattery,
              let capacity = battery.capacityMAh,
              let design = battery.designMAh,
              design > 0 else { return nil }
        return Double(capacity) / Double(design)
    }

    private var healthPercentText: String {
        guard let ratio = healthRatio else { return "—" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    private var cycleText: String {
        guard let cycles = appState.lastBattery?.cycleCount else { return "—" }
        return "\(cycles)"
    }

    private var conditionText: String {
        BatteryCondition.classify(
            cycleCount: appState.lastBattery?.cycleCount,
            capacityMAh: appState.lastBattery?.capacityMAh,
            designMAh: appState.lastBattery?.designMAh
        ).rawValue
    }

    private var temperatureText: String {
        guard let celsius = appState.lastBattery?.temperatureC else { return "—" }
        let fahrenheit = celsius * 9 / 5 + 32
        return String(format: "%.1f °C / %.1f °F", celsius, fahrenheit)
    }

    // MARK: - Top apps section

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top energy use (last 30 min)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if appState.topApps.isEmpty && appState.systemSummary.count == 0 {
                Text("Collecting samples…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                let topMax = appState.topApps.map(\.totalEnergyNJ).max() ?? 0
                ForEach(appState.topApps) { row in
                    appRow(row, topMax: topMax)
                }
                if appState.systemSummary.count > 0 {
                    systemRow
                }
            }
        }
    }

    private func appRow(_ row: AppDatabase.TopAppEnergy, topMax: Int64) -> some View {
        HStack(spacing: 8) {
            AppIconView(path: row.path, bundleId: row.bundleIdentifier, size: 16)
            Text(row.processName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            IntensityDots(filled: IntensityDots.dotCount(value: row.totalEnergyNJ, max: topMax))
            Button {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Open in History window")
        }
        .help(rowTooltip(row))
    }

    private func rowTooltip(_ row: AppDatabase.TopAppEnergy) -> String {
        let joules = Double(row.totalEnergyNJ) / 1_000_000_000.0
        let bundle = row.bundleIdentifier ?? "(no bundle)"
        return String(format: "%@\n%@\nLast 30 min: %.2f J", row.processName, bundle, joules)
    }

    /// Collapsible footer row: keeps system processes in the dropdown
    /// (geek users want them) but out of the user-app stack by default.
    /// Expanded shows the top 5 system processes inline, mirroring the user
    /// app section above. Symmetric layout keeps the dropdown predictable.
    private var systemRow: some View {
        DisclosureGroup(isExpanded: $systemExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                let systemMax = appState.systemSummary.topItems.map(\.totalEnergyNJ).max() ?? 0
                ForEach(appState.systemSummary.topItems) { row in
                    appRow(row, topMax: systemMax)
                        .opacity(0.7)
                }
                if appState.systemSummary.count > appState.systemSummary.topItems.count {
                    Text("+ \(appState.systemSummary.count - appState.systemSummary.topItems.count) more in History")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 24)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2")
                    .foregroundStyle(.secondary)
                Text("System")
                    .foregroundStyle(.secondary)
                Text(systemSummaryText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    private var systemSummaryText: String {
        let s = appState.systemSummary
        let j = Double(s.totalEnergyNJ) / 1_000_000_000.0
        return String(format: "%d procs · %.2f J", s.count, j)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open History", systemImage: "chart.bar.xaxis")
            }
            Spacer()
            Button {
                appState.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct LabeledMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout)
        }
    }
}
