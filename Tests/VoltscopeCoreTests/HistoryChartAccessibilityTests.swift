import XCTest
@testable import VoltscopeCore

final class HistoryChartAccessibilityTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testSummaryCallsOutMissingIntervalsWithoutInterpolation() {
        let summary = HistoryChartAccessibility.summary(
            title: "App CPU energy", range: date(0)...date(120),
            points: [.init(date: date(0), value: 2), .init(date: date(60), value: 4), .init(date: date(120), value: 3)],
            unit: "joules", bucketSeconds: 30
        )
        XCTAssertTrue(summary.contains("minimum 2.00 joules"))
        XCTAssertTrue(summary.contains("maximum 4.00 joules"))
        XCTAssertTrue(summary.contains("current 3.00 joules"))
        XCTAssertTrue(summary.contains("Gaps are no data; values are not interpolated."))
    }


    func testMissingBatteryObservationIsSpokenEvenWhenSurroundingSamplesAreNear() {
        let summary = HistoryChartAccessibility.summary(
            title: "Battery level", range: date(0)...date(60),
            points: [.init(date: date(0), value: 50), .init(date: date(60), value: 49)],
            unit: "percent", hasMissingIntervals: true
        )
        XCTAssertTrue(summary.contains("Gaps are no data; values are not interpolated."))
    }

    func testSinglePointSummaryUsesSameCurrentMinimumAndMaximum() {
        let summary = HistoryChartAccessibility.summary(
            title: "Battery level", range: date(0)...date(60),
            points: [.init(date: date(30), value: 50)], unit: "percent", bucketSeconds: 90
        )
        XCTAssertTrue(summary.contains("minimum 50.00 percent"))
        XCTAssertTrue(summary.contains("maximum 50.00 percent"))
        XCTAssertTrue(summary.contains("current 50.00 percent"))
        XCTAssertFalse(summary.contains("interpolated"))
    }

    func testEmptySummaryExplicitlySaysNoData() {
        let summary = HistoryChartAccessibility.summary(title: "Battery level", range: date(0)...date(60),
                                                        points: [], unit: "percent")
        XCTAssertTrue(summary.contains("No data"))
        XCTAssertFalse(summary.contains("current"))
    }

    func testMixedMetricVersionsAreAnnouncedAsSeparate() {
        let summary = HistoryChartAccessibility.summary(
            title: "App CPU energy", range: date(0)...date(60),
            points: [.init(date: date(30), value: 12)], unit: "joules", mixedMetricVersions: true,
            scopeNote: "Recorded per-app CPU energy only; not whole-device battery drain."
        )
        XCTAssertTrue(summary.contains("Older metric-version data is marked separately and is not combined with current data."))
        XCTAssertTrue(summary.contains("not whole-device battery drain"))
    }

    func testBatterySummaryExcludesFlatPredecessorOutsideSelectedRange() {
        let range = date(90)...date(210)
        let predecessor = date(0)
        let summary = HistoryChartAccessibility.summary(
            title: "Battery level", range: range,
            points: [.init(date: predecessor, value: 50),
                     .init(date: date(90), value: 50),
                     .init(date: date(210), value: 50)],
            unit: "percent", bucketSeconds: 30
        )

        XCTAssertFalse(summary.contains(predecessor.formatted(date: .abbreviated, time: .shortened)))
        XCTAssertTrue(summary.contains(date(90).formatted(date: .abbreviated, time: .shortened)))
        XCTAssertTrue(summary.contains(date(210).formatted(date: .abbreviated, time: .shortened)))
    }

    func testBatterySummaryIncludesChargingAndSleepIntervals() {
        let charging = [
            DateInterval(start: date(10), end: date(70)),
            DateInterval(start: date(100), end: date(160))
        ]
        let sleep = [
            DateInterval(start: date(200), end: date(290))
        ]
        let summary = HistoryChartAccessibility.summary(
            title: "Battery level", range: date(0)...date(300),
            points: [.init(date: date(0), value: 50), .init(date: date(300), value: 60)],
            unit: "percent",
            chargingIntervals: charging,
            sleepIntervals: sleep
        )

        XCTAssertTrue(summary.contains("Charging: 2 intervals, total 2 min"))
        XCTAssertTrue(summary.contains("Sleep: 1 period, total 1 min"))
    }

    func testSummaryClipsChargingAndSleepIntervalsToRange() {
        let charging = [
            DateInterval(start: date(-100), end: date(50)),
            DateInterval(start: date(250), end: date(400))
        ]
        let sleep = [
            DateInterval(start: date(-50), end: date(-10)),
            DateInterval(start: date(100), end: date(220))
        ]
        let summary = HistoryChartAccessibility.summary(
            title: "Battery level", range: date(0)...date(300),
            points: [.init(date: date(0), value: 50), .init(date: date(300), value: 60)],
            unit: "percent",
            chargingIntervals: charging,
            sleepIntervals: sleep
        )

        XCTAssertTrue(summary.contains("Charging: 2 intervals, total 1 min"))
        XCTAssertTrue(summary.contains("Sleep: 1 period, total 2 min"))
    }

    func testSummaryClipsIntervalsWhenNoBatteryPoints() {
        let charging = [DateInterval(start: date(-100), end: date(60))]
        let sleep = [DateInterval(start: date(120), end: date(500))]
        let summary = HistoryChartAccessibility.summary(
            title: "Battery level", range: date(0)...date(300),
            points: [], unit: "percent",
            chargingIntervals: charging,
            sleepIntervals: sleep
        )

        XCTAssertTrue(summary.contains("No data"))
        XCTAssertTrue(summary.contains("Charging: 1 interval, total 1 min"))
        XCTAssertTrue(summary.contains("Sleep: 1 period, total 3 min"))
    }

    func testBatteryPointsContainOnlyRealReadingsInsideDomain() {
        let snapshots = [
            BatterySnapshot(timestamp: 0, levelPercent: 50, capacityMAh: nil, designMAh: nil, cycleCount: nil,
                           voltageMV: nil, amperageMA: nil, temperatureC: nil, timeRemainingMin: nil,
                           isCharging: true, isACPlugged: true),
            BatterySnapshot(timestamp: 30_000, levelPercent: nil, capacityMAh: nil, designMAh: nil, cycleCount: nil,
                           voltageMV: nil, amperageMA: nil, temperatureC: nil, timeRemainingMin: nil,
                           isCharging: false, isACPlugged: false),
            BatterySnapshot(timestamp: 60_000, levelPercent: 140, capacityMAh: nil, designMAh: nil, cycleCount: nil,
                           voltageMV: nil, amperageMA: nil, temperatureC: nil, timeRemainingMin: nil,
                           isCharging: false, isACPlugged: false),
            BatterySnapshot(timestamp: 600_000, levelPercent: 80, capacityMAh: nil, designMAh: nil, cycleCount: nil,
                           voltageMV: nil, amperageMA: nil, temperatureC: nil, timeRemainingMin: nil,
                           isCharging: false, isACPlugged: false)
        ]

        let points = HistoryChartAccessibility.batteryPoints(snapshots: snapshots, domain: date(0)...date(300))

        XCTAssertEqual(points, [
            .init(date: date(0), value: 50),
            .init(date: date(60), value: 100)
        ])
    }

    func testClipIntervalsDropsEmptyAndClampsPartialOverlaps() {
        let range = date(100)...date(200)
        let clipped = HistoryChartAccessibility.clipIntervals([
            DateInterval(start: date(0), end: date(50)),
            DateInterval(start: date(50), end: date(100)),
            DateInterval(start: date(150), end: date(160)),
            DateInterval(start: date(180), end: date(260)),
            DateInterval(start: date(300), end: date(400))
        ], to: range)

        XCTAssertEqual(clipped, [
            DateInterval(start: date(150), end: date(160)),
            DateInterval(start: date(180), end: date(200))
        ])
    }

    func testFormatDuration() {
        XCTAssertEqual(HistoryChartAccessibility.formatDuration(45), "45 s")
        XCTAssertEqual(HistoryChartAccessibility.formatDuration(120), "2 min")
        XCTAssertEqual(HistoryChartAccessibility.formatDuration(3600), "1 hr")
        XCTAssertEqual(HistoryChartAccessibility.formatDuration(3660), "1 hr 1 min")
        XCTAssertEqual(HistoryChartAccessibility.formatDuration(7320), "2 hr 2 min")
    }
}
