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
    public static let historyDisplayOptions = "history.displayOptions"
    public static let historyGroupSystemProcesses = "history.groupSystemProcesses"
    public static let historyExportCSV = "history.exportCSV"
    public static let historyClearAppSelection = "history.clearAppSelection"
    public static let historySystemProcesses = "history.systemProcesses"
    public static let historyChartBattery = "history.chartBattery"
    public static let historyChartEnergy = "history.chartEnergy"
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

/// Spoken accessibility text for controls whose labels explain dynamic state.
public enum AccessibilityLabels {
    /// VoiceOver label for the History battery level chart container.
    public static let batteryLevelChartLabel = "Battery level chart"
    /// VoiceOver label for the History App CPU energy chart container.
    public static let appCPUEnergyChartLabel = "App CPU energy chart"

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
}
