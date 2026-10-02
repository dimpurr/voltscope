import Foundation
import GRDB

/// Process identity and metadata supplied by a sampling caller.
public struct SampledApp: Equatable, Sendable {
    public var groupKey: String
    public var bundleIdentifier: String?
    public var displayName: String
    public var path: String?
    public var pid: Int32
    public var parentPid: Int32?
    public var energyNJ: Int64
    public var cpuNs: Int64
    public var wakeups: Int64
    public var diskReadBytes: Int64
    public var diskWriteBytes: Int64

    public init(
        groupKey: String, bundleIdentifier: String? = nil, displayName: String,
        path: String? = nil, pid: Int32, parentPid: Int32? = nil,
        energyNJ: Int64, cpuNs: Int64, wakeups: Int64 = 0,
        diskReadBytes: Int64 = 0, diskWriteBytes: Int64 = 0
    ) {
        self.groupKey = groupKey
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.path = path
        self.pid = pid
        self.parentPid = parentPid
        self.energyNJ = energyNJ
        self.cpuNs = cpuNs
        self.wakeups = wakeups
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
    }
}

/// A named hardware energy sample supplied by a sampling caller.
public struct SampledBucket: Equatable, Sendable {
    public var name: String
    public var energyNJ: Int64

    public init(name: String, energyNJ: Int64) {
        self.name = name
        self.energyNJ = energyNJ
    }
}

/// Counts describing the process scan performed during one sampling tick.
public struct SampleCoverage: Equatable, Sendable {
    public var visible: Int64
    public var unreadable: Int64

    public init(visible: Int64, unreadable: Int64) {
        self.visible = visible
        self.unreadable = unreadable
    }
}

public extension HistoryDatabase {
    /// Writes a complete sampling tick atomically. When process energy is not
    /// available, callers may retain CPU-active rows by setting
    /// `energyUnavailable`; this decision is supplied by the platform layer.
    func writeTick(
        timestamp: Int64,
        apps: [SampledApp],
        buckets: [SampledBucket],
        coverage: SampleCoverage,
        metricVersion: Int = EnergyMetric.currentVersion,
        energyUnavailable: Bool = false
    ) async throws {
        try await dbPool.write { db in
            for sample in apps where sample.energyNJ > 0 || (energyUnavailable && sample.cpuNs > 0) {
                let appId = try upsertApp(
                    db,
                    groupKey: sample.groupKey,
                    bundleIdentifier: sample.bundleIdentifier,
                    displayName: sample.displayName,
                    path: sample.path,
                    ts: timestamp
                )
                try AppSampleRaw(
                    ts: timestamp, appId: appId, pid: sample.pid,
                    parentPid: sample.parentPid, metricVersion: metricVersion,
                    energyNJ: sample.energyNJ, cpuNs: sample.cpuNs,
                    wakeups: sample.wakeups, diskReadBytes: sample.diskReadBytes,
                    diskWriteBytes: sample.diskWriteBytes
                ).insert(db)
            }

            for sample in buckets {
                let bucketId = try upsertBucket(db, name: sample.name)
                try BucketSampleRaw(
                    ts: timestamp, bucketId: bucketId,
                    metricVersion: metricVersion, energyNJ: sample.energyNJ
                ).insert(db)
            }
            try Coverage(ts: timestamp, visible: coverage.visible, unreadable: coverage.unreadable).insert(db)
        }
    }

    /// Runs each maintenance phase in its own transaction. The injected date
    /// keeps cutoff behavior deterministic in tests.
    func runMaintenance(now: Date = Date()) async throws {
        try await rollupMinutes(now: now)
        try await rollupHours(now: now)
        try await pruneHistory(now: now)
        try await incrementalVacuum()
    }

