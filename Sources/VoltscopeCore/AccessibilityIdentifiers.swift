/// Stable accessibility identifiers used by the macOS UI and UI automation.
/// Treat these values as a public interface: do not rename them casually.
public enum AccessibilityIdentifiers {
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
    public static let settingsLaunchAtLogin = "settings.launchAtLogin"
    public static let settingsOpenLoginItems = "settings.openLoginItems"
    public static let settingsRawRetention = "settings.rawRetention"
    public static let settingsDeleteLegacyDatabase = "settings.deleteLegacyDatabase"
}

/// Spoken accessibility text for controls whose labels explain dynamic state.
public enum AccessibilityLabels {
    public static func openHistoryFromApp(name: String) -> String {
        "Open History from \(name)"
    }

    public static func batteryPowerHint(available: Bool, isCharging: Bool, isACPlugged: Bool) -> String {
        guard available else { return "Power draw" }
        if isCharging { return "Power flowing into the battery (V × I); excludes system power" }
        if isACPlugged { return "Battery current magnitude while connected to AC; not total adapter power" }
        return "Battery discharge rate (V × I)"
    }
}
