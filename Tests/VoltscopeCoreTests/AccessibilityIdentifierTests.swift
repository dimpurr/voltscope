import XCTest
@testable import VoltscopeCore

final class AccessibilityIdentifierTests: XCTestCase {
    func testIdentifiersAreStableAndUnique() {
        let identifiers = [
            AccessibilityIdentifiers.menuBarItem,
            AccessibilityIdentifiers.menuOpenHistory,
            AccessibilityIdentifiers.menuSettings,
            AccessibilityIdentifiers.menuCheckForUpdates,
            AccessibilityIdentifiers.menuQuit,
            AccessibilityIdentifiers.menuSystemProcesses,
            AccessibilityIdentifiers.historyTimeRange,
            AccessibilityIdentifiers.historyDisplayOptions,
            AccessibilityIdentifiers.historyGroupSystemProcesses,
            AccessibilityIdentifiers.historyExportCSV,
            AccessibilityIdentifiers.historyClearAppSelection,
            AccessibilityIdentifiers.historySystemProcesses,
            AccessibilityIdentifiers.settingsLaunchAtLogin,
            AccessibilityIdentifiers.settingsOpenLoginItems,
            AccessibilityIdentifiers.settingsRawRetention,
            AccessibilityIdentifiers.settingsDeleteLegacyDatabase,
            AccessibilityIdentifiers.welcomeNotNow,
            AccessibilityIdentifiers.welcomeDone,
            AccessibilityIdentifiers.welcomeOpenLoginItems,
            AccessibilityIdentifiers.welcomeEnableAtLogin
        ]

        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertTrue(identifiers.allSatisfy { $0.range(of: #"^[a-z]+\.[a-zA-Z]+$"#, options: .regularExpression) != nil })
        XCTAssertEqual(identifiers, [
            "menu.barItem",
            "menu.openHistory",
            "menu.settings",
            "menu.checkForUpdates",
            "menu.quit",
            "menu.systemProcesses",
            "history.timeRange",
            "history.displayOptions",
            "history.groupSystemProcesses",
            "history.exportCSV",
            "history.clearAppSelection",
            "history.systemProcesses",
            "settings.launchAtLogin",
            "settings.openLoginItems",
            "settings.rawRetention",
            "settings.deleteLegacyDatabase",
            "welcome.notNow",
            "welcome.done",
            "welcome.openLoginItems",
            "welcome.enableAtLogin"
        ])
    }

    func testAppHistoryIdentifiersIncludeStableAppIdentity() {
        let chrome = AccessibilityIdentifiers.menuOpenAppInHistory(appIdentity: "com.google.Chrome")
        let safari = AccessibilityIdentifiers.menuOpenAppInHistory(appIdentity: "com.apple.Safari")

        XCTAssertEqual(chrome, "menu.openAppInHistory.com.google.Chrome")
        XCTAssertEqual(safari, "menu.openAppInHistory.com.apple.Safari")
        XCTAssertNotEqual(chrome, safari)
    }

    func testAppHistoryLabelDescribesOpeningHistoryFromTheRow() {
        XCTAssertEqual(AccessibilityLabels.openHistoryFromApp(name: "Safari"), "Open History from Safari")
    }

    func testBatteryPowerHintsExplainEachPowerDirection() {
        XCTAssertEqual(
            AccessibilityLabels.batteryPowerHint(available: true, isCharging: true, isACPlugged: true),
            "Power flowing into the battery (V × I); excludes system power"
        )
        XCTAssertEqual(
            AccessibilityLabels.batteryPowerHint(available: true, isCharging: false, isACPlugged: true),
            "Battery current magnitude while connected to AC; not total adapter power"
        )
        XCTAssertEqual(
            AccessibilityLabels.batteryPowerHint(available: true, isCharging: false, isACPlugged: false),
            "Battery discharge rate (V × I)"
        )
        XCTAssertEqual(
            AccessibilityLabels.batteryPowerHint(available: false, isCharging: false, isACPlugged: false),
            "Power draw"
        )
    }

    func testMenuBarBatteryValueFormatting() {
        XCTAssertEqual(
            AccessibilityLabels.menuBarBatteryValue(levelPercent: nil, isCharging: false, isACPlugged: false),
            "Battery status unavailable"
        )
        XCTAssertEqual(
            AccessibilityLabels.menuBarBatteryValue(levelPercent: 85.4, isCharging: true, isACPlugged: true),
            "85 percent, charging"
        )
        XCTAssertEqual(
            AccessibilityLabels.menuBarBatteryValue(levelPercent: 100.0, isCharging: false, isACPlugged: true),
            "100 percent, on AC power"
        )
        XCTAssertEqual(
            AccessibilityLabels.menuBarBatteryValue(levelPercent: 42.1, isCharging: false, isACPlugged: false),
            "42 percent, on battery"
        )
    }

    func testMenuBarAppRowValueFormatting() {
        XCTAssertEqual(
            AccessibilityLabels.menuBarAppRowValue(energyNJ: 12_340_000_000, cpuNS: 0, energyAvailable: true),
            "12.34 J recorded CPU energy"
        )
        XCTAssertEqual(
            AccessibilityLabels.menuBarAppRowValue(energyNJ: 0, cpuNS: 1_500_000_000, energyAvailable: false),
            "1.5s CPU time"
        )
    }
}
