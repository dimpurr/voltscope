import XCTest
import GRDB
@testable import VoltscopeCore

final class HistoryWriterTests: XCTestCase {
    private func epoch(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Int64 {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Int64(components.date!.timeIntervalSince1970 * 1000)
    }

    private func rows<T: FetchableRecord>(_ db: HistoryDatabase, _ type: T.Type, sql: String) throws -> [Row] {
        try db.dbPool.read { conn in try Row.fetchAll(conn, sql: sql) }
    }

    func testTickWritingRollupsAreIdempotentAcrossHourAndDayBoundaries() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let start = epoch(2025, 1, 1, 23, 58)
        for (offset, energy, version) in [(0, 10, 1), (2, 20, 1), (4, 7, 0)] {
            try await db.writeTick(
                timestamp: start + Int64(offset * 60_000),
                apps: [
                    SampledApp(groupKey: "app", bundleIdentifier: "app", displayName: "App", pid: 44,
                               energyNJ: Int64(energy), cpuNs: Int64(energy * 10), wakeups: 1),
                    SampledApp(groupKey: "filtered", displayName: "Filtered", pid: 45,
                               energyNJ: 0, cpuNs: 90)
                ],
                buckets: [SampledBucket(name: "cpu", energyNJ: Int64(energy * 2))],
                coverage: SampleCoverage(visible: 2, unreadable: 1),
                metricVersion: version
            )
        }
        // CPU-only rows are retained only when the caller marks energy unavailable.
        try await db.writeTick(
            timestamp: start + 6 * 60_000,
            apps: [SampledApp(groupKey: "cpu-only", displayName: "CPU", pid: 46, energyNJ: 0, cpuNs: 123)],
            buckets: [], coverage: SampleCoverage(visible: 1, unreadable: 0), energyUnavailable: true
        )

        let now = Date(timeIntervalSince1970: Double(start + 3 * 60 * 60_000) / 1000)
        try await db.runMaintenance(now: now)
        let firstMinutes = try rows(db, AppUsageMinute.self, sql: "SELECT * FROM AppUsageMinute ORDER BY minute, appId, metricVersion")
        let firstAppHours = try rows(db, AppUsageHour.self, sql: "SELECT * FROM AppUsageHour ORDER BY hour, appId, metricVersion")
        let firstBucketHours = try rows(db, BucketHour.self, sql: "SELECT * FROM BucketHour ORDER BY hour, bucketId, metricVersion")
        let firstCoverage = try rows(db, CoverageHour.self, sql: "SELECT * FROM CoverageHour ORDER BY hour")
        try await db.runMaintenance(now: now)
        let secondMinutes = try rows(db, AppUsageMinute.self, sql: "SELECT * FROM AppUsageMinute ORDER BY minute, appId, metricVersion")
        let secondAppHours = try rows(db, AppUsageHour.self, sql: "SELECT * FROM AppUsageHour ORDER BY hour, appId, metricVersion")
        let secondBucketHours = try rows(db, BucketHour.self, sql: "SELECT * FROM BucketHour ORDER BY hour, bucketId, metricVersion")
        let secondCoverage = try rows(db, CoverageHour.self, sql: "SELECT * FROM CoverageHour ORDER BY hour")
        XCTAssertEqual(firstMinutes, secondMinutes)
        XCTAssertEqual(firstAppHours, secondAppHours)
        XCTAssertEqual(firstBucketHours, secondBucketHours)
        XCTAssertEqual(firstCoverage, secondCoverage)

        let totals = try await db.dbPool.read { conn in
            let rawEnergy = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw") ?? 0
            let minuteEnergy = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppUsageMinute") ?? 0
            let hourEnergy = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppUsageHour") ?? 0
            let rawBucketEnergy = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM BucketSampleRaw") ?? 0
            let hourBucketEnergy = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM BucketHour") ?? 0
            let filteredApps = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM App WHERE groupKey = 'filtered'") ?? 0
            let cpuOnlyApps = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM App WHERE groupKey = 'cpu-only'") ?? 0
            let coverageTicks = try Int64.fetchOne(conn, sql: "SELECT SUM(ticks) FROM CoverageHour") ?? 0
            return (rawEnergy, minuteEnergy, hourEnergy, rawBucketEnergy, hourBucketEnergy,
                    filteredApps, cpuOnlyApps, coverageTicks)
        }
        XCTAssertEqual(totals.0, 37)
        XCTAssertEqual(totals.1, totals.0)
        XCTAssertEqual(totals.2, totals.0)
        XCTAssertEqual(totals.3, 74)
        XCTAssertEqual(totals.4, totals.3)
        XCTAssertEqual(totals.5, 0)
        XCTAssertEqual(totals.6, 1)
        XCTAssertEqual(totals.7, 4)

        let versionTotals = try await db.dbPool.read { conn in
            try Row.fetchAll(conn, sql: "SELECT metricVersion, SUM(energyNJ) AS energy FROM AppUsageHour GROUP BY metricVersion ORDER BY metricVersion")
                .map { ($0["metricVersion"] as Int, $0["energy"] as Int64) }
        }
        XCTAssertEqual(versionTotals.map(\.0), [0, 1])
        XCTAssertEqual(versionTotals.map(\.1), [7, 30])
    }

