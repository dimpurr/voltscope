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
}
