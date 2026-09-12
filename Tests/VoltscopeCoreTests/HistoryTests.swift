import XCTest
@testable import VoltscopeCore

final class HistoryTests: XCTestCase {
    private func sample(_ time: Int64, _ app: String, _ energy: Int64, name: String? = nil) -> EnergySample {
        EnergySample(timestamp: time, pid: 1, bundleIdentifier: app, processName: name ?? app,
                     cpuUserNs: 0, cpuSystemNs: 0, energyNJ: energy, wakeups: 0,
                     diskReadBytes: 0, diskWriteBytes: 0, year: 2026, month: 9, day: 11, hour: 0, minute: 0)
    }
    private func battery(_ seconds: Double, current: Int? = -1000, voltage: Int? = 10000, ac: Bool = false, charging: Bool = false) -> BatterySnapshot {
        BatterySnapshot(timestamp: Int64(seconds * 1000), levelPercent: 50, capacityMAh: nil, designMAh: nil,
                        cycleCount: nil, voltageMV: voltage, amperageMA: current, temperatureC: nil,
                        timeRemainingMin: nil, isCharging: charging, isACPlugged: ac)
    }
    private func interval(_ start: Double, _ end: Double) -> DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    func testAllAppsRetainedAndNamesStableAcrossBuckets() async throws {
        let db = try AppDatabase.makeInMemory()
        var samples = (0..<14).map { sample(10_000, "app.\($0)", Int64($0 + 1)) }
        samples += [sample(70_000, "app.0", 100, name: "A helper"), sample(120_000, "excluded", 9999)]
        try await db.writeBatchSamples(samples)
        let points = try await db.historyEnergy(in: interval(0, 120), bucketSeconds: 60)
        XCTAssertEqual(points.reduce(0) { $0 + $1.energyNJ }, 205)
        XCTAssertEqual(HistoryMath.apps(points).count, 14)
        XCTAssertEqual(Set(points.filter { $0.appID == "app.0" }.map(\.name)).count, 1)
        XCTAssertEqual(HistoryMath.apps(points, selection: interval(60, 120)).first?.energyNJ, 100)
        XCTAssertEqual(HistoryMath.apps(points, selection: interval(0, 60)).reduce(0) { $0 + $1.energyNJ }, 105)
        XCTAssertFalse(points.contains { $0.appID == "excluded" })
    }

    func testPartialQueryDoesNotIncludeSamplesOutsideBounds() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.writeBatchSamples([sample(5_000, "app", 100), sample(20_000, "app", 3), sample(55_000, "app", 200)])
        let points = try await db.historyEnergy(in: interval(10, 50), bucketSeconds: 60)
        XCTAssertEqual(points.first?.date, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(points.first?.energyNJ, 3)
        let invalid = try await db.historyEnergy(in: interval(10, 50), bucketSeconds: 0)
        XCTAssertTrue(invalid.isEmpty)
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
            [battery(0, ac: true), battery(30)],
            [battery(0), battery(91)],
            [battery(0, current: nil), battery(30)],
            [battery(0), battery(30, voltage: nil)],
            [battery(0), battery(30, current: 1000)],
            [battery(0), battery(0)]
        ] {
            XCTAssertEqual(HistoryMath.drainJ(snapshots, within: interval(0, 100)), 0)
        }
    }

    func testObservedDischargeDoesNotBridgeSleep() {
        let snapshots = [battery(0), battery(30), battery(4000), battery(4030)]
        XCTAssertEqual(HistoryMath.drainJ(snapshots, within: interval(0, 5000)), 600, accuracy: 0.001)
    }

    func testBatteryQueryIncludesPredecessorForClippedIntegration() async throws {
        let db = try AppDatabase.makeInMemory()
        for snapshot in [battery(0), battery(30), battery(60), battery(120)] { try await db.writeBatterySnapshot(snapshot) }
        let snapshots = try await db.batteryHistory(in: interval(10, 60))
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(HistoryMath.drainJ(snapshots, within: interval(10, 60)), 500, accuracy: 0.001)
    }
    func testStackTotalsSurviveGroupingAndAppHighlight() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.writeBatchSamples((0..<15).map { sample(10_000, "app.\($0)", Int64($0 + 1) * 1_000_000_000) })
        let points = try await db.historyEnergy(in: interval(0, 60), bucketSeconds: 60)
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

    func testToolbarRangesUseMatchingBucketWidthsAndTotals() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.writeBatchSamples([sample(30_000, "old", 10), sample(6_030_000, "recent", 20), sample(7_170_000, "now", 30)])
        for (seconds, width, expected) in [(1800.0, 30, 50), (3600.0, 120, 50), (21600.0, 600, 60), (86400.0, 1800, 60), (604800.0, 21600, 60)] {
            let points = try await db.historyEnergy(in: interval(7200 - seconds, 7200), bucketSeconds: width)
            XCTAssertEqual(points.reduce(0) { $0 + $1.energyNJ }, Int64(expected))
            for point in points { XCTAssertEqual(Int(point.date.timeIntervalSince1970) % width, 0) }
        }
    }

    func testHardwareAndExportShareExclusiveTimeBounds() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.writeBatchBuckets([SystemBucket(timestamp: 10_000, bucketName: "CPU", energyNJ: 10), SystemBucket(timestamp: 60_000, bucketName: "CPU", energyNJ: 90)])
        try await db.writeBatchSamples([sample(10_000, "app", 10), sample(60_000, "app", 90)])
        let hardware = try await db.historyHardware(in: interval(0, 60), bucketSeconds: 30)
        let exported = try await db.historySamples(in: interval(0, 60))
        XCTAssertEqual(hardware.first?.totalEnergyNJ, 10)
        XCTAssertEqual(exported.reduce(0) { $0 + $1.energyNJ }, 10)
    }

}
