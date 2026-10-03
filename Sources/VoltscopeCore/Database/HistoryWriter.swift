import Foundation
import GRDB

private struct WindowAppKey: Hashable {
    let groupKey: String
    let pid: Int32
    let version: Int
}

private struct WindowAppValue {
    var sample: SampledApp
    let version: Int
}

private struct WindowBucketKey: Hashable {
    let name: String
    let version: Int
}

private struct WindowBatch {
    let start: Int64
    let apps: [WindowAppValue]
    let buckets: [WindowBucketKey: Int64]
    let coverage: SampleCoverage
}

/// Thread-safe in-memory coalescing for independently scheduled sampler calls.
final class HistoryWindowBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var windowStart: Int64?
    private var apps: [WindowAppKey: WindowAppValue] = [:]
    private var buckets: [WindowBucketKey: Int64] = [:]
    private var coverage = SampleCoverage(visible: 0, unreadable: 0)

    fileprivate func append(timestamp: Int64, apps newApps: [SampledApp], buckets newBuckets: [SampledBucket],
                coverage newCoverage: SampleCoverage?, version: Int, energyUnavailable: Bool) -> WindowBatch? {
        lock.lock(); defer { lock.unlock() }
        let start = timestamp / 30_000 * 30_000
        let completed = windowStart != nil && windowStart != start ? takeLocked() : nil
        if windowStart == nil || windowStart != start { windowStart = start }
        for sample in newApps where sample.energyNJ > 0 || (energyUnavailable && sample.cpuNs > 0) {
            let key = WindowAppKey(groupKey: sample.groupKey, pid: sample.pid, version: version)
            if var old = apps[key] {
                old.sample.energyNJ += sample.energyNJ; old.sample.cpuNs += sample.cpuNs
                old.sample.wakeups += sample.wakeups; old.sample.diskReadBytes += sample.diskReadBytes
                old.sample.diskWriteBytes += sample.diskWriteBytes
                apps[key] = old
            } else { apps[key] = WindowAppValue(sample: sample, version: version) }
        }
        for sample in newBuckets {
            let key = WindowBucketKey(name: sample.name, version: version)
            buckets[key, default: 0] += sample.energyNJ
        }
        if let newCoverage { coverage = newCoverage }
        return completed
    }

    fileprivate func flush() -> WindowBatch? {
        lock.lock(); defer { lock.unlock() }
        return takeLocked()
    }

    private func takeLocked() -> WindowBatch? {
        guard let start = windowStart else { return nil }
        let batch = WindowBatch(start: start, apps: Array(apps.values), buckets: buckets, coverage: coverage)
        windowStart = nil; apps.removeAll(); buckets.removeAll()
        coverage = SampleCoverage(visible: 0, unreadable: 0)
        return batch
    }
}

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
    func writeBatterySnapshot(_ snapshot: BatterySnapshot) async throws {
        try await dbPool.write { db in try snapshot.insert(db, onConflict: .replace) }
    }

    func writePowerEvent(_ event: PowerEvent) async throws {
        try await dbPool.write { db in try event.insert(db, onConflict: .replace) }
    }

    /// Writes hardware bucket deltas from the independently scheduled sampler.
    func writeBuckets(timestamp: Int64, buckets: [SampledBucket], metricVersion: Int = EnergyMetric.currentVersion) async throws {
        if let completed = windowBuffer.append(timestamp: timestamp, apps: [], buckets: buckets, coverage: nil,
                                                version: metricVersion, energyUnavailable: false) {
            try await persistWindow(completed)
        }
    }

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
        if let completed = windowBuffer.append(timestamp: timestamp, apps: apps, buckets: buckets, coverage: coverage,
                                                version: metricVersion, energyUnavailable: energyUnavailable) {
            try await persistWindow(completed)
        }
    }

    /// Persists the last partial window. Called by maintenance and sampler shutdown.
    func flushPendingWindow() async throws {
        if let pending = windowBuffer.flush() { try await persistWindow(pending) }
    }

    private func persistWindow(_ batch: WindowBatch) async throws {
        try await dbPool.write { db in
            for value in batch.apps {
                let sample = value.sample
                let appId = try upsertApp(
                    db,
                    groupKey: sample.groupKey,
                    bundleIdentifier: sample.bundleIdentifier,
                    displayName: sample.displayName,
                    path: sample.path,
                    ts: batch.start
                )
                try db.execute(sql: """
                    UPDATE AppSampleRaw SET energyNJ=energyNJ+?, cpuNs=cpuNs+?, wakeups=wakeups+?,
                        diskReadBytes=diskReadBytes+?, diskWriteBytes=diskWriteBytes+?
                    WHERE ts=? AND appId=? AND pid=? AND metricVersion=?
                    """, arguments: [sample.energyNJ, sample.cpuNs, sample.wakeups, sample.diskReadBytes,
                                     sample.diskWriteBytes, batch.start, appId, sample.pid, value.version])
                if db.changesCount == 0 {
                    try AppSampleRaw(
                        ts: batch.start, appId: appId, pid: sample.pid,
                        parentPid: sample.parentPid, metricVersion: value.version,
                        energyNJ: sample.energyNJ, cpuNs: sample.cpuNs,
                        wakeups: sample.wakeups, diskReadBytes: sample.diskReadBytes,
                        diskWriteBytes: sample.diskWriteBytes
                    ).insert(db)
                }
            }

            for (key, energy) in batch.buckets {
                let bucketId = try upsertBucket(db, name: key.name)
                try db.execute(sql: "UPDATE BucketSampleRaw SET energyNJ=energyNJ+? WHERE ts=? AND bucketId=? AND metricVersion=?",
                               arguments: [energy, batch.start, bucketId, key.version])
                if db.changesCount == 0 {
                    try BucketSampleRaw(ts: batch.start, bucketId: bucketId,
                                        metricVersion: key.version, energyNJ: energy).insert(db)
                }
            }
            try Coverage(ts: batch.start, visible: batch.coverage.visible, unreadable: batch.coverage.unreadable)
                .insert(db, onConflict: .replace)
        }
    }

    /// Runs each maintenance phase in its own transaction. The injected date
    /// keeps cutoff behavior deterministic in tests.
    func runMaintenance(now: Date = Date()) async throws {
        try await flushPendingWindow()
        try await rollupMinutes(now: now)
        try await rollupHours(now: now)
        try await pruneHistory(now: now)
        try await incrementalVacuum()
    }

    /// Recomputes eligible minute rows from raw samples and advances the
    /// committed minute watermark in the same transaction.
    func rollupMinutes(now: Date = Date()) async throws {
        try await flushPendingWindow()
        let currentMinute = Int64(now.timeIntervalSince1970 / 60)
        let upperBound = currentMinute - 1
        try await dbPool.write { db in
            let watermark = try Self.watermark(db, key: "rollup.minuteWatermark")
            guard upperBound > watermark + 1 else { return }
            // Current-version rows are recomputed from raw and replaced. Legacy
            // (version 0) rows are only filled in where absent: the importer
            // aggregated them over a window wider than raw retention, so
            // recomputing a minute that straddles the raw cutoff from the raw
            // subset alone would drop energy that exists only in the imported
            // minute.
            try db.execute(sql: """
                INSERT OR REPLACE INTO AppUsageMinute
                    (minute, appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples)
                SELECT ts / 60000, appId, metricVersion, SUM(energyNJ), SUM(cpuNs), SUM(wakeups),
                       SUM(diskReadBytes), SUM(diskWriteBytes), COUNT(*)
                FROM AppSampleRaw
                WHERE ts / 60000 > ? AND ts / 60000 < ? AND metricVersion <> 0
                GROUP BY ts / 60000, appId, metricVersion
                """, arguments: [watermark, upperBound])
            try db.execute(sql: """
                INSERT OR IGNORE INTO AppUsageMinute
                    (minute, appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples)
                SELECT ts / 60000, appId, metricVersion, SUM(energyNJ), SUM(cpuNs), SUM(wakeups),
                       SUM(diskReadBytes), SUM(diskWriteBytes), COUNT(*)
                FROM AppSampleRaw
                WHERE ts / 60000 > ? AND ts / 60000 < ? AND metricVersion = 0
                GROUP BY ts / 60000, appId, metricVersion
                """, arguments: [watermark, upperBound])
            try db.execute(sql: """
                INSERT OR REPLACE INTO BucketMinute (minute, bucketId, metricVersion, energyNJ)
                SELECT ts / 60000, bucketId, metricVersion, SUM(energyNJ)
                FROM BucketSampleRaw
                WHERE ts / 60000 > ? AND ts / 60000 < ? AND metricVersion <> 0
                GROUP BY ts / 60000, bucketId, metricVersion
                """, arguments: [watermark, upperBound])
            try db.execute(sql: """
                INSERT OR IGNORE INTO BucketMinute (minute, bucketId, metricVersion, energyNJ)
                SELECT ts / 60000, bucketId, metricVersion, SUM(energyNJ)
                FROM BucketSampleRaw
                WHERE ts / 60000 > ? AND ts / 60000 < ? AND metricVersion = 0
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
            // Same version rule as the minute rollup: legacy hours are kept
            // once the importer wrote them, because the hour that straddles
            // the minute-retention cutoff would otherwise be rebuilt from the
            // surviving minutes alone.
            try db.execute(sql: """
                INSERT OR REPLACE INTO AppUsageHour
                    (hour, appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples)
                SELECT minute / 60, appId, metricVersion, SUM(energyNJ), SUM(cpuNs), SUM(wakeups),
                       SUM(diskReadBytes), SUM(diskWriteBytes), SUM(samples)
                FROM AppUsageMinute
                WHERE minute / 60 > ? AND minute / 60 < ? AND metricVersion <> 0
                GROUP BY minute / 60, appId, metricVersion
                """, arguments: [hourWatermark, upperBound])
            try db.execute(sql: """
                INSERT OR IGNORE INTO AppUsageHour
                    (hour, appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples)
                SELECT minute / 60, appId, metricVersion, SUM(energyNJ), SUM(cpuNs), SUM(wakeups),
                       SUM(diskReadBytes), SUM(diskWriteBytes), SUM(samples)
                FROM AppUsageMinute
                WHERE minute / 60 > ? AND minute / 60 < ? AND metricVersion = 0
                GROUP BY minute / 60, appId, metricVersion
                """, arguments: [hourWatermark, upperBound])
            try db.execute(sql: """
                INSERT OR REPLACE INTO BucketHour (hour, bucketId, metricVersion, energyNJ)
                SELECT minute / 60, bucketId, metricVersion, SUM(energyNJ)
                FROM BucketMinute
                WHERE minute / 60 > ? AND minute / 60 < ? AND metricVersion <> 0
                GROUP BY minute / 60, bucketId, metricVersion
                """, arguments: [hourWatermark, upperBound])
            try db.execute(sql: """
                INSERT OR IGNORE INTO BucketHour (hour, bucketId, metricVersion, energyNJ)
                SELECT minute / 60, bucketId, metricVersion, SUM(energyNJ)
                FROM BucketMinute
                WHERE minute / 60 > ? AND minute / 60 < ? AND metricVersion = 0
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
            let rawCutoff = (nowMS - Int64(retention) * 86_400_000) / 30_000 * 30_000
            let minuteCutoff = nowMS / 60_000 - 2 * 24 * 60
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
