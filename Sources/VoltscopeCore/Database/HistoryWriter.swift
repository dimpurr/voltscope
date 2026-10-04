import Foundation
import Darwin
import GRDB

private let continuousClockTimebase: mach_timebase_info_data_t = {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return timebase
}()

func continuousClockSeconds() -> TimeInterval {
    let nanoseconds = Double(mach_continuous_time())
        * Double(continuousClockTimebase.numer) / Double(continuousClockTimebase.denom)
    return nanoseconds / 1_000_000_000
}

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

enum HistoryWindowBufferError: Error {
    case pendingLimitReached
}

actor HistoryWindowWriteGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Thread-safe in-memory coalescing for independently scheduled sampler calls.
final class HistoryWindowBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private static let maximumPendingWindows = 8
    private var windowStart: Int64?
    private var apps: [WindowAppKey: WindowAppValue] = [:]
    private var buckets: [WindowBucketKey: Int64] = [:]
    private var coverage = SampleCoverage(visible: 0, unreadable: 0)
    private var pending: [WindowBatch] = []

    fileprivate func append(timestamp: Int64, apps newApps: [SampledApp], buckets newBuckets: [SampledBucket],
                             coverage newCoverage: SampleCoverage?, version: Int, energyUnavailable: Bool) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let start = timestamp / 30_000 * 30_000
        if windowStart != nil, windowStart != start {
            guard pending.count < Self.maximumPendingWindows else { throw HistoryWindowBufferError.pendingLimitReached }
            if let completed = takeLocked() { pending.append(completed) }
        }
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
        return !pending.isEmpty
    }

    fileprivate func enqueueCurrentWindow() throws {
        lock.lock(); defer { lock.unlock() }
        guard windowStart != nil else { return }
        guard pending.count < Self.maximumPendingWindows else { throw HistoryWindowBufferError.pendingLimitReached }
        if let batch = takeLocked() { pending.append(batch) }
    }

    fileprivate func firstPending() -> WindowBatch? {
        lock.lock(); defer { lock.unlock() }
        return pending.first
    }

    fileprivate func removeFirstPending() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { pending.removeFirst() }
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
        await windowWriteGate.acquire()
        do {
            let hasPending = try windowBuffer.append(timestamp: timestamp, apps: [], buckets: buckets, coverage: nil,
                                                     version: metricVersion, energyUnavailable: false)
            if hasPending { try await persistPendingWindows() }
            await windowWriteGate.release()
        } catch {
            await windowWriteGate.release()
            throw error
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
        await windowWriteGate.acquire()
        do {
            let hasPending = try windowBuffer.append(timestamp: timestamp, apps: apps, buckets: buckets, coverage: coverage,
                                                     version: metricVersion, energyUnavailable: energyUnavailable)
            if hasPending { try await persistPendingWindows() }
            await windowWriteGate.release()
        } catch {
            await windowWriteGate.release()
            throw error
        }
    }

    /// Persists the last partial window. Called by maintenance and sampler shutdown.
    func flushPendingWindow() async throws {
        await windowWriteGate.acquire()
        do {
            try await persistPendingWindows()
            try windowBuffer.enqueueCurrentWindow()
            try await persistPendingWindows()
            await windowWriteGate.release()
        } catch {
            await windowWriteGate.release()
            throw error
        }
    }

    private func persistPendingWindows() async throws {
        while let batch = windowBuffer.firstPending() {
            try await persistWindow(batch)
            windowBuffer.removeFirstPending()
        }
    }

    private func persistWindow(_ batch: WindowBatch) async throws {
        try await dbPool.write { db in
            var appIDsByGroupKey: [String: Int64] = [:]
            appIDsByGroupKey.reserveCapacity(batch.apps.count)
            for value in batch.apps {
                let sample = value.sample
                let appId: Int64
                if let cachedID = appIDsByGroupKey[sample.groupKey] {
                    appId = cachedID
                } else {
                    appId = try upsertApp(
                        db,
                        groupKey: sample.groupKey,
                        bundleIdentifier: sample.bundleIdentifier,
                        displayName: sample.displayName,
                        path: sample.path,
                        ts: batch.start
                    )
                    appIDsByGroupKey[sample.groupKey] = appId
                }
                try db.execute(sql: """
                    UPDATE AppSampleRaw SET energyNJ=energyNJ+?, cpuNs=cpuNs+?, wakeups=wakeups+?,
                        diskReadBytes=diskReadBytes+?, diskWriteBytes=diskWriteBytes+?
                    WHERE ts=? AND appId=? AND pid=? AND metricVersion=?
                    """, arguments: [sample.energyNJ, sample.cpuNs, sample.wakeups, sample.diskReadBytes,
                                     sample.diskWriteBytes, batch.start, appId, sample.pid, value.version])
                let newRawRow = db.changesCount == 0
                if newRawRow {
                    try AppSampleRaw(
                        ts: batch.start, appId: appId, pid: sample.pid,
                        parentPid: sample.parentPid, metricVersion: value.version,
                        energyNJ: sample.energyNJ, cpuNs: sample.cpuNs,
                        wakeups: sample.wakeups, diskReadBytes: sample.diskReadBytes,
                        diskWriteBytes: sample.diskWriteBytes
                    ).insert(db)
                }
                if value.version != 0 {
                    try Self.addLateAppRollupDelta(db, timestamp: batch.start, appId: appId,
                                                   version: value.version, sample: sample,
                                                   newRawRow: newRawRow)
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
                if key.version != 0 {
                    try Self.addLateBucketRollupDelta(db, timestamp: batch.start, bucketId: bucketId,
                                                      version: key.version, energyNJ: energy)
                }
            }
            let previousCoverage = try Coverage.fetchOne(db, key: batch.start)
            try Coverage(ts: batch.start, visible: batch.coverage.visible, unreadable: batch.coverage.unreadable)
                .insert(db, onConflict: .replace)
            let coverageHour = batch.start / 3_600_000
            if coverageHour <= (try Self.watermark(db, key: "rollup.hourWatermark")) {
                try db.execute(sql: """
                    INSERT INTO CoverageHour (hour, ticks, visibleSum, unreadableSum)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(hour) DO UPDATE SET
                        ticks=ticks+excluded.ticks,
                        visibleSum=visibleSum+excluded.visibleSum,
                        unreadableSum=unreadableSum+excluded.unreadableSum
                    """, arguments: [coverageHour, previousCoverage == nil ? 1 : 0,
                                    batch.coverage.visible - (previousCoverage?.visible ?? 0),
                                    batch.coverage.unreadable - (previousCoverage?.unreadable ?? 0)])
            }
        }
    }

    /// Runs each maintenance phase in its own transaction. The injected date
    /// keeps cutoff behavior deterministic in tests.
    func runMaintenance(now: Date = Date(), monotonicNow: TimeInterval? = nil) async throws {
        try await flushPendingWindow()
        try await rollupMinutes(now: now)
        try await rollupHours(now: now)
        try await pruneHistory(now: now, monotonicNow: monotonicNow ?? continuousClockSeconds())
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
            let lowerTimestamp = (watermark + 1) * 60_000
            let upperTimestamp = upperBound * 60_000
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
                WHERE ts >= ? AND ts < ? AND metricVersion <> 0
                GROUP BY ts / 60000, appId, metricVersion
                """, arguments: [lowerTimestamp, upperTimestamp])
            try db.execute(sql: """
                INSERT OR IGNORE INTO AppUsageMinute
                    (minute, appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples)
                SELECT ts / 60000, appId, metricVersion, SUM(energyNJ), SUM(cpuNs), SUM(wakeups),
                       SUM(diskReadBytes), SUM(diskWriteBytes), COUNT(*)
                FROM AppSampleRaw
                WHERE ts >= ? AND ts < ? AND metricVersion = 0
                GROUP BY ts / 60000, appId, metricVersion
                """, arguments: [lowerTimestamp, upperTimestamp])
            try db.execute(sql: """
                INSERT OR REPLACE INTO BucketMinute (minute, bucketId, metricVersion, energyNJ)
                SELECT ts / 60000, bucketId, metricVersion, SUM(energyNJ)
                FROM BucketSampleRaw
                WHERE ts >= ? AND ts < ? AND metricVersion <> 0
                GROUP BY ts / 60000, bucketId, metricVersion
                """, arguments: [lowerTimestamp, upperTimestamp])
            try db.execute(sql: """
                INSERT OR IGNORE INTO BucketMinute (minute, bucketId, metricVersion, energyNJ)
                SELECT ts / 60000, bucketId, metricVersion, SUM(energyNJ)
                FROM BucketSampleRaw
                WHERE ts >= ? AND ts < ? AND metricVersion = 0
                GROUP BY ts / 60000, bucketId, metricVersion
                """, arguments: [lowerTimestamp, upperTimestamp])
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
            let lowerMinute = (hourWatermark + 1) * 60
            let upperMinute = upperBound * 60
            let lowerTimestamp = (hourWatermark + 1) * 3_600_000
            let upperTimestamp = upperBound * 3_600_000
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
                WHERE minute >= ? AND minute < ? AND metricVersion <> 0
                GROUP BY minute / 60, appId, metricVersion
                """, arguments: [lowerMinute, upperMinute])
            try db.execute(sql: """
                INSERT OR IGNORE INTO AppUsageHour
                    (hour, appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples)
                SELECT minute / 60, appId, metricVersion, SUM(energyNJ), SUM(cpuNs), SUM(wakeups),
                       SUM(diskReadBytes), SUM(diskWriteBytes), SUM(samples)
                FROM AppUsageMinute
                WHERE minute >= ? AND minute < ? AND metricVersion = 0
                GROUP BY minute / 60, appId, metricVersion
                """, arguments: [lowerMinute, upperMinute])
            try db.execute(sql: """
                INSERT OR REPLACE INTO BucketHour (hour, bucketId, metricVersion, energyNJ)
                SELECT minute / 60, bucketId, metricVersion, SUM(energyNJ)
                FROM BucketMinute
                WHERE minute >= ? AND minute < ? AND metricVersion <> 0
                GROUP BY minute / 60, bucketId, metricVersion
                """, arguments: [lowerMinute, upperMinute])
            try db.execute(sql: """
                INSERT OR IGNORE INTO BucketHour (hour, bucketId, metricVersion, energyNJ)
                SELECT minute / 60, bucketId, metricVersion, SUM(energyNJ)
                FROM BucketMinute
                WHERE minute >= ? AND minute < ? AND metricVersion = 0
                GROUP BY minute / 60, bucketId, metricVersion
                """, arguments: [lowerMinute, upperMinute])
            try db.execute(sql: """
                INSERT OR REPLACE INTO CoverageHour (hour, ticks, visibleSum, unreadableSum)
                SELECT ts / 3600000, COUNT(*), SUM(visible), SUM(unreadable)
                FROM Coverage
                WHERE ts >= ? AND ts < ?
                GROUP BY ts / 3600000
                """, arguments: [lowerTimestamp, upperTimestamp])
            try Self.setWatermark(db, key: "rollup.hourWatermark", value: upperBound - 1)
        }
    }

    /// Applies raw and minute retention while preserving all hour summaries.
    func pruneHistory(now: Date = Date(), monotonicNow: TimeInterval? = nil) async throws {
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        let monotonicMS = Int64((monotonicNow ?? continuousClockSeconds()) * 1000)
        try await dbPool.write { db in
            let safeNowMS = try Self.advanceSafeClock(db, nowMS: nowMS, monotonicMS: monotonicMS)
            let retention = try Int.fetchOne(
                db,
                sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key = 'settings.rawRetentionDays'"
            ) ?? 7
            let rawCutoff = (safeNowMS - Int64(retention) * 86_400_000) / 30_000 * 30_000
            let minuteCutoff = safeNowMS / 60_000 - 2 * 24 * 60
            try db.execute(sql: "DELETE FROM AppSampleRaw WHERE ts < ?", arguments: [rawCutoff])
            try db.execute(sql: "DELETE FROM BucketSampleRaw WHERE ts < ?", arguments: [rawCutoff])
            try db.execute(sql: "DELETE FROM Coverage WHERE ts < ?", arguments: [rawCutoff])
            try db.execute(sql: "DELETE FROM AppUsageMinute WHERE minute < ?", arguments: [minuteCutoff])
            try db.execute(sql: "DELETE FROM BucketMinute WHERE minute < ?", arguments: [minuteCutoff])
        }
    }

    /// Advances the persisted safe wall clock using the same sleep-inclusive
    /// continuous-clock anchor for pruning and legacy database lifecycle work.
    func safeNow(now: Date = Date(), monotonicNow: TimeInterval? = nil,
                 fallbackLatestHistoryMS: Int64? = nil) async throws -> Int64 {
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        let monotonicMS = Int64((monotonicNow ?? continuousClockSeconds()) * 1000)
        return try await dbPool.write { db in
            try Self.advanceSafeClock(db, nowMS: nowMS, monotonicMS: monotonicMS,
                                      fallbackLatestHistoryMS: fallbackLatestHistoryMS)
        }
    }

    private static func advanceSafeClock(_ db: Database, nowMS: Int64, monotonicMS: Int64,
                                         fallbackLatestHistoryMS: Int64? = nil) throws -> Int64 {
        let previousSafeMS = try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key = 'retention.safeWallClockMS'")
        let previousMonotonicMS = try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key = 'retention.safeMonotonicMS'")
        let latestHistoryMS = try Self.latestHistoryTimestampMS(db) ?? fallbackLatestHistoryMS
        let safeNowMS: Int64
        if let previousSafeMS, let previousMonotonicMS {
            if monotonicMS >= previousMonotonicMS {
                let elapsed = monotonicMS - previousMonotonicMS
                safeNowMS = min(nowMS, previousSafeMS + elapsed)
            } else if let latestHistoryMS {
                // A reboot resets the continuous clock. Re-anchor from stored
                // history so a wall-clock jump cannot advance retention.
                safeNowMS = min(nowMS, latestHistoryMS + 5 * 60_000)
            } else {
                safeNowMS = min(nowMS, previousSafeMS)
            }
        } else if let latestHistoryMS {
            // Establish a conservative anchor on upgrades or before the first
            // import has populated history.
            safeNowMS = min(nowMS, latestHistoryMS + 5 * 60_000)
        } else {
            safeNowMS = nowMS
        }
        try Self.setWatermark(db, key: "retention.safeWallClockMS", value: safeNowMS)
        try Self.setWatermark(db, key: "retention.safeMonotonicMS", value: monotonicMS)
        return safeNowMS
    }

    private static func latestHistoryTimestampMS(_ db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
                SELECT MAX(timestampMS) FROM (
                    SELECT MAX(ts) AS timestampMS FROM AppSampleRaw
                    UNION ALL SELECT MAX(ts) FROM BucketSampleRaw
                    UNION ALL SELECT MAX(hour * 3600000) FROM AppUsageHour
                    UNION ALL SELECT MAX(hour * 3600000) FROM BucketHour
                )
                """)
    }

    /// Asks SQLite to reclaim a bounded number of pages in incremental mode.
    func incrementalVacuum() async throws {
        try await dbPool.write { db in try db.execute(sql: "PRAGMA incremental_vacuum(2000)") }
        // Checkpoint outside a transaction so the reclaimed database tail is
        // reflected in the main file and the reusable WAL is truncated.
        try await dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
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

    private static func addLateAppRollupDelta(_ db: Database, timestamp: Int64, appId: Int64,
                                               version: Int, sample: SampledApp, newRawRow: Bool) throws {
        let minute = timestamp / 60_000
        let hour = timestamp / 3_600_000
        let minuteWatermark = try watermark(db, key: "rollup.minuteWatermark")
        if minute <= minuteWatermark {
            try db.execute(sql: """
                INSERT INTO AppUsageMinute (minute, appId, metricVersion, energyNJ, cpuNs, wakeups,
                                            diskReadBytes, diskWriteBytes, samples)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(minute, appId, metricVersion) DO UPDATE SET
                    energyNJ=energyNJ+excluded.energyNJ, cpuNs=cpuNs+excluded.cpuNs,
                    wakeups=wakeups+excluded.wakeups, diskReadBytes=diskReadBytes+excluded.diskReadBytes,
                    diskWriteBytes=diskWriteBytes+excluded.diskWriteBytes, samples=samples+excluded.samples
                """, arguments: [minute, appId, version, sample.energyNJ, sample.cpuNs, sample.wakeups,
                                sample.diskReadBytes, sample.diskWriteBytes, newRawRow ? 1 : 0])
        }
        let hourWatermark = try watermark(db, key: "rollup.hourWatermark")
        if hour <= hourWatermark {
            try db.execute(sql: """
                INSERT INTO AppUsageHour (hour, appId, metricVersion, energyNJ, cpuNs, wakeups,
                                          diskReadBytes, diskWriteBytes, samples)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(hour, appId, metricVersion) DO UPDATE SET
                    energyNJ=energyNJ+excluded.energyNJ, cpuNs=cpuNs+excluded.cpuNs,
                    wakeups=wakeups+excluded.wakeups, diskReadBytes=diskReadBytes+excluded.diskReadBytes,
                    diskWriteBytes=diskWriteBytes+excluded.diskWriteBytes, samples=samples+excluded.samples
                """, arguments: [hour, appId, version, sample.energyNJ, sample.cpuNs, sample.wakeups,
                                sample.diskReadBytes, sample.diskWriteBytes, newRawRow ? 1 : 0])
        }
    }

    private static func addLateBucketRollupDelta(_ db: Database, timestamp: Int64, bucketId: Int64,
                                                  version: Int, energyNJ: Int64) throws {
        let minute = timestamp / 60_000
        if minute <= (try watermark(db, key: "rollup.minuteWatermark")) {
            try db.execute(sql: """
                INSERT INTO BucketMinute (minute, bucketId, metricVersion, energyNJ) VALUES (?, ?, ?, ?)
                ON CONFLICT(minute, bucketId, metricVersion) DO UPDATE SET energyNJ=energyNJ+excluded.energyNJ
                """, arguments: [minute, bucketId, version, energyNJ])
        }
        let hour = timestamp / 3_600_000
        if hour <= (try watermark(db, key: "rollup.hourWatermark")) {
            try db.execute(sql: """
                INSERT INTO BucketHour (hour, bucketId, metricVersion, energyNJ) VALUES (?, ?, ?, ?)
                ON CONFLICT(hour, bucketId, metricVersion) DO UPDATE SET energyNJ=energyNJ+excluded.energyNJ
                """, arguments: [hour, bucketId, version, energyNJ])
        }
    }
}
