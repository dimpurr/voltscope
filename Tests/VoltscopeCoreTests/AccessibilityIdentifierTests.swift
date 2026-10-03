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
            AccessibilityIdentifiers.menuOpenAppInHistory,
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
            "menu.openAppInHistory",
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
}
