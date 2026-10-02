import XCTest
import GRDB
@testable import VoltscopeCore

/// One row of `PRAGMA table_info`, normalized so the whole tiered schema can
/// be compared against the storage contract column by column.
private struct ColumnSpec: Equatable {
    let name: String
    let type: String
    let notNull: Bool
    let pk: Int
}

private func spec(_ name: String, _ type: String, notNull: Bool = false, pk: Int = 0) -> ColumnSpec {
    ColumnSpec(name: name, type: type, notNull: notNull, pk: pk)
}

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

    /// Normalized `PRAGMA table_info` for one table, in declared column order.
    private func tableInfo(_ db: HistoryDatabase, _ table: String) async throws -> [ColumnSpec] {
        try await db.dbPool.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA table_info(\(table))").map { row in
                ColumnSpec(
                    name: row["name"] as String,
                    type: row["type"] as String,
                    notNull: (row["notnull"] as Int? ?? 0) != 0,
                    pk: row["pk"] as Int? ?? 0
                )
            }
        }
    }

    // MARK: - Schema

    func testFreshFileEnablesIncrementalAutoVacuum() async throws {
        let db = try makeTemporaryDatabase()
        let mode = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "PRAGMA auto_vacuum")
        }
        XCTAssertEqual(mode, 2, "a fresh history file must use incremental auto-vacuum")
    }

    func testAutoVacuumSurvivesReopenWithoutPreparation() async throws {
        var db: HistoryDatabase? = try makeTemporaryDatabase()
        let url = try XCTUnwrap(db?.fileURL)
        let modeBefore = try await db!.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "PRAGMA auto_vacuum")
        }
        XCTAssertEqual(modeBefore, 2)

        // Drop the creating pool so its connections close, then reopen the
        // raw file with default settings (no auto-vacuum pragma anywhere). The
        // mode must come from the persisted file header.
        db = nil
        let reopened = try DatabasePool(path: url.path)
        let modeAfter = try await reopened.read { conn in
            try Int.fetchOne(conn, sql: "PRAGMA auto_vacuum")
        }
        XCTAssertEqual(modeAfter, 2, "auto-vacuum must persist across reopen")
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

    func testRawIndexesPointAtTimestampColumn() async throws {
        let db = try makeTemporaryDatabase()
        let expected = ["AppSampleRaw_ts": "ts", "BucketSampleRaw_ts": "ts"]
        for (index, column) in expected {
            let columns = try await db.dbPool.read { conn in
                try Row.fetchAll(conn, sql: "PRAGMA index_info(\(index))")
                    .compactMap { $0["name"] as String? }
            }
            XCTAssertEqual(columns, [column], "\(index) must index the \(column) column")
        }
    }

    func testRawTablesReferenceTheirDictionaries() async throws {
        let db = try makeTemporaryDatabase()
        struct ForeignKey: Equatable {
            let table: String
            let from: String
            let to: String
        }
        let expected: [String: [ForeignKey]] = [
            "AppSampleRaw": [ForeignKey(table: "App", from: "appId", to: "id")],
            "BucketSampleRaw": [ForeignKey(table: "Bucket", from: "bucketId", to: "id")]
        ]
        for (table, keys) in expected {
            let rows: [ForeignKey] = try await db.dbPool.read { conn in
                try Row.fetchAll(conn, sql: "PRAGMA foreign_key_list(\(table))").map { row in
                    ForeignKey(
                        table: row["table"] as String,
                        from: row["from"] as String,
                        to: row["to"] as String
                    )
                }
            }
            XCTAssertEqual(rows, keys, "unexpected foreign keys for \(table)")
        }
    }

    func testTieredSchemaMatchesContractColumnByColumn() async throws {
        let db = try makeTemporaryDatabase()
        let expected: [String: [ColumnSpec]] = [
            "App": [
                spec("id", "INTEGER", pk: 1),
                spec("groupKey", "TEXT", notNull: true),
                spec("bundleIdentifier", "TEXT"),
                spec("displayName", "TEXT", notNull: true),
                spec("path", "TEXT"),
                spec("firstSeen", "INTEGER", notNull: true),
                spec("lastSeen", "INTEGER", notNull: true)
            ],
            "AppSampleRaw": [
                spec("ts", "INTEGER", notNull: true),
                spec("appId", "INTEGER", notNull: true),
                spec("pid", "INTEGER", notNull: true),
                spec("parentPid", "INTEGER"),
                spec("metricVersion", "INTEGER", notNull: true),
                spec("energyNJ", "INTEGER", notNull: true),
                spec("cpuNs", "INTEGER", notNull: true),
                spec("wakeups", "INTEGER", notNull: true),
                spec("diskReadBytes", "INTEGER", notNull: true),
                spec("diskWriteBytes", "INTEGER", notNull: true)
            ],
            "AppUsageMinute": [
                spec("minute", "INTEGER", notNull: true, pk: 1),
                spec("appId", "INTEGER", notNull: true, pk: 2),
                spec("metricVersion", "INTEGER", notNull: true, pk: 3),
                spec("energyNJ", "INTEGER", notNull: true),
                spec("cpuNs", "INTEGER", notNull: true),
                spec("wakeups", "INTEGER", notNull: true),
                spec("diskReadBytes", "INTEGER", notNull: true),
                spec("diskWriteBytes", "INTEGER", notNull: true),
                spec("samples", "INTEGER", notNull: true)
            ],
            "AppUsageHour": [
                spec("hour", "INTEGER", notNull: true, pk: 1),
                spec("appId", "INTEGER", notNull: true, pk: 2),
                spec("metricVersion", "INTEGER", notNull: true, pk: 3),
                spec("energyNJ", "INTEGER", notNull: true),
                spec("cpuNs", "INTEGER", notNull: true),
                spec("wakeups", "INTEGER", notNull: true),
                spec("diskReadBytes", "INTEGER", notNull: true),
                spec("diskWriteBytes", "INTEGER", notNull: true),
                spec("samples", "INTEGER", notNull: true)
            ],
            "Bucket": [
                spec("id", "INTEGER", pk: 1),
                spec("name", "TEXT", notNull: true)
            ],
            "BucketSampleRaw": [
                spec("ts", "INTEGER", notNull: true),
                spec("bucketId", "INTEGER", notNull: true),
                spec("metricVersion", "INTEGER", notNull: true),
                spec("energyNJ", "INTEGER", notNull: true)
            ],
            "BucketMinute": [
                spec("minute", "INTEGER", notNull: true, pk: 1),
                spec("bucketId", "INTEGER", notNull: true, pk: 2),
                spec("metricVersion", "INTEGER", notNull: true, pk: 3),
                spec("energyNJ", "INTEGER", notNull: true)
            ],
            "BucketHour": [
                spec("hour", "INTEGER", notNull: true, pk: 1),
                spec("bucketId", "INTEGER", notNull: true, pk: 2),
                spec("metricVersion", "INTEGER", notNull: true, pk: 3),
                spec("energyNJ", "INTEGER", notNull: true)
            ],
            "Coverage": [
                spec("ts", "INTEGER", pk: 1),
                spec("visible", "INTEGER", notNull: true),
                spec("unreadable", "INTEGER", notNull: true)
            ],
            "CoverageHour": [
                spec("hour", "INTEGER", pk: 1),
                spec("ticks", "INTEGER", notNull: true),
                spec("visibleSum", "INTEGER", notNull: true),
                spec("unreadableSum", "INTEGER", notNull: true)
            ],
            "Meta": [
                spec("key", "TEXT", pk: 1),
                spec("value", "TEXT", notNull: true)
            ]
        ]
        for (table, columns) in expected {
            let actual = try await tableInfo(db, table)
            XCTAssertEqual(actual, columns, "schema drift in \(table)")
        }
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
        let battery: [ColumnSpec] = [
            spec("timestamp", "INTEGER", pk: 1),
            spec("levelPercent", "DOUBLE"),
            spec("capacityMAh", "INTEGER"),
            spec("designMAh", "INTEGER"),
            spec("cycleCount", "INTEGER"),
            spec("voltageMV", "INTEGER"),
            spec("amperageMA", "INTEGER"),
            spec("temperatureC", "DOUBLE"),
            spec("timeRemainingMin", "INTEGER"),
            spec("isCharging", "BOOLEAN", notNull: true),
            spec("isACPlugged", "BOOLEAN", notNull: true)
        ]
        let actualBattery = try await tableInfo(db, "BatteryStatus")
        XCTAssertEqual(actualBattery, battery)

        let events: [ColumnSpec] = [
            spec("timestamp", "INTEGER", pk: 1),
            spec("eventType", "TEXT", notNull: true),
            spec("durationSeconds", "INTEGER"),
            spec("metadata", "TEXT")
        ]
        let actualEvents = try await tableInfo(db, "PowerEvents")
        XCTAssertEqual(actualEvents, events)
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

    func testAppUpsertWidensSeenIntervalWhenTimestampsArriveOutOfOrder() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let first = try await db.upsertApp(
            groupKey: "com.example.app",
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            path: nil,
            ts: 5_000
        )
        let second = try await db.upsertApp(
            groupKey: "com.example.app",
            bundleIdentifier: "com.example.app",
            displayName: "Example",
            path: nil,
            ts: 1_000
        )
        XCTAssertEqual(first, second, "the same groupKey must resolve to the same row")

        let row = try await db.dbPool.read { conn in
            try AppRecord.fetchOne(conn, key: second)
        }
        XCTAssertEqual(row?.firstSeen, 1_000, "an earlier timestamp must lower firstSeen")
        XCTAssertEqual(row?.lastSeen, 5_000, "an earlier timestamp must not lower lastSeen")
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
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_PRIMARYKEY {
            // Expected: the composite primary key rejects the duplicate.
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
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
            // Expected: the appId reference rejects the orphan row.
        }
    }
}
