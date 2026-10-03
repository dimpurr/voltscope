import XCTest
@testable import VoltscopeCore

final class HistoryTests: XCTestCase {
    private func battery(_ seconds: Double, current: Int? = -1000, voltage: Int? = 10000, ac: Bool = false, charging: Bool = false) -> BatterySnapshot {
        BatterySnapshot(timestamp: Int64(seconds * 1000), levelPercent: 50, capacityMAh: nil, designMAh: nil,
                        cycleCount: nil, voltageMV: voltage, amperageMA: current, temperatureC: nil,
                        timeRemainingMin: nil, isCharging: charging, isACPlugged: ac)
    }
    private func interval(_ start: Double, _ end: Double) -> DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    func testDischargeTrapezoidAndClippedBounds() {
        let snapshots = [battery(0), battery(30, current: -2000)]
        XCTAssertEqual(HistoryMath.drainJ(snapshots, within: interval(0, 30)), 450, accuracy: 0.001)
        XCTAssertEqual(HistoryMath.drainJ(snapshots, within: interval(10, 20)), 150, accuracy: 0.001)
    }

    func testChargingTransitionsMissingValuesAndGapsExcluded() {
        for snapshots in [
            [battery(0, current: 1000, ac: true, charging: true), battery(30, current: 1000, ac: true, charging: true)],
            [battery(0), battery(30, current: 1000, ac: true, charging: true)],
            [battery(0, ac: true), battery(30)], [battery(0), battery(91)],
            [battery(0, current: nil), battery(30)], [battery(0), battery(30, voltage: nil)],
            [battery(0), battery(30, current: 1000)], [battery(0), battery(0)]
        ] { XCTAssertEqual(HistoryMath.drainJ(snapshots, within: interval(0, 100)), 0) }
    }

    func testObservedDischargeDoesNotBridgeSleep() {
        let snapshots = [battery(0), battery(30), battery(4000), battery(4030)]
        XCTAssertEqual(HistoryMath.drainJ(snapshots, within: interval(0, 5000)), 600, accuracy: 0.001)
    }

    func testStackTotalsSurviveGroupingAndAppHighlight() {
        let points = (0..<15).map { index in
            HistoryEnergyPoint(appID: "app.\(index)", name: "App \(index)", bundleIdentifier: "app.\(index)",
                               path: nil, isSystem: false, date: Date(timeIntervalSince1970: 0),
                               energyNJ: Int64(index + 1) * 1_000_000_000)
        }
        let base = HistoryChartModel(points: points, groupSystem: true)
        let highlight = HistoryChartModel(points: points, groupSystem: true, selectedApp: "app.0")
        XCTAssertEqual(base.series.count, 5)
        XCTAssertTrue(base.series.contains { $0.id == HistoryChartModel.otherID })
        XCTAssertEqual(base.bucketTotals.values.reduce(0, +), 120, accuracy: 0.001)
        XCTAssertEqual(base.upper, highlight.upper)
        XCTAssertEqual(base.bucketTotals, highlight.bucketTotals)
        XCTAssertEqual(base.segments.first?.bottom, 0)
        XCTAssertEqual(base.segments.last?.top, 120)
        for (a, b) in zip(base.segments, base.segments.dropFirst()) { XCTAssertEqual(a.top, b.bottom) }
    }

    func testOlderMethodBucketsAreMarkedWithoutChangingCurrentTotals() {
        let date = Date(timeIntervalSince1970: 60)
        let point = HistoryEnergyPoint(appID: "current", name: "Current", bundleIdentifier: "current",
                                       path: nil, isSystem: false, date: date, energyNJ: 25_000_000_000)
        let model = HistoryChartModel(points: [point], groupSystem: true, legacyBuckets: [date])
        XCTAssertEqual(model.bucketTotals[date], 25)
        XCTAssertTrue(model.bucketItems[date]?.contains("Older recording method") == true)
        XCTAssertTrue(model.legacyBuckets.contains(date))
    }
}
