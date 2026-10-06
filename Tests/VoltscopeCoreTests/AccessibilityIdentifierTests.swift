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
            AccessibilityIdentifiers.historyEnergyBreakdown,
            AccessibilityIdentifiers.historyAppBreakdown,
            AccessibilityIdentifiers.historyChartBattery,
            AccessibilityIdentifiers.historyChartEnergy,
            AccessibilityIdentifiers.historyStatusCharge,
            AccessibilityIdentifiers.historyStatusHealth,
            AccessibilityIdentifiers.historyStatusTemp,
            AccessibilityIdentifiers.historyStatusTime,
            AccessibilityIdentifiers.historyStatusDrain,
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
            "history.energyBreakdown",
            "history.appBreakdown",
            "history.chartBattery",
            "history.chartEnergy",
            "history.statusCharge",
            "history.statusHealth",
            "history.statusTemp",
            "history.statusTime",
            "history.statusDrain",
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

    func testAppRowIdentifiersIncludeStableAppIdentity() {
        let chrome = AccessibilityIdentifiers.historyAppRow(appIdentity: "com.google.Chrome")
        let finder = AccessibilityIdentifiers.historyAppRow(appIdentity: "Finder")

        XCTAssertEqual(chrome, "history.appRow.com.google.Chrome")
        XCTAssertEqual(finder, "history.appRow.Finder")
        XCTAssertNotEqual(chrome, finder)
    }

    func testHardwareBucketValueFormatsJoulesAndPercentage() {
        XCTAssertEqual(
            AccessibilityLabels.hardwareBucketValue(joulesText: "245 J", percent: 100),
            "245 J, 100 percent of largest hardware channel"
        )
        XCTAssertEqual(
            AccessibilityLabels.hardwareBucketValue(joulesText: "12.3 J", percent: 45.4),
            "12.3 J, 45 percent of largest hardware channel"
        )
    }

    func testLegendSelectionValue() {
        XCTAssertEqual(AccessibilityLabels.legendSelectionValue(selected: true, anySelected: true), "Highlighted")
        XCTAssertEqual(AccessibilityLabels.legendSelectionValue(selected: false, anySelected: true), "Muted")
        XCTAssertEqual(AccessibilityLabels.legendSelectionValue(selected: false, anySelected: false), "All apps shown")
    }

    func testTimeRangeOptionIdentifiersAddressEveryRangeIndividually() {
        let identifiers = HistoryRange.allCases.map(AccessibilityIdentifiers.historyTimeRangeOption)

        XCTAssertEqual(identifiers, [
            "history.timeRange.Live",
            "history.timeRange.1H",
            "history.timeRange.6H",
            "history.timeRange.24H",
            "history.timeRange.7D"
        ])
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        // The picker wrapper keeps the group identifier, so segment identifiers
        // must not collide with it.
        XCTAssertFalse(identifiers.contains(AccessibilityIdentifiers.historyTimeRange))
    }

    func testLegendChipIdentifiersUseStableSeriesIdentity() {
        XCTAssertEqual(
            AccessibilityIdentifiers.historyLegendChip(seriesID: "com.google.Chrome"),
            "history.legend.com.google.Chrome"
        )
        XCTAssertEqual(
            AccessibilityIdentifiers.historyLegendChip(seriesID: HistoryChartModel.systemID),
            "history.legend.voltscope:group:system"
        )
        XCTAssertEqual(
            AccessibilityIdentifiers.historyLegendChip(seriesID: HistoryChartModel.otherID),
            "history.legend.voltscope:group:other"
        )
        XCTAssertNotEqual(
            AccessibilityIdentifiers.historyLegendChip(seriesID: "com.google.Chrome"),
            AccessibilityIdentifiers.historyLegendChip(seriesID: "com.google.Chrome.helper")
        )
    }

    func testMinimumTargetSizeMeetsTheDocumentedMinimum() {
        // WCAG 2.2 SC 2.5.8 asks for 24 by 24; the legend chips are padded to
        // this value so caption-sized rows still meet it.
        XCTAssertEqual(AccessibilityMetrics.minimumTargetSize, 24)
    }

    func testSystemProcessesGroupLabelDoesNotDoubleUpParentheses() {
        XCTAssertEqual(
            AccessibilityLabels.systemProcessesGroupLabel(summary: "(576 procs · 109427.9 J · 49%)"),
            "System processes: 576 procs · 109427.9 J · 49%"
        )
        XCTAssertEqual(
            AccessibilityLabels.systemProcessesGroupLabel(summary: "(12 procs · ranked by CPU time)"),
            "System processes: 12 procs · ranked by CPU time"
        )
    }

    func testUnparenthesizedLeavesPlainTextAlone() {
        XCTAssertEqual(AccessibilityLabels.unparenthesized("0 procs"), "0 procs")
        XCTAssertEqual(AccessibilityLabels.unparenthesized("("), "(")
        XCTAssertEqual(AccessibilityLabels.unparenthesized("(wrapped)"), "wrapped")
        XCTAssertEqual(AccessibilityLabels.unparenthesized("(a) (b)"), "a) (b")
    }

    func testDisplayOptionsSpokenNameAndValue() {
        XCTAssertEqual(AccessibilityLabels.displayOptionsName, "Display options")
        XCTAssertEqual(
            AccessibilityLabels.displayOptionsValue(groupSystemProcesses: true),
            "System processes grouped"
        )
        XCTAssertEqual(
            AccessibilityLabels.displayOptionsValue(groupSystemProcesses: false),
            "System processes listed individually"
        )
    }
}
