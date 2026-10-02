import XCTest
import GRDB
@testable import VoltscopeCore

final class HistoryDatabaseTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    /// File-backed store whose directory is removed at the end of the test.
    private func makeTemporaryDatabase() throws -> HistoryDatabase {
        let db = try HistoryDatabase.makeTemporaryFile()
        if let fileURL = db.fileURL {
            temporaryDirectories.append(fileURL.deletingLastPathComponent())
        }
        return db
    }

    // MARK: - Schema

    func testFreshFileEnablesIncrementalAutoVacuum() async throws {
        let db = try makeTemporaryDatabase()
        let mode = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "PRAGMA auto_vacuum")
        }
        XCTAssertEqual(mode, 2, "a fresh history file must use incremental auto-vacuum")
    }

    func testMigrationCreatesEveryTieredTable() async throws {
        let db = try makeTemporaryDatabase()
        let names = try await db.dbPool.read { conn in
            try String.fetchAll(conn, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        let expected: Set<String> = [
            "App", "AppSampleRaw", "AppUsageMinute", "AppUsageHour",
            "Bucket", "BucketSampleRaw", "BucketMinute", "BucketHour",
            "Coverage", "CoverageHour", "BatteryStatus", "PowerEvents", "Meta"
        ]
        XCTAssertTrue(expected.isSubset(of: Set(names)), "missing tables: \(expected.subtracting(names))")
    }

    func testRawTablesAreIndexedOnTimestamp() async throws {
        let db = try makeTemporaryDatabase()
        let indexes = try await db.dbPool.read { conn in
            try String.fetchAll(conn, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        XCTAssertTrue(indexes.contains("AppSampleRaw_ts"))
        XCTAssertTrue(indexes.contains("BucketSampleRaw_ts"))
    }

    func testRollupTablesAreWithoutRowID() async throws {
        let db = try makeTemporaryDatabase()
        let names = ["AppUsageMinute", "AppUsageHour", "BucketMinute", "BucketHour"]
        for name in names {
            let sql = try await db.dbPool.read { conn in
                try String.fetchOne(
                    conn,
                    sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                    arguments: [name]
                )
            }
            XCTAssertTrue(
                sql?.contains("WITHOUT ROWID") == true,
                "\(name) should be WITHOUT ROWID, got: \(sql ?? "nil")"
            )
        }
    }

    func testRollupPrimaryKeysAreWholeTuples() async throws {
        let db = try makeTemporaryDatabase()
        let expected: [String: [String]] = [
            "AppUsageMinute": ["minute", "appId", "metricVersion"],
            "AppUsageHour": ["hour", "appId", "metricVersion"],
            "BucketMinute": ["minute", "bucketId", "metricVersion"],
            "BucketHour": ["hour", "bucketId", "metricVersion"]
        ]
        for (table, columns) in expected {
            let rows: [Row] = try await db.dbPool.read { conn in
                try Row.fetchAll(conn, sql: "PRAGMA table_info(\(table))")
            }
            let keyColumns = rows
                .filter { (row: Row) in (row["pk"] as Int? ?? 0) > 0 }
                .sorted { (lhs: Row, rhs: Row) in (lhs["pk"] as Int? ?? 0) < (rhs["pk"] as Int? ?? 0) }
                .compactMap { (row: Row) in row["name"] as String? }
            XCTAssertEqual(keyColumns, columns, "unexpected primary key for \(table)")
        }
    }

    func testLegacyTablesMatchLegacyFileColumns() async throws {
        let db = try makeTemporaryDatabase()
        let batteryColumns = try await db.dbPool.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA table_info(BatteryStatus)").map { $0["name"] as String? }
        }
        XCTAssertEqual(
            batteryColumns.compactMap { $0 },
            ["timestamp", "levelPercent", "capacityMAh", "designMAh", "cycleCount",
             "voltageMV", "amperageMA", "temperatureC", "timeRemainingMin",
             "isCharging", "isACPlugged"]
        )
        let eventColumns = try await db.dbPool.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA table_info(PowerEvents)").map { $0["name"] as String? }
        }
        XCTAssertEqual(
            eventColumns.compactMap { $0 },
            ["timestamp", "eventType", "durationSeconds", "metadata"]
        )
    }

    func testMigrationIsIdempotentWhenReopened() async throws {
        let db = try makeTemporaryDatabase()
        let url = try XCTUnwrap(db.fileURL)
        // A second store over the same file must not re-run the migration.
        let reopened = try HistoryDatabase(dbPool: DatabasePool(path: url.path))
        let names = try await reopened.dbPool.read { conn in
            try String.fetchAll(conn, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        XCTAssertTrue(names.contains("AppUsageHour"))
    }

    // MARK: - Dictionary upserts

    func testAppUpsertKeepsIDAndFirstSeen() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let first = try await db.upsertApp(
            groupKey: "com.example.app",
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            path: "/Applications/Example.app",
            ts: 1_000
        )
        let second = try await db.upsertApp(
            groupKey: "com.example.app",
            bundleIdentifier: "com.example.app",
            displayName: "Example Renamed",
            path: "/Applications/Example.app",
            ts: 2_000
        )
        XCTAssertEqual(first, second, "the same groupKey must resolve to the same row")

        let count = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM App") ?? 0
        }
        XCTAssertEqual(count, 1)

        let row = try await db.dbPool.read { conn in
            try AppRecord.fetchOne(conn, key: second)
        }
        XCTAssertEqual(row?.firstSeen, 1_000, "firstSeen must not be rewritten")
        XCTAssertEqual(row?.lastSeen, 2_000, "lastSeen must be refreshed")
    }

    func testAppUpsertTreatsDifferentGroupKeysAsDifferentRows() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let a = try await db.upsertApp(
            groupKey: "com.example.a", bundleIdentifier: "com.example.a",
            displayName: "A", path: nil, ts: 10
        )
        let b = try await db.upsertApp(
            groupKey: "com.example.b", bundleIdentifier: "com.example.b",
            displayName: "B", path: nil, ts: 10
        )
        XCTAssertNotEqual(a, b)
    }

    func testBucketUpsertIsStablePerName() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let first = try await db.upsertBucket(name: "cpu_p")
        let second = try await db.upsertBucket(name: "cpu_p")
        let other = try await db.upsertBucket(name: "gpu")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)

        let names = try await db.dbPool.read { conn in
            try String.fetchAll(conn, sql: "SELECT name FROM Bucket ORDER BY name")
        }
        XCTAssertEqual(names, ["cpu_p", "gpu"])
    }

    // MARK: - Rollup keys and metric versions

    func testMinuteKeyRejectsDuplicateAndAllowsOtherMetricVersion() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let appId = try await db.upsertApp(
            groupKey: "com.example.app",
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            path: nil,
            ts: 1_000
        )
        let row = AppUsageMinute(
            minute: 29_000_000,
            appId: appId,
            metricVersion: EnergyMetric.currentVersion,
            energyNJ: 42,
            cpuNs: 7,
            wakeups: 1,
            diskReadBytes: 0,
            diskWriteBytes: 0,
            samples: 1
        )
        try await db.dbPool.write { conn in try row.insert(conn) }

        do {
            try await db.dbPool.write { conn in try row.insert(conn) }
            XCTFail("a duplicate (minute, appId, metricVersion) must violate the primary key")
        } catch {
            // Expected: PRIMARY KEY constraint failed.
        }

        let legacyRow = AppUsageMinute(
            minute: row.minute,
            appId: appId,
            metricVersion: EnergyMetric.legacyVersion,
            energyNJ: 99,
            cpuNs: 0,
            wakeups: 0,
            diskReadBytes: 0,
            diskWriteBytes: 0,
            samples: 1
        )
        try await db.dbPool.write { conn in try legacyRow.insert(conn) }

        let count = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppUsageMinute") ?? 0
        }
        XCTAssertEqual(count, 2, "different metric versions coexist for the same key")
    }

    func testSampleRawForeignKeyRequiresKnownApp() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let orphan = AppSampleRaw(
            ts: 1_000,
            appId: 9_999,
            pid: 1,
            parentPid: nil,
            metricVersion: EnergyMetric.currentVersion,
            energyNJ: 1,
            cpuNs: 1,
            wakeups: 0,
            diskReadBytes: 0,
            diskWriteBytes: 0
        )
        do {
            try await db.dbPool.write { conn in try orphan.insert(conn) }
            XCTFail("AppSampleRaw.appId must reference an existing App row")
        } catch {
            // Expected: FOREIGN KEY constraint failed.
        }
    }
}
