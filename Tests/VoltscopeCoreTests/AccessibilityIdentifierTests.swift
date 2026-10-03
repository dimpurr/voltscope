import XCTest
@testable import VoltscopeCore

final class AccessibilityIdentifierTests: XCTestCase {
    func testIdentifiersAreStableAndUnique() {
        let identifiers = [
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
            AccessibilityIdentifiers.settingsDeleteLegacyDatabase
        ]

        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertTrue(identifiers.allSatisfy { $0.range(of: #"^[a-z]+\.[a-zA-Z]+$"#, options: .regularExpression) != nil })
        XCTAssertEqual(identifiers, [
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
            "settings.deleteLegacyDatabase"
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
}
