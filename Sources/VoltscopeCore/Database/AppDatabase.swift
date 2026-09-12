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

    // MARK: - Read queries used by the UI layer

    public func latestBatterySnapshot() async throws -> BatterySnapshot? {
        try await dbPool.read { db in
            try BatterySnapshot
                .order(Column("timestamp").desc)
                .limit(1)
                .fetchOne(db)
        }
    }

    public struct TopAppEnergy: Sendable, Equatable, Identifiable {
        public let bundleIdentifier: String?
        public let processName: String
        public let path: String?
        public let totalEnergyNJ: Int64
        /// Identity used for SwiftUI `Identifiable`. Prefers bundle ID so helper
        /// processes that share a bundle ID collapse into one row.
        public var id: String { bundleIdentifier ?? processName }

        public init(bundleIdentifier: String?, processName: String, path: String?, totalEnergyNJ: Int64) {
            self.bundleIdentifier = bundleIdentifier
            self.processName = processName
            self.path = path
            self.totalEnergyNJ = totalEnergyNJ
        }
    }

    /// Returns the top energy consumers in the time window, grouped by `bundleIdentifier`
    /// when one is present (so Chrome + 5 Chrome Helpers collapse to one row), otherwise
    /// by `processName` (for daemons / CLIs without a bundle).
    public func topApps(sinceMinutes minutes: Int, limit: Int = 5) async throws -> [TopAppEnergy] {
        let since = Int64(Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    COALESCE(bundleIdentifier, processName) AS groupKey,
                    bundleIdentifier,
                    MAX(processName) AS processName,
                    MAX(path) AS path,
                    SUM(energyNJ) AS total
                FROM EnergyHistory
                WHERE timestamp >= ?
                GROUP BY groupKey
                ORDER BY total DESC
                LIMIT ?
                """, arguments: [since, limit])
            return rows.compactMap { row in
                guard let name: String = row["processName"], let total: Int64 = row["total"] else { return nil }
                return TopAppEnergy(
                    bundleIdentifier: row["bundleIdentifier"],
                    processName: name,
                    path: row["path"],
                    totalEnergyNJ: total
                )
            }
        }
    }

    public struct EnergyChartPoint: Sendable, Equatable {
        public let displayName: String
        public let bundleIdentifier: String?
        public let bucketStart: Date
        public let totalEnergyNJ: Int64
        public init(displayName: String, bundleIdentifier: String?, bucketStart: Date, totalEnergyNJ: Int64) {
            self.displayName = displayName
            self.bundleIdentifier = bundleIdentifier
            self.bucketStart = bucketStart
            self.totalEnergyNJ = totalEnergyNJ
        }
    }

    /// Returns per-bundle per-hour buckets across the requested window, restricted to the top N
    /// groups by total energy. Falls back to processName grouping for bundle-less daemons.
    public func energyChartPoints(sinceMinutes minutes: Int, topN: Int = 8) async throws -> [EnergyChartPoint] {
        let since = Int64(Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in
            let topRows = try Row.fetchAll(db, sql: """
                SELECT
                    COALESCE(bundleIdentifier, processName) AS groupKey,
                    MAX(processName) AS displayName,
                    SUM(energyNJ) AS total
                FROM EnergyHistory
                WHERE timestamp >= ?
                GROUP BY groupKey
                ORDER BY total DESC
                LIMIT ?
                """, arguments: [since, topN])
            let topKeys: [String] = topRows.compactMap { $0["groupKey"] as String? }
            guard !topKeys.isEmpty else { return [] }

            let placeholders = topKeys.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT
                    COALESCE(bundleIdentifier, processName) AS groupKey,
                    bundleIdentifier,
                    MAX(processName) AS displayName,
                    year, month, day, hour,
                    SUM(energyNJ) AS total
                FROM EnergyHistory
                WHERE timestamp >= ?
                  AND COALESCE(bundleIdentifier, processName) IN (\(placeholders))
                GROUP BY groupKey, year, month, day, hour
                ORDER BY year, month, day, hour
                """
            var args: [DatabaseValueConvertible] = [since]
            args.append(contentsOf: topKeys)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            var output: [EnergyChartPoint] = []
            output.reserveCapacity(rows.count)
            for row in rows {
                guard
                    let display: String = row["displayName"],
                    let year: Int = row["year"],
                    let month: Int = row["month"],
                    let day: Int = row["day"],
                    let hour: Int = row["hour"],
                    let total: Int64 = row["total"]
                else { continue }
                var comps = DateComponents()
                comps.year = year; comps.month = month; comps.day = day; comps.hour = hour
                guard let date = calendar.date(from: comps) else { continue }
                output.append(EnergyChartPoint(
                    displayName: display,
                    bundleIdentifier: row["bundleIdentifier"],
                    bucketStart: date,
                    totalEnergyNJ: total
                ))
            }
            return output
        }
    }

    // MARK: - CSV export

    /// Returns every EnergyHistory row in the time window in chronological order.
    /// Caller is responsible for streaming behavior — for v0.5 the export window is
    /// bounded by the UI's range selector (max 7 days, ~2M rows), which fits comfortably
    /// in memory. If 30-day exports become a use case we'll switch to a true streaming
    /// API; the current shape avoids the Sendable closure dance with GRDB's reader.
    public func fetchAllSamples(sinceMinutes minutes: Int) async throws -> [EnergySample] {
        let since = Int64(Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in
            try EnergySample
                .filter(Column("timestamp") >= since)
                .order(Column("timestamp"))
                .fetchAll(db)
        }
    }

    public func batteryHistory(sinceMinutes minutes: Int) async throws -> [BatterySnapshot] {
        let since = Int64(Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in
            try BatterySnapshot
                .filter(Column("timestamp") >= since)
                .order(Column("timestamp"))
                .fetchAll(db)
        }
    }

    /// Truncates the WAL file back to a small size after applying outstanding
    /// pages to the main DB. Without periodic checkpointing the WAL grows
    /// monotonically while the app is running, which is the dominant cause of
    /// the v0.5 "writes GB per day" issue measured via `ri_diskio_byteswritten`.
    public func runWALCheckpoint() async throws {
        try await dbPool.write { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    // MARK: - v0.5.1 redesign queries

    /// Per-bundle per-time-bucket energy. Bucket size is parameterized so the
    /// chart can keep ~30 bars across any time range — the v0.5 implementation
    /// hardcoded an hourly bucket regardless of range, which made the 1H view
    /// render a single block when the user had less than an hour of data.
    public func bucketedEnergyChartPoints(
        sinceMinutes minutes: Int,
        bucketSeconds: Int,
        topN: Int = 8
    ) async throws -> [EnergyChartPoint] {
        let since = Int64(Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970 * 1000)
        let bucketMs = Int64(bucketSeconds) * 1000
        guard bucketMs > 0 else { return [] }
        return try await dbPool.read { db in
            // Top-N groups by total energy in the window — drives both the chart
            // colors and the legend, so we restrict the bucket query to these IDs.
            let topRows = try Row.fetchAll(db, sql: """
                SELECT
                    COALESCE(bundleIdentifier, processName) AS groupKey,
                    MAX(processName) AS displayName,
                    SUM(energyNJ) AS total
                FROM EnergyHistory
                WHERE timestamp >= ?
                GROUP BY groupKey
                ORDER BY total DESC
                LIMIT ?
                """, arguments: [since, topN])
            let topKeys: [String] = topRows.compactMap { $0["groupKey"] as String? }
            guard !topKeys.isEmpty else { return [] }

            let placeholders = topKeys.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT
                    COALESCE(bundleIdentifier, processName) AS groupKey,
                    bundleIdentifier,
                    MAX(processName) AS displayName,
                    (timestamp / ?) * ? AS bucketStartMs,
                    SUM(energyNJ) AS total
                FROM EnergyHistory
                WHERE timestamp >= ?
                  AND COALESCE(bundleIdentifier, processName) IN (\(placeholders))
                GROUP BY groupKey, bucketStartMs
                ORDER BY bucketStartMs
                """
            var args: [DatabaseValueConvertible] = [bucketMs, bucketMs, since]
            args.append(contentsOf: topKeys)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row in
                guard
                    let display: String = row["displayName"],
                    let bucketStartMs: Int64 = row["bucketStartMs"],
                    let total: Int64 = row["total"]
                else { return nil }
                return EnergyChartPoint(
                    displayName: display,
                    bundleIdentifier: row["bundleIdentifier"],
                    bucketStart: Date(timeIntervalSince1970: TimeInterval(bucketStartMs) / 1000.0),
                    totalEnergyNJ: total
                )
            }
        }
    }

    public struct AppBreakdownEntry: Sendable, Equatable, Identifiable {
        public let bundleIdentifier: String?
        public let processName: String
        public let path: String?
        public let totalEnergyNJ: Int64
        public let isSystem: Bool
        public var id: String { bundleIdentifier ?? processName }
    }

    /// Every process with non-zero energy in the window, classified into user
    /// vs system by `AppClassification`. No bucketing — used to drive the
    /// breakdown list and the dropdown's "System (n)" summary.
    public func appBreakdown(sinceMinutes minutes: Int) async throws -> [AppBreakdownEntry] {
        let since = Int64(Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    COALESCE(bundleIdentifier, processName) AS groupKey,
                    bundleIdentifier,
                    MAX(processName) AS processName,
                    MAX(path) AS path,
                    SUM(energyNJ) AS total
                FROM EnergyHistory
                WHERE timestamp >= ?
                GROUP BY groupKey
                HAVING total > 0
                ORDER BY total DESC
                """, arguments: [since])
            return rows.compactMap { row in
                guard let name: String = row["processName"],
                      let total: Int64 = row["total"] else { return nil }
                let bundleId: String? = row["bundleIdentifier"]
                let path: String? = row["path"]
                return AppBreakdownEntry(
                    bundleIdentifier: bundleId,
                    processName: name,
                    path: path,
                    totalEnergyNJ: total,
                    isSystem: AppClassification.isSystem(
                        bundleIdentifier: bundleId,
                        processName: name,
                        path: path
                    )
                )
            }
        }
    }

    public func powerEvents(sinceMinutes minutes: Int) async throws -> [PowerEvent] {
        let since = Int64(Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in
            try PowerEvent
                .filter(Column("timestamp") >= since)
                .order(Column("timestamp"))
                .fetchAll(db)
        }
    }

    /// True iff at least one bucket sample row was written within the last
    /// `withinMinutes`. Used by the UI to decide between "samples are
    /// flowing" and "the bucket sampler isn't producing data on this
    /// system" — a self-detected signal that works regardless of which
    /// sampling path (framework / IOConnect) actually succeeded.
    public func bucketSamplerActive(withinMinutes: Int = 5) async throws -> Bool {
        let since = Int64(Date().addingTimeInterval(-Double(withinMinutes) * 60).timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT 1 FROM SystemBuckets WHERE timestamp >= ? LIMIT 1
                """, arguments: [since])
            return row != nil
        }
    }

    /// Earliest sample timestamp across the whole DB. Used by the History
    /// window to (a) auto-pick a sensible default range for new installs and
    /// (b) tighten the Live range's x-axis when data is sparse.
    public func earliestSampleTimestamp() async throws -> Date? {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT MIN(timestamp) AS earliest FROM EnergyHistory"),
                  let earliest: Int64 = row["earliest"] else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(earliest) / 1000.0)
        }
    }

    // MARK: - v0.6 bucket + drain queries

    public func writeBatchBuckets(_ rows: [SystemBucket]) async throws {
        guard !rows.isEmpty else { return }
        try await dbPool.write { db in
            for row in rows {
                try row.insert(db)
            }
        }
    }

    public struct BucketSummary: Sendable, Equatable, Identifiable {
        public let bucketName: String
        public let totalEnergyNJ: Int64
        public let sparkline: [SparkPoint]

        public var id: String { bucketName }

        public struct SparkPoint: Sendable, Equatable {
            public let bucketStart: Date
            public let energyNJ: Int64
        }
    }

    /// Per-bucket totals over the window plus sparkline points bucketed at
    /// the requested resolution. Drives the History panel's
    /// "Energy breakdown" section.
    public func bucketSummaries(
        sinceMinutes: Int,
        sparklineBucketSeconds: Int
    ) async throws -> [BucketSummary] {
        let since = Int64(Date().addingTimeInterval(-Double(sinceMinutes) * 60).timeIntervalSince1970 * 1000)
        let bucketMs = Int64(sparklineBucketSeconds) * 1000
        guard bucketMs > 0 else { return [] }
        return try await dbPool.read { db in
            let totalRows = try Row.fetchAll(db, sql: """
                SELECT bucketName, SUM(energyNJ) AS total
                FROM SystemBuckets
                WHERE timestamp >= ?
                GROUP BY bucketName
                ORDER BY total DESC
                """, arguments: [since])
            var output: [BucketSummary] = []
            for row in totalRows {
                guard let name: String = row["bucketName"],
                      let total: Int64 = row["total"] else { continue }
                let sparklineRows = try Row.fetchAll(db, sql: """
                    SELECT (timestamp / ?) * ? AS bucketStart, SUM(energyNJ) AS v
                    FROM SystemBuckets
                    WHERE timestamp >= ? AND bucketName = ?
                    GROUP BY bucketStart
                    ORDER BY bucketStart
                    """, arguments: [bucketMs, bucketMs, since, name])
                let points: [BucketSummary.SparkPoint] = sparklineRows.compactMap { r in
                    guard let bs: Int64 = r["bucketStart"],
                          let v: Int64 = r["v"] else { return nil }
                    return BucketSummary.SparkPoint(
                        bucketStart: Date(timeIntervalSince1970: TimeInterval(bs) / 1000.0),
                        energyNJ: v
                    )
                }
                output.append(BucketSummary(
                    bucketName: name,
                    totalEnergyNJ: total,
                    sparkline: points
                ))
            }
            return output
        }
    }

    /// Observed discharge only; charging, transitions and missing coverage are excluded.
    public func totalDrainJ(sinceMinutes: Int) async throws -> Double {
        let interval = DateInterval(start: Date().addingTimeInterval(-Double(sinceMinutes) * 60), end: Date())
        return HistoryMath.drainJ(try await batteryHistory(in: interval), within: interval)
    }
}
