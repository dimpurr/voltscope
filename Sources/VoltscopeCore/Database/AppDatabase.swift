import Foundation
import GRDB

public final class AppDatabase: @unchecked Sendable {
    /// Writer is `any DatabaseWriter` so we can use a `DatabasePool` (file-backed,
    /// supports WAL + true concurrent reads) in production and a `DatabaseQueue`
    /// (which works with `:memory:`) in tests. Both conform to `DatabaseWriter`
    /// and to the `DatabaseReader` protocol used by our read queries.
    public let dbPool: any DatabaseWriter

    public init(dbPool: any DatabaseWriter) throws {
        self.dbPool = dbPool
        try migrator.migrate(dbPool)
    }

    public static func makeDefault() throws -> AppDatabase {
        let url = try AppPaths.databaseURL()
        var config = Configuration()
        config.busyMode = .timeout(5.0)
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(dbPool: pool)
    }

    public static func makeInMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue()
        return try AppDatabase(dbPool: queue)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v0.1_initial") { db in
            try db.create(table: EnergySample.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("sampleId")
                t.column("timestamp", .integer).notNull().indexed()
                t.column("pid", .integer).notNull()
                t.column("processName", .text).notNull()
                t.column("path", .text)
                t.column("cpuUserNs", .integer).notNull().defaults(to: 0)
                t.column("cpuSystemNs", .integer).notNull().defaults(to: 0)
                t.column("energyNJ", .integer).notNull().defaults(to: 0)
                t.column("wakeups", .integer).notNull().defaults(to: 0)
                t.column("diskReadBytes", .integer).notNull().defaults(to: 0)
                t.column("diskWriteBytes", .integer).notNull().defaults(to: 0)
                t.column("year", .integer).notNull()
                t.column("month", .integer).notNull()
                t.column("day", .integer).notNull()
                t.column("hour", .integer).notNull()
                t.column("minute", .integer).notNull()
            }
            try db.create(
                index: "idx_eh_year_month_day",
                on: EnergySample.databaseTableName,
                columns: ["year", "month", "day"]
            )

            try db.create(table: BatterySnapshot.databaseTableName) { t in
                t.column("timestamp", .integer).primaryKey()
                t.column("levelPercent", .double)
                t.column("capacityMAh", .integer)
                t.column("designMAh", .integer)
                t.column("cycleCount", .integer)
                t.column("voltageMV", .integer)
                t.column("amperageMA", .integer)
                t.column("temperatureC", .double)
                t.column("timeRemainingMin", .integer)
                t.column("isCharging", .boolean).notNull().defaults(to: false)
                t.column("isACPlugged", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: PowerEvent.databaseTableName) { t in
                t.column("timestamp", .integer).primaryKey()
                t.column("eventType", .text).notNull()
                t.column("durationSeconds", .integer)
                t.column("metadata", .text)
            }
        }

        m.registerMigration("v0.2_bundle_id_and_parent_pid") { db in
            try db.alter(table: EnergySample.databaseTableName) { t in
                t.add(column: "bundleIdentifier", .text)
                t.add(column: "parentPid", .integer)
            }
            try db.create(
                index: "idx_eh_bundle_timestamp",
                on: EnergySample.databaseTableName,
                columns: ["bundleIdentifier", "timestamp"]
            )
        }

        m.registerMigration("v0.3_system_buckets") { db in
            try db.create(table: SystemBucket.databaseTableName) { t in
                t.column("timestamp", .integer).notNull().indexed()
                t.column("bucketName", .text).notNull()
                t.column("energyNJ", .integer).notNull()
            }
            try db.create(
                index: "idx_buckets_name_ts",
                on: SystemBucket.databaseTableName,
                columns: ["bucketName", "timestamp"]
            )
        }

        return m
    }
}

extension AppDatabase {
    public func writeBatchSamples(_ samples: [EnergySample]) async throws {
        try await dbPool.write { db in
            for var sample in samples {
                try sample.insert(db)
            }
        }
    }

    public func writeBatterySnapshot(_ snapshot: BatterySnapshot) async throws {
        try await dbPool.write { db in
            // Allow overwrite if same-ms timestamp (defensive; primary key collision otherwise).
            try snapshot.insert(db, onConflict: .replace)
        }
    }

    public func writePowerEvent(_ event: PowerEvent) async throws {
        try await dbPool.write { db in
            try event.insert(db, onConflict: .replace)
        }
    }

    // Legacy-only fixture writers used by migration tests.

    public func writeBatchBuckets(_ rows: [SystemBucket]) async throws {
        guard !rows.isEmpty else { return }
        try await dbPool.write { db in
            for row in rows {
                try row.insert(db)
            }
        }
    }




}
