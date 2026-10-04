import SwiftUI
import VoltscopeCore

struct HistoryStatusBar: View {
    let battery: BatterySnapshot?
    @Environment(\.colorScheme) private var colorScheme

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
            Image(systemName: chargeIcon).foregroundStyle(chargeColor).accessibilityHidden(true)
            Text(chargeText)
                .font(.callout.bold().monospacedDigit())
            Text(chargeStateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(chargeAccessibilityValue), \(chargeStateLabel.isEmpty ? "status unavailable" : chargeStateLabel.lowercased())")
        .accessibilityIdentifier(AccessibilityIdentifiers.historyStatusCharge)
    }

    private var healthBlock: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .foregroundStyle(healthColor)
                .accessibilityHidden(true)
            Text(healthText)
                .font(.callout.monospacedDigit())
            Text(conditionText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery health \(healthAccessibilityValue), condition \(conditionText)")
        .accessibilityIdentifier(AccessibilityIdentifiers.historyStatusHealth)
    }

    private var tempBlock: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(tempText).font(.callout.monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery temperature \(temperatureAccessibilityValue)")
        .accessibilityIdentifier(AccessibilityIdentifiers.historyStatusTemp)
    }

    private var timeBlock: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(timeText).font(.callout.monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time remaining: \(timeAccessibilityValue)")
        .accessibilityIdentifier(AccessibilityIdentifiers.historyStatusTime)
    }

    private var drainBlock: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(drainIconColor)
                .accessibilityHidden(true)
            Text(drainText)
                .font(.callout.monospacedDigit())
        }
        .help(drainHelpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery power: \(drainAccessibilityValue)")
        .accessibilityHint(drainHelpText)
        .accessibilityIdentifier(AccessibilityIdentifiers.historyStatusDrain)
    }

    private var drainHelpText: String {
        AccessibilityLabels.batteryPowerHint(
            available: battery != nil,
            isCharging: battery?.isCharging ?? false,
            isACPlugged: battery?.isACPlugged ?? false
        )
    }

    private var drainIconColor: Color {
        guard let b = battery else { return .secondary }
        if b.isCharging || b.isACPlugged { return .green }
        return colorScheme == .light ? Color(nsColor: .systemOrange) : .yellow
    }

    private var drainText: String {
        guard let watts = battery?.instantaneousWatts else { return "—" }
        return String(format: "%.1f W", watts)
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

    private var chargeAccessibilityValue: String {
        guard let level = battery?.levelPercent else { return "charge unavailable" }
        return "\(Int(level.rounded())) percent"
    }

    private var healthAccessibilityValue: String {
        guard let ratio = healthRatio else { return "unavailable" }
        return "\(Int((ratio * 100).rounded())) percent"
    }

    private var temperatureAccessibilityValue: String {
        guard let celsius = battery?.temperatureC else { return "unavailable" }
        let fahrenheit = celsius * 9 / 5 + 32
        return String(format: "%.1f degrees Celsius, %.1f degrees Fahrenheit", celsius, fahrenheit)
    }

    private var timeAccessibilityValue: String {
        guard battery?.timeRemainingMin != nil, timeText != "—" else { return "unavailable" }
        return timeText
    }

    private var drainAccessibilityValue: String {
        guard let watts = battery?.instantaneousWatts else { return "unavailable" }
        let state = battery?.isCharging == true ? "charging" : battery?.isACPlugged == true ? "plugged in" : "discharging"
        return String(format: "%.1f watts, %@", watts, state)
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
