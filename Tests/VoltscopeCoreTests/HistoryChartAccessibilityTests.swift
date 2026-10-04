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

    func testFormatDuration() {
        XCTAssertEqual(HistoryChartAccessibility.formatDuration(45), "45 s")
        XCTAssertEqual(HistoryChartAccessibility.formatDuration(120), "2 min")
        XCTAssertEqual(HistoryChartAccessibility.formatDuration(3600), "1 hr")
        XCTAssertEqual(HistoryChartAccessibility.formatDuration(3660), "1 hr 1 min")
        XCTAssertEqual(HistoryChartAccessibility.formatDuration(7320), "2 hr 2 min")
    }
}
