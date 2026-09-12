import SwiftUI
import VoltscopeCore

struct HistoryStatusBar: View {
    let battery: BatterySnapshot?

    var body: some View {
        HStack(spacing: 24) {
            chargeBlock
            healthBlock
            tempBlock
            timeBlock
            drainBlock
            Spacer(minLength: 0)
        }
    }

    private var chargeBlock: some View {
        HStack(spacing: 6) {
            Image(systemName: chargeIcon).foregroundStyle(chargeColor)
            Text(chargeText)
                .font(.callout.bold().monospacedDigit())
            Text(chargeStateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var healthBlock: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .foregroundStyle(healthColor)
            Text(healthText)
                .font(.callout.monospacedDigit())
            Text(conditionText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tempBlock: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(.secondary)
            Text(tempText).font(.callout.monospacedDigit())
        }
    }

    private var timeBlock: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
                .foregroundStyle(.secondary)
            Text(timeText).font(.callout.monospacedDigit())
        }
    }

    private var drainBlock: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(drainIconColor)
            Text(drainText)
                .font(.callout.monospacedDigit())
                .help(drainHelpText)
        }
    }

    private var drainIconColor: Color {
        guard let b = battery else { return .secondary }
        return b.isCharging || b.isACPlugged ? .green : .yellow
    }

    private var drainText: String {
        guard let watts = battery?.instantaneousWatts else { return "—" }
        return String(format: "%.1f W", watts)
    }

    private var drainHelpText: String {
        guard let b = battery else { return "Power draw" }
        if b.isCharging { return "Power flowing into the battery (V × I); excludes system power" }
        if b.isACPlugged { return "Battery current magnitude while connected to AC; not total adapter power" }
        return "Battery discharge rate (V × I)"
    }

    private var chargeIcon: String {
        guard let b = battery else { return "bolt.slash" }
        if b.isCharging { return "bolt.fill" }
        if b.isACPlugged { return "powerplug.fill" }
        return "battery.50"
    }

    private var chargeColor: Color {
        guard let b = battery, let level = b.levelPercent else { return .secondary }
        if b.isCharging || b.isACPlugged { return .green }
        if level < 20 { return .red }
        if level < 40 { return .orange }
        return .green
    }

    private var chargeText: String {
        guard let level = battery?.levelPercent else { return "—" }
        return "\(Int(level.rounded()))%"
    }

    private var chargeStateLabel: String {
        guard let b = battery else { return "" }
        if b.isCharging { return "Charging" }
        if b.isACPlugged { return "Plugged in" }
        return "On battery"
    }

    private var healthColor: Color {
        guard let r = healthRatio else { return .secondary }
        if r < 0.80 { return .red }
        if r < 0.88 { return .orange }
        return .pink
    }

    private var healthRatio: Double? {
        guard let b = battery, let cap = b.capacityMAh, let design = b.designMAh, design > 0 else { return nil }
        return Double(cap) / Double(design)
    }

    private var healthText: String {
        guard let r = healthRatio else { return "—" }
        return "\(Int((r * 100).rounded()))%"
    }

    private var conditionText: String {
        BatteryCondition.classify(
            cycleCount: battery?.cycleCount,
            capacityMAh: battery?.capacityMAh,
            designMAh: battery?.designMAh
        ).rawValue
    }

    private var tempText: String {
        guard let c = battery?.temperatureC else { return "—" }
        let f = c * 9 / 5 + 32
        return String(format: "%.1f °C / %.1f °F", c, f)
    }

    private var timeText: String {
        guard let b = battery, let m = b.timeRemainingMin, m > 0 else { return "—" }
        let h = m / 60
        let mm = m % 60
        let suffix = b.isCharging ? "until full" : "until empty"
        return h > 0 ? String(format: "%dh %02dm %@", h, mm, suffix) : String(format: "%dm %@", mm, suffix)
    }
}