    /// Recomputes eligible minute rows from raw samples and advances the
    /// committed minute watermark in the same transaction.
    func rollupMinutes(now: Date = Date()) async throws {
        let currentMinute = Int64(now.timeIntervalSince1970 / 60)
        let upperBound = currentMinute - 1
        try await dbPool.write { db in
            let watermark = try Self.watermark(db, key: "rollup.minuteWatermark")
            guard upperBound > watermark + 1 else { return }
            try db.execute(sql: """
                INSERT OR REPLACE INTO AppUsageMinute
                    (minute, appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples)
                SELECT ts / 60000, appId, metricVersion, SUM(energyNJ), SUM(cpuNs), SUM(wakeups),
                       SUM(diskReadBytes), SUM(diskWriteBytes), COUNT(*)
                FROM AppSampleRaw
                WHERE ts / 60000 > ? AND ts / 60000 < ?
                GROUP BY ts / 60000, appId, metricVersion
                """, arguments: [watermark, upperBound])
            try db.execute(sql: """
                INSERT OR REPLACE INTO BucketMinute (minute, bucketId, metricVersion, energyNJ)
                SELECT ts / 60000, bucketId, metricVersion, SUM(energyNJ)
                FROM BucketSampleRaw
                WHERE ts / 60000 > ? AND ts / 60000 < ?
                GROUP BY ts / 60000, bucketId, metricVersion
                """, arguments: [watermark, upperBound])
            try Self.setWatermark(db, key: "rollup.minuteWatermark", value: upperBound - 1)
        }
    }

    /// Recomputes complete hours from minute tables and tick coverage.
    func rollupHours(now: Date = Date()) async throws {
        let currentHour = Int64(now.timeIntervalSince1970 / 3600)
        try await dbPool.write { db in
            let minuteWatermark = try Self.watermark(db, key: "rollup.minuteWatermark")
            let hourWatermark = try Self.watermark(db, key: "rollup.hourWatermark")
            let upperBound = min(currentHour, minuteWatermark / 60)
            guard upperBound > hourWatermark + 1 else { return }
            try db.execute(sql: """
                INSERT OR REPLACE INTO AppUsageHour
                    (hour, appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples)
                SELECT minute / 60, appId, metricVersion, SUM(energyNJ), SUM(cpuNs), SUM(wakeups),
                       SUM(diskReadBytes), SUM(diskWriteBytes), SUM(samples)
                FROM AppUsageMinute
                WHERE minute / 60 > ? AND minute / 60 < ?
                GROUP BY minute / 60, appId, metricVersion
                """, arguments: [hourWatermark, upperBound])
            try db.execute(sql: """
                INSERT OR REPLACE INTO BucketHour (hour, bucketId, metricVersion, energyNJ)
                SELECT minute / 60, bucketId, metricVersion, SUM(energyNJ)
                FROM BucketMinute
                WHERE minute / 60 > ? AND minute / 60 < ?
                GROUP BY minute / 60, bucketId, metricVersion
                """, arguments: [hourWatermark, upperBound])
            try db.execute(sql: """
                INSERT OR REPLACE INTO CoverageHour (hour, ticks, visibleSum, unreadableSum)
                SELECT ts / 3600000, COUNT(*), SUM(visible), SUM(unreadable)
                FROM Coverage
                WHERE ts / 3600000 > ? AND ts / 3600000 < ?
                GROUP BY ts / 3600000
                """, arguments: [hourWatermark, upperBound])
            try Self.setWatermark(db, key: "rollup.hourWatermark", value: upperBound - 1)
        }
    }

    /// Applies raw and minute retention while preserving all hour summaries.
    func pruneHistory(now: Date = Date()) async throws {
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        try await dbPool.write { db in
            let retention = try Int.fetchOne(
                db,
                sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key = 'settings.rawRetentionDays'"
            ) ?? 7
            let rawCutoff = nowMS - Int64(retention) * 86_400_000
            let minuteCutoff = nowMS / 60_000 - 30 * 24 * 60
            try db.execute(sql: "DELETE FROM AppSampleRaw WHERE ts < ?", arguments: [rawCutoff])
            try db.execute(sql: "DELETE FROM BucketSampleRaw WHERE ts < ?", arguments: [rawCutoff])
            try db.execute(sql: "DELETE FROM Coverage WHERE ts < ?", arguments: [rawCutoff])
            try db.execute(sql: "DELETE FROM AppUsageMinute WHERE minute < ?", arguments: [minuteCutoff])
            try db.execute(sql: "DELETE FROM BucketMinute WHERE minute < ?", arguments: [minuteCutoff])
        }
    }

    /// Asks SQLite to reclaim a bounded number of pages in incremental mode.
    func incrementalVacuum() async throws {
        try await dbPool.write { db in try db.execute(sql: "PRAGMA incremental_vacuum(2000)") }
    }

    private static func watermark(_ db: Database, key: String) throws -> Int64 {
        try Int64.fetchOne(
            db,
            sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key = ?",
            arguments: [key]
        ) ?? -1
    }

    private static func setWatermark(_ db: Database, key: String, value: Int64) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO Meta (key, value) VALUES (?, ?)",
            arguments: [key, String(value)]
        )
    }
}
