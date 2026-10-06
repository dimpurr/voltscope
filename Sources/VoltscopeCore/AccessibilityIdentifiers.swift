import Foundation

/// Stable accessibility identifiers used by the macOS UI and UI automation.
/// Treat these values as a public interface: do not rename them casually.
public enum AccessibilityIdentifiers {
    public static let menuBarItem = "menu.barItem"
    public static let menuOpenHistory = "menu.openHistory"
    public static let menuSettings = "menu.settings"
    public static let menuCheckForUpdates = "menu.checkForUpdates"
    public static let menuQuit = "menu.quit"
    public static let menuSystemProcesses = "menu.systemProcesses"
    public static func menuOpenAppInHistory(appIdentity: String) -> String {
        "menu.openAppInHistory.\(appIdentity)"
    }
    public static let historyTimeRange = "history.timeRange"
    /// Per-segment identifier for the segmented time control, so automation can
    /// reach a single range even when the `Picker` wrapper keeps its own
    /// identifier on the surrounding radio group.
    public static func historyTimeRangeOption(_ range: HistoryRange) -> String {
        "history.timeRange.\(range.rawValue)"
    }
    public static let historyDisplayOptions = "history.displayOptions"
    public static let historyGroupSystemProcesses = "history.groupSystemProcesses"
    public static let historyExportCSV = "history.exportCSV"
    public static let historyClearAppSelection = "history.clearAppSelection"
    public static let historySystemProcesses = "history.systemProcesses"
    /// Keyboard focus sections for the two breakdown columns under the chart.
    /// One stop per column keeps the Tab ring short while still letting a
    /// keyboard-only user reach both lists.
    public static let historyEnergyBreakdown = "history.energyBreakdown"
    public static let historyAppBreakdown = "history.appBreakdown"
    public static let historyChartBattery = "history.chartBattery"
    public static let historyChartEnergy = "history.chartEnergy"
    /// Legend chip identifier; `<series-id>` is the stable app identity, or
    /// `System` / `Other apps` for the aggregated rows.
    public static func historyLegendChip(seriesID: String) -> String {
        "history.legend.\(seriesID)"
    }
    public static let historyStatusCharge = "history.statusCharge"
    public static let historyStatusHealth = "history.statusHealth"
    public static let historyStatusTemp = "history.statusTemp"
    public static let historyStatusTime = "history.statusTime"
    public static let historyStatusDrain = "history.statusDrain"
    public static func historyAppRow(appIdentity: String) -> String {
        "history.appRow.\(appIdentity)"
    }
    public static let settingsLaunchAtLogin = "settings.launchAtLogin"
    public static let settingsOpenLoginItems = "settings.openLoginItems"
    public static let settingsRawRetention = "settings.rawRetention"
    public static let settingsDeleteLegacyDatabase = "settings.deleteLegacyDatabase"
    public static let welcomeNotNow = "welcome.notNow"
    public static let welcomeDone = "welcome.done"
    public static let welcomeOpenLoginItems = "welcome.openLoginItems"
    public static let welcomeEnableAtLogin = "welcome.enableAtLogin"
}

/// Shared hit-target geometry so controls can meet one documented minimum
/// instead of each view picking its own padding.
public enum AccessibilityMetrics {
    /// Minimum pointer and keyboard target size in points.
    ///
    /// WCAG 2.2 SC 2.5.8 Target Size (Minimum) asks for 24 by 24 CSS pixels,
    /// which matches the macOS HIG minimum control height.
    public static let minimumTargetSize: CGFloat = 24
}

/// Spoken accessibility text for controls whose labels explain dynamic state.
public enum AccessibilityLabels {
    public static func openHistoryFromApp(name: String) -> String {
        "Open History from \(name)"
    }

    public static func menuBarBatteryValue(levelPercent: Double?, isCharging: Bool, isACPlugged: Bool) -> String {
        guard let level = levelPercent else {
            return "Battery status unavailable"
        }
        let percent = Int(level.rounded())
        let state: String
        if isCharging {
            state = "charging"
        } else if isACPlugged {
            state = "on AC power"
        } else {
            state = "on battery"
        }
        return "\(percent) percent, \(state)"
    }

    public static func menuBarAppRowValue(energyNJ: Int64, cpuNS: Int64, energyAvailable: Bool) -> String {
        if energyAvailable {
            let joules = Double(energyNJ) / 1_000_000_000.0
            return String(format: "%.2f J recorded CPU energy", joules)
        } else {
            let seconds = Double(cpuNS) / 1_000_000_000.0
            return String(format: "%.1fs CPU time", seconds)
        }
    }

    public static func batteryPowerHint(available: Bool, isCharging: Bool, isACPlugged: Bool) -> String {
        guard available else { return "Power draw" }
        if isCharging { return "Power flowing into the battery (V × I); excludes system power" }
        if isACPlugged { return "Battery current magnitude while connected to AC; not total adapter power" }
        return "Battery discharge rate (V × I)"
    }

    public static func hardwareBucketValue(joulesText: String, percent: Double) -> String {
        "\(joulesText), \(Int(percent.rounded())) percent of largest hardware channel"
    }

    public static func legendSelectionValue(selected: Bool, anySelected: Bool) -> String {
        if selected { return "Highlighted" }
        return anySelected ? "Muted" : "All apps shown"
    }

    /// Spoken name for the History Display menu.
    ///
    /// The control is an icon-only toolbar menu, so its name has to be supplied
    /// instead of read from the visible "Display" caption.
    public static let displayOptionsName = "Display options"

    /// Dynamic value for the Display menu: the state of the one toggle it holds.
    public static func displayOptionsValue(groupSystemProcesses: Bool) -> String {
        groupSystemProcesses ? "System processes grouped" : "System processes listed individually"
    }

    /// Spoken label for the grouped system-processes row.
    ///
    /// The on-screen caption is a compact `(count · joules · percent)` summary.
    /// The spoken label expands it so VoiceOver states that the joules and the
    /// percentage both refer to recorded App CPU energy, not whole-device
    /// battery drain. `percent` is `nil` when no recorded energy exists to take
    /// a share of.
    public static func systemProcessesGroupLabel(count: Int, joules: Double, percent: Double?) -> String {
        let processes = count == 1 ? "1 process" : "\(count) processes"
        let energy = "\(String(format: "%.1f", joules)) joules of recorded App CPU energy"
        guard let percent else {
            return "System processes: \(processes), \(energy)"
        }
        return "System processes: \(processes), \(energy), \(Int(percent.rounded())) percent of recorded App CPU energy"
    }

    /// Spoken label for the grouped system-processes row when per-process
    /// energy is unavailable (Intel Macs), where the row ranks by CPU time.
    public static func systemProcessesGroupLabel(count: Int) -> String {
        let processes = count == 1 ? "1 process" : "\(count) processes"
        return "System processes: \(processes), ranked by CPU time"
    }
}
