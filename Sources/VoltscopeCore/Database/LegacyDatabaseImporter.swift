import Foundation
import GRDB
import Darwin

private actor LegacyImportRunLock {
    private var isLocked = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    func lock() async throws {
        try Task.checkCancellation()
        if !isLocked { isLocked = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// Progress for a legacy database import.
public struct LegacyImportProgress: Sendable, Equatable {
    public let importedHours: Int64
    public let totalHours: Int64

    public init(importedHours: Int64, totalHours: Int64) {
        self.importedHours = importedHours
        self.totalHours = totalHours
    }
}

/// Injectable CPU clock scale. Production callers should use `system`.
public struct LegacyTimebase: Sendable, Equatable {
    public let numer: Int64
    public let denom: Int64

    public init(numer: Int64, denom: Int64) {
        self.numer = numer
        self.denom = denom
    }

    public static var system: LegacyTimebase {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return LegacyTimebase(numer: Int64(info.numer), denom: Int64(info.denom))
    }
}

public enum LegacyImportState: String, Sendable {
    case none, pending, importing, verifying, done, failed
}

public enum LegacyImportError: Error, LocalizedError, Equatable {
    case invalidTimebase
    case missingLegacyTables
    case emptyLegacyEnergyHistory
    case verificationFailed(String)
    case deletionNotAllowed(LegacyImportState)

    public var errorDescription: String? {
        switch self {
        case .invalidTimebase: return "The CPU timebase must have positive numerator and denominator."
        case .missingLegacyTables: return "The legacy database is missing EnergyHistory or SystemBuckets."
        case .emptyLegacyEnergyHistory: return "The legacy EnergyHistory table contains no rows."
        case .verificationFailed(let reason): return reason
        case .deletionNotAllowed(let state): return "Legacy database deletion is not allowed while import state is \(state.rawValue)."
        }
    }
}

private struct LegacyAppRow: Sendable {
    let timestamp: Int64
    let pid: Int32
    let bundleIdentifier: String?
    let processName: String
    let path: String?
    let parentPid: Int32?
    let cpuUserNs: Int64
    let cpuSystemNs: Int64
    let energyNJ: Int64
    let wakeups: Int64
    let diskReadBytes: Int64
    let diskWriteBytes: Int64
}

private struct LegacyBucketRow: Sendable {
    let timestamp: Int64
    let bucketName: String
    let energyNJ: Int64
}

/// Imports the old database without ever opening it for writing.
public final class LegacyDatabaseImporter: @unchecked Sendable {
    public let history: HistoryDatabase
    public let legacyURL: URL
    public let timebase: LegacyTimebase
    public let rawRetentionDays: Int
    public let progressHandler: (@Sendable (LegacyImportProgress) -> Void)?
    private let batteryCopyProgress: (@Sendable (Int) -> Void)?
    private let runLock = LegacyImportRunLock()
    private let now: @Sendable () -> Date

    public convenience init(
        history: HistoryDatabase,
        legacyURL: URL,
        timebase: LegacyTimebase = .system,
        now: @escaping @Sendable () -> Date = Date.init,
        rawRetentionDays: Int = 7,
        progress: (@Sendable (LegacyImportProgress) -> Void)? = nil
    ) {
        self.init(history: history, legacyURL: legacyURL, timebase: timebase, now: now,
                  rawRetentionDays: rawRetentionDays, progress: progress, batteryCopyProgress: nil)
    }

    init(
        history: HistoryDatabase,
        legacyURL: URL,
        timebase: LegacyTimebase = .system,
        now: @escaping @Sendable () -> Date = Date.init,
        rawRetentionDays: Int = 7,
        progress: (@Sendable (LegacyImportProgress) -> Void)? = nil,
        batteryCopyProgress: (@Sendable (Int) -> Void)?
    ) {
        self.history = history
        self.legacyURL = legacyURL
        self.timebase = timebase
        self.rawRetentionDays = max(0, rawRetentionDays)
        self.progressHandler = progress
        self.batteryCopyProgress = batteryCopyProgress
        self.now = now
    }

    /// Starts import work independently of the caller's executor.
    @discardableResult
    public func start() -> Task<Void, Error> {
        Task.detached(priority: .utility) { try await self.run() }
    }

    /// Imports hour by hour. The cursor update commits with each hour's rows,
    /// making a cancelled or interrupted run safe to resume.
    public func run() async throws {
        try await runLock.lock()
        if Task.isCancelled {
            await runLock.unlock()
            throw CancellationError()
        }
        do {
            try await performRun()
            await runLock.unlock()
        } catch {
            await runLock.unlock()
            throw error
        }
    }

    private func performRun() async throws {
        guard timebase.numer > 0, timebase.denom > 0 else { throw LegacyImportError.invalidTimebase }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { throw CocoaError(.fileNoSuchFile) }

        let snapshot = try Self.prepareLegacySnapshot(at: legacyURL)
        defer { snapshot.cleanup?() }
        var configuration = Configuration()
        configuration.readonly = true
        let sourceURL = URL(string: "file:\(snapshot.url.path)?mode=ro\(snapshot.immutable ? "&immutable=1" : "")")!
        let source = try DatabaseQueue(path: sourceURL.absoluteString, configuration: configuration)
        let schema = try Self.sourceRead(source) { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        guard schema.contains("EnergyHistory"), schema.contains("SystemBuckets") else {
            throw LegacyImportError.missingLegacyTables
        }

        let bounds = try Self.sourceRead(source) { db -> (Int64, Int64, Int64)? in
            let e = try Row.fetchOne(db, sql: "SELECT MIN(timestamp) AS lo, MAX(timestamp) AS hi FROM EnergyHistory")!
            let b = try Row.fetchOne(db, sql: "SELECT MIN(timestamp) AS lo, MAX(timestamp) AS hi FROM SystemBuckets")!
            let lows = [e["lo"] as Int64?, b["lo"] as Int64?].compactMap { $0 }
            let highs = [e["hi"] as Int64?, b["hi"] as Int64?].compactMap { $0 }
            guard let lo = lows.min(), let hi = highs.max() else { return nil }
            return (lo / 3_600_000, hi / 3_600_000, hi)
        }
        guard let (minHour, maxHour, latestTimestamp) = bounds else { throw LegacyImportError.emptyLegacyEnergyHistory }
        let totalHours = maxHour - minHour + 1
        let savedState = try await meta("legacy.state")
        if savedState == LegacyImportState.done.rawValue { return }
        let savedAnchor = try await meta("legacy.windowAnchor").flatMap(Int64.init)
        let anchor = savedAnchor ?? min(latestTimestamp, Int64(now().timeIntervalSince1970 * 1000))
        if savedAnchor == nil { try await setMeta("legacy.windowAnchor", value: String(anchor)) }
        let minuteCutoff = anchor - 30 * 86_400_000
        let rawCutoff = anchor - Int64(rawRetentionDays) * 86_400_000
        if savedState == nil || savedState == LegacyImportState.none.rawValue || savedState == LegacyImportState.failed.rawValue {
            try await setMeta("legacy.state", value: LegacyImportState.pending.rawValue)
        }
        try await setMeta("legacy.state", value: LegacyImportState.importing.rawValue)
        let savedCursorText = try await meta("legacy.cursorHour")
        let savedCursor = savedCursorText.flatMap(Int64.init)
        let startHour = max(minHour, (savedCursor ?? (minHour - 1)) + 1)

        if startHour <= maxHour {
            for hour in startHour...maxHour {
                try Task.checkCancellation()
                let start = hour * 3_600_000
                let end = start + 3_600_000
                try await history.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM AppSampleRaw WHERE metricVersion=0 AND ts >= ? AND ts < ?", arguments: [start, end])
                    try db.execute(sql: "DELETE FROM BucketSampleRaw WHERE metricVersion=0 AND ts >= ? AND ts < ?", arguments: [start, end])
                    try Self.sourceRead(source) { src in
                        try Self.importHour(db, source: src, start: start, end: end, hour: hour,
                                            minuteCutoff: minuteCutoff, rawCutoff: rawCutoff, timebase: self.timebase)
                    }
                    try Self.putMeta(db, key: "legacy.cursorHour", value: String(hour))
                    try Self.putMeta(db, key: "legacy.state", value: LegacyImportState.importing.rawValue)
                    if hour == maxHour { try Self.advanceImportWatermarks(db) }
                }
                progressHandler?(LegacyImportProgress(importedHours: hour - minHour + 1, totalHours: totalHours))
            }
        }
        try Task.checkCancellation()
        try await setMeta("legacy.state", value: LegacyImportState.verifying.rawValue)
        do {
            try await history.dbPool.write { db in
                try Self.copyBatteryAndEvents(source: source, db: db, progress: self.batteryCopyProgress)
            }
            let oldTotals = try Self.sourceRead(source) { src in try Self.readVerificationTotals(src, rawCutoff: rawCutoff) }
            try await history.dbPool.read { dst in try Self.verify(oldTotals, dst) }
            try await history.dbPool.write { db in
                let doneAt = Int64(Date().timeIntervalSince1970 * 1000)
                try Self.putMeta(db, key: "legacy.doneAt", value: String(doneAt))
                try Self.putMeta(db, key: "legacy.deleteAfter", value: String(doneAt + 7 * 86_400_000))
                try Self.putMeta(db, key: "legacy.state", value: LegacyImportState.done.rawValue)
                try db.execute(sql: "DELETE FROM Meta WHERE key = 'legacy.error'")
            }
        } catch {
            if error is CancellationError { throw error }
            try await history.dbPool.write { db in
                try Self.putMeta(db, key: "legacy.state", value: LegacyImportState.failed.rawValue)
                try Self.putMeta(db, key: "legacy.error", value: error.localizedDescription)
            }
            throw error
        }
    }

    private static func importHour(
        _ db: Database,
        source: Database,
        start: Int64,
        end: Int64,
        hour: Int64,
        minuteCutoff: Int64,
        rawCutoff: Int64,
        timebase: LegacyTimebase
    ) throws {
        var appMinutes: [String: (Int64, Int64, Int64, Int64, Int64, Int64, Int64)] = [:]
        var appHours: [String: (Int64, Int64, Int64, Int64, Int64, Int64, Int64)] = [:]
        var appIds: [String: Int64] = [:]
        let appRows = try Row.fetchCursor(source, sql: """
            SELECT timestamp, pid, bundleIdentifier, processName, path, parentPid,
                   cpuUserNs, cpuSystemNs, energyNJ, wakeups, diskReadBytes, diskWriteBytes
            FROM EnergyHistory WHERE timestamp >= ? AND timestamp < ? AND energyNJ > 0
            ORDER BY timestamp, sampleId
            """, arguments: [start, end])
        while let sourceRow = try appRows.next() {
            let row = LegacyAppRow(timestamp: sourceRow["timestamp"], pid: sourceRow["pid"],
                                   bundleIdentifier: sourceRow["bundleIdentifier"], processName: sourceRow["processName"],
                                   path: sourceRow["path"], parentPid: sourceRow["parentPid"], cpuUserNs: sourceRow["cpuUserNs"],
                                   cpuSystemNs: sourceRow["cpuSystemNs"], energyNJ: sourceRow["energyNJ"], wakeups: sourceRow["wakeups"],
                                   diskReadBytes: sourceRow["diskReadBytes"], diskWriteBytes: sourceRow["diskWriteBytes"])
            let timestamp = row.timestamp
            let bundle = row.bundleIdentifier
            let process = row.processName
            let key = bundle ?? process
            let user = row.cpuUserNs
            let system = row.cpuSystemNs
            let sum = user.addingReportingOverflow(system)
            let scaled = sum.partialValue.multipliedReportingOverflow(by: timebase.numer)
            guard !sum.overflow, !scaled.overflow else { throw LegacyImportError.verificationFailed("CPU time overflow for app group \(key).") }
            let cpuNs = scaled.partialValue / timebase.denom
            let energy = row.energyNJ
            let wakeups = row.wakeups
            let diskRead = row.diskReadBytes
            let diskWrite = row.diskWriteBytes
            let minute = timestamp / 60_000
            let appId: Int64
            if let found = appIds[key] { appId = found } else { appId = try upsertApp(db, key: key, bundle: bundle, name: process, path: row.path, ts: timestamp) }
            appIds[key] = appId
            if timestamp >= minuteCutoff {
                try Self.accumulate(&appMinutes, key: "\(minute)|\(key)", values: (energy, cpuNs, wakeups, diskRead, diskWrite))
            }
            try Self.accumulate(&appHours, key: key, values: (energy, cpuNs, wakeups, diskRead, diskWrite))
            if timestamp >= rawCutoff {
                try db.execute(sql: """
                    INSERT INTO AppSampleRaw(ts, appId, pid, parentPid, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes)
                    VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                    """, arguments: [timestamp, appId, row.pid, row.parentPid, energy, cpuNs, wakeups, diskRead, diskWrite])
            }
        }
        // Use aggregated rows per hour/minute, including a deterministic app ID map.
        for (key, totals) in appHours {
            let appId: Int64
            if let found = appIds[key] { appId = found } else { appId = try Self.appID(db, groupKey: key) }
            try db.execute(sql: """
                INSERT OR REPLACE INTO AppUsageHour(hour, appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples)
                VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?)
                """, arguments: [hour, appId, totals.0, totals.1, totals.2, totals.3, totals.4, totals.5])
        }
        for (compound, totals) in appMinutes {
            let parts = compound.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let minute = Int64(parts[0]) else { continue }
            let appId: Int64
            if let found = appIds[parts[1]] { appId = found } else { appId = try Self.appID(db, groupKey: parts[1]) }
            try db.execute(sql: """
                INSERT OR REPLACE INTO AppUsageMinute(minute, appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples)
                VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?)
                """, arguments: [minute, appId, totals.0, totals.1, totals.2, totals.3, totals.4, totals.5])
        }

        var bucketMinutes: [String: Int64] = [:]
        var bucketHours: [String: Int64] = [:]
        let bucketRows = try Row.fetchCursor(source, sql: """
            SELECT timestamp, bucketName, energyNJ FROM SystemBuckets
            WHERE timestamp >= ? AND timestamp < ? AND energyNJ > 0 ORDER BY timestamp, bucketName
            """, arguments: [start, end])
        while let sourceRow = try bucketRows.next() {
            let row = LegacyBucketRow(timestamp: sourceRow["timestamp"], bucketName: sourceRow["bucketName"], energyNJ: sourceRow["energyNJ"])
            let timestamp = row.timestamp
            let name = row.bucketName
            let energy = row.energyNJ
            let bucketId = try upsertBucket(db, name: name)
            try db.execute(sql: "INSERT OR IGNORE INTO BucketHour(hour, bucketId, metricVersion, energyNJ) VALUES (?, ?, 0, ?)", arguments: [hour, bucketId, energy])
            bucketHours[name, default: 0] += energy
            if timestamp >= minuteCutoff { bucketMinutes["\(timestamp / 60_000)|\(name)", default: 0] += energy }
            if timestamp >= rawCutoff {
                try db.execute(sql: "INSERT INTO BucketSampleRaw(ts, bucketId, metricVersion, energyNJ) VALUES (?, ?, 0, ?)", arguments: [timestamp, bucketId, energy])
            }
        }
        for (name, energy) in bucketHours {
            let id = try upsertBucket(db, name: name)
            try db.execute(sql: "INSERT OR REPLACE INTO BucketHour(hour, bucketId, metricVersion, energyNJ) VALUES (?, ?, 0, ?)", arguments: [hour, id, energy])
        }
        for (compound, energy) in bucketMinutes {
            let parts = compound.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let minute = Int64(parts[0]) else { continue }
            let id = try upsertBucket(db, name: parts[1])
            try db.execute(sql: "INSERT OR REPLACE INTO BucketMinute(minute, bucketId, metricVersion, energyNJ) VALUES (?, ?, 0, ?)", arguments: [minute, id, energy])
        }
    }

    private static func advanceImportWatermarks(_ db: Database) throws {
        let minuteTableMax = try Int64.fetchOne(db, sql: "SELECT MAX(minute) FROM AppUsageMinute WHERE metricVersion=0")
        let bucketMinuteMax = try Int64.fetchOne(db, sql: "SELECT MAX(minute) FROM BucketMinute WHERE metricVersion=0")
        let hourTableMax = try Int64.fetchOne(db, sql: "SELECT MAX(hour) FROM AppUsageHour WHERE metricVersion=0")
        let bucketHourMax = try Int64.fetchOne(db, sql: "SELECT MAX(hour) FROM BucketHour WHERE metricVersion=0")
        let minuteCurrent = try watermark(db, key: "rollup.minuteWatermark")
        let hourCurrent = try watermark(db, key: "rollup.hourWatermark")
        let minuteTarget = [minuteCurrent, minuteTableMax, bucketMinuteMax].compactMap { $0 }.max()
        let hourTarget = [hourCurrent, hourTableMax, bucketHourMax].compactMap { $0 }.max()

        if let minuteTarget {
            try foldCurrentRawIntoTiers(db, timeColumn: "minute", divisor: 60_000,
                                        from: minuteCurrent.map { ($0 + 1) * 60_000 } ?? Int64.min,
                                        before: (minuteTarget + 1) * 60_000)
            try putMeta(db, key: "rollup.minuteWatermark", value: String(minuteTarget))
        }
        if let hourTarget {
            try foldCurrentRawIntoTiers(db, timeColumn: "hour", divisor: 3_600_000,
                                        from: hourCurrent.map { ($0 + 1) * 3_600_000 } ?? Int64.min,
                                        before: (hourTarget + 1) * 3_600_000)
            try putMeta(db, key: "rollup.hourWatermark", value: String(hourTarget))
        }
    }

    private static func watermark(_ db: Database, key: String) throws -> Int64? {
        try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key = ?", arguments: [key]).flatMap(Int64.init)
    }

    private static func foldCurrentRawIntoTiers(_ db: Database, timeColumn: String, divisor: Int64, from lowerBound: Int64, before cutoff: Int64) throws {
        let appSQL = """
            INSERT INTO AppUsage\(timeColumn == "hour" ? "Hour" : "Minute")
                (\(timeColumn), appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples)
            SELECT ts / ?, appId, metricVersion, SUM(energyNJ), SUM(cpuNs), SUM(wakeups),
                   SUM(diskReadBytes), SUM(diskWriteBytes), COUNT(*)
            FROM AppSampleRaw WHERE ts >= ? AND ts < ? AND metricVersion=?
            GROUP BY ts / ?, appId, metricVersion
            ON CONFLICT(\(timeColumn), appId, metricVersion) DO UPDATE SET
                energyNJ=energyNJ+excluded.energyNJ, cpuNs=cpuNs+excluded.cpuNs,
                wakeups=wakeups+excluded.wakeups, diskReadBytes=diskReadBytes+excluded.diskReadBytes,
                diskWriteBytes=diskWriteBytes+excluded.diskWriteBytes, samples=samples+excluded.samples
            """
        try db.execute(sql: appSQL, arguments: [divisor, lowerBound, cutoff, EnergyMetric.currentVersion, divisor])

        let bucketSQL = """
            INSERT INTO Bucket\(timeColumn == "hour" ? "Hour" : "Minute")
                (\(timeColumn), bucketId, metricVersion, energyNJ)
            SELECT ts / ?, bucketId, metricVersion, SUM(energyNJ)
            FROM BucketSampleRaw WHERE ts >= ? AND ts < ? AND metricVersion=?
            GROUP BY ts / ?, bucketId, metricVersion
            ON CONFLICT(\(timeColumn), bucketId, metricVersion) DO UPDATE SET energyNJ=energyNJ+excluded.energyNJ
            """
        try db.execute(sql: bucketSQL, arguments: [divisor, lowerBound, cutoff, EnergyMetric.currentVersion, divisor])
    }

    private struct LegacySnapshot {
        let url: URL
        let immutable: Bool
        let cleanup: (() -> Void)?
    }

    private static func prepareLegacySnapshot(at source: URL) throws -> LegacySnapshot {
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let walSize = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.intValue ?? 0
        guard walSize > 0 else { return LegacySnapshot(url: source, immutable: true, cleanup: nil) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voltscope-legacy-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for suffix in ["", "-wal", "-shm"] {
                let original = URL(fileURLWithPath: source.path + suffix)
                guard FileManager.default.fileExists(atPath: original.path) else { continue }
                let destination = directory.appendingPathComponent(source.lastPathComponent + suffix)
                let cloned = original.path.withCString { from in
                    destination.path.withCString { to in clonefile(from, to, 0) == 0 }
                }
                if !cloned { try FileManager.default.copyItem(at: original, to: destination) }
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let copied = directory.appendingPathComponent(source.lastPathComponent)
        return LegacySnapshot(url: copied, immutable: false, cleanup: { try? FileManager.default.removeItem(at: directory) })
    }

    private static func accumulate(
        _ target: inout [String: (Int64, Int64, Int64, Int64, Int64, Int64, Int64)],
        key: String,
        values: (Int64, Int64, Int64, Int64, Int64)
    ) throws {
        let old = target[key] ?? (0, 0, 0, 0, 0, 0, 0)
        let n = old.0.addingReportingOverflow(values.0)
        let c = old.1.addingReportingOverflow(values.1)
        let w = old.2.addingReportingOverflow(values.2)
        let r = old.3.addingReportingOverflow(values.3)
        let d = old.4.addingReportingOverflow(values.4)
        let count = old.5.addingReportingOverflow(1)
        guard !n.overflow, !c.overflow, !w.overflow, !r.overflow, !d.overflow, !count.overflow else {
            throw LegacyImportError.verificationFailed("An aggregated legacy value exceeded Int64.")
        }
        target[key] = (n.partialValue, c.partialValue, w.partialValue, r.partialValue, d.partialValue, count.partialValue, 0)
    }

    private static func upsertApp(_ db: Database, key: String, bundle: String?, name: String, path: String?, ts: Int64) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            INSERT INTO App(groupKey, bundleIdentifier, displayName, path, firstSeen, lastSeen) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(groupKey) DO UPDATE SET firstSeen=MIN(firstSeen, excluded.firstSeen), lastSeen=MAX(lastSeen, excluded.lastSeen)
            RETURNING id
            """, arguments: [key, bundle, name, path, ts, ts])!
    }

    private static func appID(_ db: Database, groupKey: String) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT id FROM App WHERE groupKey = ?", arguments: [groupKey])!
    }

    private static func upsertBucket(_ db: Database, name: String) throws -> Int64 {
        try Int64.fetchOne(db, sql: "INSERT INTO Bucket(name) VALUES (?) ON CONFLICT(name) DO UPDATE SET name=excluded.name RETURNING id", arguments: [name])!
    }

    private struct VerificationTotals {
        let apps: [String: Int64]
        let buckets: [String: Int64]
        let batteryCount: Int
        let eventCount: Int
        let rawAppEnergy: Int64
        let rawBucketEnergy: Int64
    }

    private static func readVerificationTotals(_ src: Database, rawCutoff: Int64) throws -> VerificationTotals {
        let oldApps = try Row.fetchAll(src, sql: "SELECT COALESCE(bundleIdentifier, processName) AS groupKey, SUM(energyNJ) AS energy FROM EnergyHistory WHERE energyNJ > 0 GROUP BY 1")
        let oldBuckets = try Row.fetchAll(src, sql: "SELECT bucketName, SUM(energyNJ) AS energy FROM SystemBuckets WHERE energyNJ > 0 GROUP BY bucketName")
        return VerificationTotals(
            apps: Dictionary(uniqueKeysWithValues: oldApps.compactMap { row -> (String, Int64)? in
                guard let key: String = row["groupKey"], let value: Int64 = row["energy"] else { return nil }; return (key, value)
            }),
            buckets: Dictionary(uniqueKeysWithValues: oldBuckets.compactMap { row -> (String, Int64)? in
                guard let key: String = row["bucketName"], let value: Int64 = row["energy"] else { return nil }; return (key, value)
            }),
            batteryCount: try Int.fetchOne(src, sql: "SELECT COUNT(*) FROM BatteryStatus") ?? 0,
            eventCount: try Int.fetchOne(src, sql: "SELECT COUNT(*) FROM PowerEvents") ?? 0,
            rawAppEnergy: try Int64.fetchOne(src, sql: "SELECT COALESCE(SUM(energyNJ), 0) FROM EnergyHistory WHERE energyNJ > 0 AND timestamp >= ?", arguments: [rawCutoff]) ?? 0,
            rawBucketEnergy: try Int64.fetchOne(src, sql: "SELECT COALESCE(SUM(energyNJ), 0) FROM SystemBuckets WHERE energyNJ > 0 AND timestamp >= ?", arguments: [rawCutoff]) ?? 0
        )
    }

    private static func verify(_ oldTotals: VerificationTotals, _ dst: Database) throws {
        let newApps = try Row.fetchAll(dst, sql: "SELECT a.groupKey, SUM(h.energyNJ) AS energy FROM AppUsageHour h JOIN App a ON a.id=h.appId WHERE h.metricVersion=0 GROUP BY a.groupKey")
        let newAppTotals = Dictionary(uniqueKeysWithValues: newApps.compactMap { row -> (String, Int64)? in
            guard let key: String = row["groupKey"], let value: Int64 = row["energy"] else { return nil }; return (key, value)
        })
        if oldTotals.apps != newAppTotals { throw LegacyImportError.verificationFailed("Per-app metricVersion 0 hour totals do not match the legacy database.") }
        let newBuckets = try Row.fetchAll(dst, sql: "SELECT b.name, SUM(h.energyNJ) AS energy FROM BucketHour h JOIN Bucket b ON b.id=h.bucketId WHERE h.metricVersion=0 GROUP BY b.name")
        let newBucketTotals = Dictionary(uniqueKeysWithValues: newBuckets.compactMap { row -> (String, Int64)? in
            guard let key: String = row["name"], let value: Int64 = row["energy"] else { return nil }; return (key, value)
        })
        if oldTotals.buckets != newBucketTotals { throw LegacyImportError.verificationFailed("Per-bucket metricVersion 0 hour totals do not match the legacy database.") }
        let batteryOld = oldTotals.batteryCount
        let batteryNew = try Int.fetchOne(dst, sql: "SELECT COUNT(*) FROM BatteryStatus") ?? 0
        if batteryOld != batteryNew { throw LegacyImportError.verificationFailed("Battery row count differs (legacy \(batteryOld), new \(batteryNew)).") }
        let eventNew = try Int.fetchOne(dst, sql: "SELECT COUNT(*) FROM PowerEvents") ?? 0
        if oldTotals.eventCount != eventNew { throw LegacyImportError.verificationFailed("Power event row count differs (legacy \(oldTotals.eventCount), new \(eventNew)).") }
        let appRaw = try Int64.fetchOne(dst, sql: "SELECT COALESCE(SUM(energyNJ), 0) FROM AppSampleRaw WHERE metricVersion=0") ?? 0
        let bucketRaw = try Int64.fetchOne(dst, sql: "SELECT COALESCE(SUM(energyNJ), 0) FROM BucketSampleRaw WHERE metricVersion=0") ?? 0
        if oldTotals.rawAppEnergy != appRaw || oldTotals.rawBucketEnergy != bucketRaw {
            throw LegacyImportError.verificationFailed("Raw metricVersion 0 energy totals do not match the legacy retention window.")
        }
    }

    private static func copyBatteryAndEvents(source: DatabaseQueue, db: Database, progress: (@Sendable (Int) -> Void)?) throws {
        try source.read { src in
            let batteries = try Row.fetchCursor(src, sql: "SELECT * FROM BatteryStatus ORDER BY timestamp")
            var copiedBatteries = 0
            while let row = try batteries.next() {
                try Task.checkCancellation()
                let timestamp: Int64 = row["timestamp"]
                if let existing = try Row.fetchOne(db, sql: "SELECT * FROM BatteryStatus WHERE timestamp = ?", arguments: [timestamp]) {
                    let equal = (existing["levelPercent"] as Double?) == (row["levelPercent"] as Double?)
                        && (existing["capacityMAh"] as Int?) == (row["capacityMAh"] as Int?)
                        && (existing["designMAh"] as Int?) == (row["designMAh"] as Int?)
                        && (existing["cycleCount"] as Int?) == (row["cycleCount"] as Int?)
                        && (existing["voltageMV"] as Int?) == (row["voltageMV"] as Int?)
                        && (existing["amperageMA"] as Int?) == (row["amperageMA"] as Int?)
                        && (existing["temperatureC"] as Double?) == (row["temperatureC"] as Double?)
                        && (existing["timeRemainingMin"] as Int?) == (row["timeRemainingMin"] as Int?)
                        && (existing["isCharging"] as Bool) == (row["isCharging"] as Bool)
                        && (existing["isACPlugged"] as Bool) == (row["isACPlugged"] as Bool)
                    guard equal else { throw LegacyImportError.verificationFailed("Battery payload conflicts at timestamp \(timestamp).") }
                }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO BatteryStatus(timestamp, levelPercent, capacityMAh, designMAh, cycleCount, voltageMV, amperageMA, temperatureC, timeRemainingMin, isCharging, isACPlugged)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [timestamp, row["levelPercent"] as Double?, row["capacityMAh"] as Int?, row["designMAh"] as Int?, row["cycleCount"] as Int?, row["voltageMV"] as Int?, row["amperageMA"] as Int?, row["temperatureC"] as Double?, row["timeRemainingMin"] as Int?, row["isCharging"] as Bool, row["isACPlugged"] as Bool])
                copiedBatteries += 1
                progress?(copiedBatteries)
            }
            let events = try Row.fetchCursor(src, sql: "SELECT * FROM PowerEvents ORDER BY timestamp")
            while let row = try events.next() {
                try Task.checkCancellation()
                let timestamp: Int64 = row["timestamp"]
                if let existing = try Row.fetchOne(db, sql: "SELECT * FROM PowerEvents WHERE timestamp = ?", arguments: [timestamp]) {
                    let equal = (existing["eventType"] as String) == (row["eventType"] as String)
                        && (existing["durationSeconds"] as Int?) == (row["durationSeconds"] as Int?)
                        && (existing["metadata"] as String?) == (row["metadata"] as String?)
                    guard equal else { throw LegacyImportError.verificationFailed("Power event payload conflicts at timestamp \(timestamp).") }
                }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO PowerEvents(timestamp, eventType, durationSeconds, metadata)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [timestamp, row["eventType"] as String, row["durationSeconds"] as Int?, row["metadata"] as String?])
            }
        }
    }

    private func meta(_ key: String) async throws -> String? {
        try await history.dbPool.read { db in try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key = ?", arguments: [key]) }
    }

    private func setMeta(_ key: String, value: String) async throws {
        try await history.dbPool.write { db in try Self.putMeta(db, key: key, value: value) }
    }

    private static func putMeta(_ db: Database, key: String, value: String) throws {
        try db.execute(sql: "INSERT INTO Meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [key, value])
    }

    private static func sourceRead<T>(_ source: DatabaseQueue, _ body: (Database) throws -> T) throws -> T {
        try source.read(body)
    }
}

/// Guarded legacy file lifecycle operations.
public extension HistoryDatabase {
    func deleteLegacyDatabaseImmediately(at legacyURL: URL) async throws {
        try await deleteLegacyDatabase(at: legacyURL, requireExpiry: false)
    }

    func deleteLegacyDatabaseIfExpired(at legacyURL: URL, now: Date = Date()) async throws -> Bool {
        guard let deleteAfter = try await dbPool.read({ db in try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key='legacy.deleteAfter'") }) else {
            return false
        }
        guard Int64(now.timeIntervalSince1970 * 1000) >= deleteAfter else { return false }
        try await deleteLegacyDatabase(at: legacyURL, requireExpiry: true, now: now)
        return true
    }

    private func deleteLegacyDatabase(at legacyURL: URL, requireExpiry: Bool, now: Date = Date()) async throws {
        let stateValue = try await dbPool.read { db in try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") }
        let state = LegacyImportState(rawValue: stateValue ?? "none") ?? .none
        guard state == .done else { throw LegacyImportError.deletionNotAllowed(state) }
        if requireExpiry {
            let expiry = try await dbPool.read { db in try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key='legacy.deleteAfter'") }
            guard let expiry, Int64(now.timeIntervalSince1970 * 1000) >= expiry else { return }
        }
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: legacyURL.path + suffix)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
    }
}