    func testMinuteOnlyRunCanBeCompletedByFullMaintenance() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let ts = epoch(2025, 2, 3, 10, 4)
        for minute in [0, 1, 2] {
            try await db.writeTick(
                timestamp: ts + Int64(minute * 60_000),
                apps: [SampledApp(groupKey: "resume", displayName: "Resume", pid: 1, energyNJ: 5, cpuNs: 8)],
                buckets: [SampledBucket(name: "gpu", energyNJ: 11)],
                coverage: SampleCoverage(visible: 1, unreadable: 0)
            )
        }
        let now = Date(timeIntervalSince1970: Double(ts + 3 * 60 * 60_000) / 1000)
        try await db.rollupMinutes(now: now)
        let afterMinuteStep = try await db.dbPool.read { conn in
            let hourCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppUsageHour") ?? 0
            let minuteWatermark = try String.fetchOne(
                conn, sql: "SELECT value FROM Meta WHERE key = 'rollup.minuteWatermark'")
            let hourWatermark = try String.fetchOne(
                conn, sql: "SELECT value FROM Meta WHERE key = 'rollup.hourWatermark'")
            return (hourCount, minuteWatermark, hourWatermark)
        }
        XCTAssertEqual(afterMinuteStep.0, 0)
        XCTAssertEqual(afterMinuteStep.1, String(Int64(now.timeIntervalSince1970 / 60) - 2))
        XCTAssertNil(afterMinuteStep.2)

        try await db.runMaintenance(now: now)
        let after = try await db.dbPool.read { conn in
            (
                try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppUsageHour") ?? 0,
                try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM BucketHour") ?? 0,
                try Int64.fetchOne(conn, sql: "SELECT SUM(ticks) FROM CoverageHour") ?? 0
            )
        }
        XCTAssertEqual(after.0, 15)
        XCTAssertEqual(after.1, 33)
        XCTAssertEqual(after.2, 3)
        let hourWatermark = try await db.dbPool.read { conn in
            try String.fetchOne(conn, sql: "SELECT value FROM Meta WHERE key = 'rollup.hourWatermark'")
        }
        XCTAssertEqual(hourWatermark, String(Int64(now.timeIntervalSince1970 / 3600) - 1))
    }

    func testConfiguredThreeDayRetentionLeavesHoursUntouched() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let old = epoch(2025, 3, 1, 12)
        let recent = old + 5 * 86_400_000
        for (ts, energy) in [(old, 4), (recent, 9)] {
            try await db.writeTick(
                timestamp: ts,
                apps: [SampledApp(groupKey: "retain", displayName: "Retain", pid: 3, energyNJ: Int64(energy), cpuNs: 1)],
                buckets: [SampledBucket(name: "cpu", energyNJ: Int64(energy))],
                coverage: SampleCoverage(visible: 1, unreadable: 0)
            )
        }
        let now = Date(timeIntervalSince1970: Double(recent + 3 * 60 * 60_000) / 1000)
        try await db.runMaintenance(now: now)
        let initialTotals = try await db.dbPool.read { conn in
            let raw = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw") ?? 0
            let hours = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppUsageHour") ?? 0
            return (raw, hours)
        }
        XCTAssertEqual(initialTotals.0, 13, "the default retention keeps both samples within seven days")
        try await db.dbPool.write { conn in
            try MetaEntry(key: "settings.rawRetentionDays", value: "3").insert(conn)
        }
        let later = now.addingTimeInterval(2 * 86_400)
        try await db.runMaintenance(now: later)

        let values = try await db.dbPool.read { conn in
            let appRaw = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw") ?? 0
            let bucketRaw = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM BucketSampleRaw") ?? 0
            let appHours = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppUsageHour") ?? 0
            let bucketHours = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM BucketHour") ?? 0
            let coverageTicks = try Int64.fetchOne(conn, sql: "SELECT SUM(ticks) FROM CoverageHour") ?? 0
            return (appRaw, bucketRaw, appHours, bucketHours, coverageTicks)
        }
        XCTAssertEqual(values.0, 9)
        XCTAssertEqual(values.1, 9)
        XCTAssertEqual(values.2, initialTotals.1)
        XCTAssertEqual(values.3, initialTotals.1)
        XCTAssertEqual(values.4, 2)
    }
}
