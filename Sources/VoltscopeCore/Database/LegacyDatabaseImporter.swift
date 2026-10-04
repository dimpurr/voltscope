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

private struct LegacyRawAppKey: Hashable {
    let window: Int64
    let appID: Int64
    let pid: Int32
}

private struct LegacyRawAppValue {
    let parentPID: Int32?
    var energy: Int64
    var cpu: Int64
    var wakeups: Int64
    var diskRead: Int64
    var diskWrite: Int64
}

private struct LegacyRawBucketKey: Hashable {
    let window: Int64
    let name: String
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
    private let monotonicNow: @Sendable () -> TimeInterval

    public convenience init(
        history: HistoryDatabase,
        legacyURL: URL,
        timebase: LegacyTimebase = .system,
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: (@Sendable () -> TimeInterval)? = nil,
        rawRetentionDays: Int = 7,
        progress: (@Sendable (LegacyImportProgress) -> Void)? = nil
    ) {
        self.init(history: history, legacyURL: legacyURL, timebase: timebase, now: now,
                  monotonicNow: monotonicNow,
                  rawRetentionDays: rawRetentionDays, progress: progress, batteryCopyProgress: nil)
    }

    init(
        history: HistoryDatabase,
        legacyURL: URL,
        timebase: LegacyTimebase = .system,
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: (@Sendable () -> TimeInterval)? = nil,
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
        self.monotonicNow = monotonicNow ?? continuousClockSeconds
    }

    /// Starts import work independently of the caller's executor.
    @discardableResult
    public func start() -> Task<Void, Error> {
        Task.detached(priority: .utility) { try await self.run() }
    }

    /// Returns whether a completed import's source revision changed after its
    /// completion marker was committed.
    func completedSourceRevisionChanged() async throws -> Bool {
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return false }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5.0)
        let source = try DatabaseQueue(path: legacyURL.path, configuration: configuration)
        let current = try Self.readSourceRevision(source)
        let savedDataVersion = try await history.dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key='legacy.sourceRevision.dataVersion'")
        }
        let savedCounts = try await history.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.sourceRevision.rowCounts'")
        }
        return savedDataVersion != current.dataVersion
            || savedCounts != current.rowCounts.map(String.init).joined(separator: ",")
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

    /// A legacy database that is still being written can keep producing new
    /// commits. The importer re-reads `MAX(timestamp)` before completing and
    /// imports anything newer, up to this many passes. If commits keep
    /// arriving past the budget it leaves `verifying` so the next launch
    /// retries; it never marks an incomplete import `done`.
    private static let maximumConvergenceRounds = 10

    private struct LegacyBounds {
        let minHour: Int64
        let maxHour: Int64
        let latestTimestamp: Int64
    }

    private struct LegacySourceRevision: Equatable {
        let dataVersion: Int64
        let rowCounts: [Int64]
    }

    private func performRun() async throws {
        var wasDone = false
        do {
            guard timebase.numer > 0, timebase.denom > 0 else { throw LegacyImportError.invalidTimebase }
            let savedState = try await meta("legacy.state")
            wasDone = savedState == LegacyImportState.done.rawValue
            // The source is intentionally retained only until the user removes
            // it or the retention deadline passes. A completed import remains
            // complete when that file has already been removed.
            if savedState == LegacyImportState.done.rawValue,
               !FileManager.default.fileExists(atPath: legacyURL.path) { return }
            guard FileManager.default.fileExists(atPath: legacyURL.path) else { throw CocoaError(.fileNoSuchFile) }

            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(5.0)
            let source = try DatabaseQueue(path: legacyURL.path, configuration: configuration)
            let schema = try Self.sourceRead(source) { db in
                Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            }
            guard schema.contains("EnergyHistory"), schema.contains("SystemBuckets") else {
                throw LegacyImportError.missingLegacyTables
            }
            guard let initialBounds = try Self.readBounds(source) else {
                throw LegacyImportError.emptyLegacyEnergyHistory
            }
            if savedState == LegacyImportState.done.rawValue {
                let currentRevision = try Self.readSourceRevision(source)
                let savedDataVersion = try await meta("legacy.sourceRevision.dataVersion").flatMap(Int64.init)
                let savedCounts = try await meta("legacy.sourceRevision.rowCounts")
                let currentCounts = currentRevision.rowCounts.map(String.init).joined(separator: ",")
                if savedDataVersion == currentRevision.dataVersion, savedCounts == currentCounts {
                    try await verifyCompletedImport(source: source, bounds: initialBounds)
                    return
                }
                // A source commit can land after the final convergence check
                // but before the destination done marker. Reopen the import
                // and rescan from the first source hour on the next entry.
                try await history.dbPool.write { db in
                    try Self.putMeta(db, key: "legacy.state", value: LegacyImportState.importing.rawValue)
                    try db.execute(sql: "DELETE FROM Meta WHERE key IN ('legacy.doneAt', 'legacy.deleteAfter', 'legacy.verifiedAt')")
                    try Self.putMeta(db, key: "legacy.cursorHour", value: String(initialBounds.minHour - 1))
                }
                wasDone = false
            }
            if savedState == nil || savedState == LegacyImportState.none.rawValue || savedState == LegacyImportState.failed.rawValue {
                try await setMeta("legacy.state", value: LegacyImportState.pending.rawValue)
            }
            let savedAnchor = try await meta("legacy.windowAnchor").flatMap(Int64.init)

            try await importUntilConverged(source: source, initialBounds: initialBounds, savedAnchor: savedAnchor)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if wasDone {
                guard let importError = error as? LegacyImportError,
                      case .verificationFailed = importError else {
                    throw error
                }
                try await history.dbPool.write { db in
                    try Self.putMeta(db, key: "legacy.state", value: LegacyImportState.failed.rawValue)
                    try Self.putMeta(db, key: "legacy.error", value: error.localizedDescription)
                    try db.execute(sql: "DELETE FROM Meta WHERE key IN ('legacy.doneAt', 'legacy.deleteAfter', 'legacy.cursorHour', 'legacy.verifiedAt')")
                }
                throw error
            }
            try await history.dbPool.write { db in
                try Self.putMeta(db, key: "legacy.state", value: LegacyImportState.failed.rawValue)
                try Self.putMeta(db, key: "legacy.error", value: error.localizedDescription)
                try db.execute(sql: "DELETE FROM Meta WHERE key IN ('legacy.doneAt', 'legacy.deleteAfter')")
            }
            throw error
        }
    }

    /// Recheck a completed import before the retained source is deleted.
    /// The raw tier is compared only inside its current retention window;
    /// permanent hourly totals and copied sampler row counts are checked in
    /// full by the shared verifier.
    private func verifyCompletedImport(source: DatabaseQueue, bounds: LegacyBounds) async throws {
        let anchor = try await meta("legacy.windowAnchor").flatMap(Int64.init) ?? bounds.latestTimestamp
        let storedCutoff = try await meta("legacy.rawCutoff").flatMap(Int64.init)
        let anchoredCutoff = Self.windowStart(anchor - Int64(rawRetentionDays) * 86_400_000)
        let safeNowMS = try await history.safeNow(now: now(), monotonicNow: monotonicNow(),
                                                  fallbackLatestHistoryMS: bounds.latestTimestamp)
        let currentCutoff = Self.windowStart(safeNowMS - Int64(rawRetentionDays) * 86_400_000)
        let rawCutoff = max(storedCutoff ?? anchoredCutoff, currentCutoff)
        let upperBound = bounds.latestTimestamp &+ 1
        let totals = try Self.sourceRead(source) { src in
            try Self.readVerificationTotals(src, rawCutoff: rawCutoff, upperBound: upperBound)
        }
        try await history.dbPool.read { dst in
            // Older completed imports did not persist the raw cutoff, so the
            // original retention window cannot be reconstructed reliably.
            // Their permanent summaries remain verifiable; skip raw-tier
            // comparison rather than comparing against a newer retention setting.
            try Self.verify(totals, rawCutoff: rawCutoff, upperBound: upperBound,
                            checkRaw: storedCutoff != nil, dst)
        }
    }

    /// Imports in ascending hour order, then verifies against the same
    /// snapshot. If the legacy database gained commits during a pass it
    /// imports and verifies again, until one pass observes no newer
    /// timestamp or the round budget is spent.
    private func importUntilConverged(source: DatabaseQueue, initialBounds: LegacyBounds, savedAnchor: Int64?) async throws {
        var anchor = savedAnchor
        var bounds = initialBounds
        var round = 0
        while true {
            try Task.checkCancellation()
            round += 1
            let sourceRevision = try Self.readSourceRevision(source)
            if anchor == nil {
                anchor = min(bounds.latestTimestamp, Int64(now().timeIntervalSince1970 * 1000))
                try await setMeta("legacy.windowAnchor", value: String(anchor!))
            }
            let minuteCutoff = (anchor! - 2 * 86_400_000) / 60_000 * 60_000
            let anchoredRawCutoff = Self.windowStart(anchor! - Int64(rawRetentionDays) * 86_400_000)
            let safeNowMS = try await history.safeNow(now: now(), monotonicNow: monotonicNow(),
                                                      fallbackLatestHistoryMS: bounds.latestTimestamp)
            let maintenanceRawCutoff = Self.windowStart(safeNowMS - Int64(rawRetentionDays) * 86_400_000)
            let rawCutoff = max(anchoredRawCutoff, maintenanceRawCutoff)
            // Every source read for this pass is bounded by the snapshot so
            // the destination can be verified against exactly what was read.
            let snapshotUpper = bounds.latestTimestamp &+ 1

            try await setMeta("legacy.state", value: LegacyImportState.importing.rawValue)
            let savedCursorText = try await meta("legacy.cursorHour")
            let savedCursor = savedCursorText.flatMap(Int64.init)
            let startHour = max(bounds.minHour, (savedCursor ?? (bounds.minHour - 1)) + 1)
            // The still-open boundary hour is re-read on the next pass. Storing
            // its cursor as `hour - 1` in the same transaction as its rows
            // means an interruption can never leave the cursor pointing at or
            // past it, so a resume always re-reads the open hour.
            let boundaryCursor = bounds.maxHour - 1
            if startHour <= bounds.maxHour {
                for hour in startHour...bounds.maxHour {
                    try Task.checkCancellation()
                    let start = hour * 3_600_000
                    let end = start + 3_600_000
                    let cursorHour = hour == bounds.maxHour ? boundaryCursor : hour
                    try await history.dbPool.write { db in
                        try db.execute(sql: "DELETE FROM AppSampleRaw WHERE metricVersion=0 AND ts >= ? AND ts < ?", arguments: [start, end])
                        try db.execute(sql: "DELETE FROM BucketSampleRaw WHERE metricVersion=0 AND ts >= ? AND ts < ?", arguments: [start, end])
                        try Self.sourceRead(source) { src in
                            try Self.importHour(db, source: src, start: start, end: end, hour: hour,
                                                snapshotUpper: snapshotUpper,
                                                minuteCutoff: minuteCutoff, rawCutoff: rawCutoff, timebase: self.timebase)
                        }
                        try Self.putMeta(db, key: "legacy.cursorHour", value: String(cursorHour))
                        try Self.putMeta(db, key: "legacy.state", value: LegacyImportState.importing.rawValue)
                    }
                    progressHandler?(LegacyImportProgress(importedHours: hour - bounds.minHour + 1,
                                                          totalHours: bounds.maxHour - bounds.minHour + 1))
                }
                try await history.dbPool.write { db in
                    try Self.writeLegacyMarks(db)
                    try Self.putMeta(db, key: "legacy.cursorHour", value: String(boundaryCursor))
                }
            } else {
                try await history.dbPool.write { db in try Self.writeLegacyMarks(db) }
            }

            try Task.checkCancellation()
            try await setMeta("legacy.state", value: LegacyImportState.verifying.rawValue)
            try await history.dbPool.write { db in
                try Self.copyBatteryAndEvents(source: source, db: db, upperBound: snapshotUpper, progress: self.batteryCopyProgress)
            }
            let verificationSafeNowMS = try await history.safeNow(
                now: now(), monotonicNow: monotonicNow(), fallbackLatestHistoryMS: bounds.latestTimestamp)
            let verificationRawCutoff = max(anchoredRawCutoff, Self.windowStart(
                verificationSafeNowMS - Int64(rawRetentionDays) * 86_400_000))
            let oldTotals = try Self.sourceRead(source) { src in
                try Self.readVerificationTotals(src, rawCutoff: verificationRawCutoff, upperBound: snapshotUpper)
            }
            do {
                try await history.dbPool.read { dst in
                    try Self.verify(oldTotals, rawCutoff: verificationRawCutoff, upperBound: snapshotUpper, dst)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if try Self.readSourceRevision(source) != sourceRevision {
                    bounds = try Self.readBounds(source) ?? bounds
                    try await setMeta("legacy.cursorHour", value: String(bounds.minHour - 1))
                    guard round < Self.maximumConvergenceRounds else { return }
                    continue
                }
                // Record the same boundary cursor before the outer handler
                // stores `failed`, so a retry re-reads the open hour rather
                // than skipping it past a possibly stale snapshot.
                try await history.dbPool.write { db in
                    try Self.putMeta(db, key: "legacy.cursorHour", value: String(boundaryCursor))
                }
                throw error
            }

            guard let refreshed = try await refreshedBoundsOrFinish(source: source, bounds: bounds, round: round,
                                                                     rawCutoff: verificationRawCutoff,
                                                                     sourceRevision: sourceRevision) else { return }
            bounds = refreshed
        }
    }

    private func refreshedBoundsOrFinish(source: DatabaseQueue, bounds: LegacyBounds, round: Int,
                                         rawCutoff: Int64, sourceRevision: LegacySourceRevision) async throws -> LegacyBounds? {
        let newest = try Self.readLatestTimestamp(source)
        let revisionUnchanged = try Self.readSourceRevision(source) == sourceRevision
        if (newest == nil || newest! <= bounds.latestTimestamp), revisionUnchanged {
            let doneAt = try await history.safeNow(now: now(), monotonicNow: monotonicNow(),
                                                   fallbackLatestHistoryMS: bounds.latestTimestamp)
            try await history.dbPool.write { db in
                try Self.putMeta(db, key: "legacy.rawCutoff", value: String(rawCutoff))
                try Self.putMeta(db, key: "legacy.doneAt", value: String(doneAt))
                try Self.putMeta(db, key: "legacy.deleteAfter", value: String(doneAt + 7 * 86_400_000))
                try Self.putMeta(db, key: "legacy.sourceRevision.dataVersion", value: String(sourceRevision.dataVersion))
                try Self.putMeta(db, key: "legacy.sourceRevision.rowCounts",
                                 value: sourceRevision.rowCounts.map(String.init).joined(separator: ","))
                try Self.putMeta(db, key: "legacy.state", value: LegacyImportState.done.rawValue)
                try db.execute(sql: "DELETE FROM Meta WHERE key = 'legacy.error'")
            }
            return nil
        }

        guard round < Self.maximumConvergenceRounds else { return nil }
        guard let refreshed = try Self.readBounds(source) else {
            throw LegacyImportError.emptyLegacyEnergyHistory
        }
        if !revisionUnchanged {
            try await setMeta("legacy.cursorHour", value: String(refreshed.minHour - 1))
        }
        return refreshed
    }

    /// `MAX(timestamp)` misses commits inserted after a clock rollback. SQLite's
    /// data_version changes when another connection commits, while table row
    /// counts also catch rows committed through this connection.
    private static func readSourceRevision(_ source: DatabaseQueue) throws -> LegacySourceRevision {
        try sourceRead(source) { db in
            let dataVersion = try Int64.fetchOne(db, sql: "PRAGMA data_version") ?? 0
            let tables = ["EnergyHistory", "SystemBuckets", "BatteryStatus", "PowerEvents"]
            let counts = try tables.map { table in
                try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return LegacySourceRevision(dataVersion: dataVersion, rowCounts: counts)
        }
    }

    private static func readBounds(_ source: DatabaseQueue) throws -> LegacyBounds? {
        try sourceRead(source) { db -> LegacyBounds? in
            let e = try Row.fetchOne(db, sql: "SELECT MIN(timestamp) AS lo, MAX(timestamp) AS hi FROM EnergyHistory")!
            let b = try Row.fetchOne(db, sql: "SELECT MIN(timestamp) AS lo, MAX(timestamp) AS hi FROM SystemBuckets")!
            let lows = [e["lo"] as Int64?, b["lo"] as Int64?].compactMap { $0 }
            let highs = [e["hi"] as Int64?, b["hi"] as Int64?].compactMap { $0 }
            guard let lo = lows.min(), let hi = highs.max() else { return nil }
            // The hourly loop walks energy records, but the snapshot bound and
            // the convergence check must also cover battery rows and power
            // events: those are copied outside the loop on their own clocks, so
            // a later one would otherwise be left behind and never verified.
            let newest = try latestTimestamp(db) ?? hi
            return LegacyBounds(minHour: lo / 3_600_000, maxHour: hi / 3_600_000, latestTimestamp: newest)
        }
    }

    private static func windowStart(_ timestamp: Int64) -> Int64 { timestamp / 30_000 * 30_000 }

    private static func readLatestTimestamp(_ source: DatabaseQueue) throws -> Int64? {
        try sourceRead(source) { db in try latestTimestamp(db) }
    }

    /// Newest committed timestamp across every imported legacy table.
    private static func latestTimestamp(_ db: Database) throws -> Int64? {
        let app = try Int64.fetchOne(db, sql: "SELECT MAX(timestamp) FROM EnergyHistory")
        let bucket = try Int64.fetchOne(db, sql: "SELECT MAX(timestamp) FROM SystemBuckets")
        let battery = try Int64.fetchOne(db, sql: "SELECT MAX(timestamp) FROM BatteryStatus")
        let event = try Int64.fetchOne(db, sql: "SELECT MAX(timestamp) FROM PowerEvents")
        return [app, bucket, battery, event].compactMap { $0 }.max()
    }

    private static func importHour(
        _ db: Database,
        source: Database,
        start: Int64,
        end: Int64,
        hour: Int64,
        snapshotUpper: Int64,
        minuteCutoff: Int64,
        rawCutoff: Int64,
        timebase: LegacyTimebase
    ) throws {
        var appMinutes: [String: (Int64, Int64, Int64, Int64, Int64, Int64, Int64)] = [:]
        var appHours: [String: (Int64, Int64, Int64, Int64, Int64, Int64, Int64)] = [:]
        var appIds: [String: Int64] = [:]
        var rawApps: [LegacyRawAppKey: LegacyRawAppValue] = [:]
        let appRows = try Row.fetchCursor(source, sql: """
            SELECT timestamp, pid, bundleIdentifier, processName, path, parentPid,
                   cpuUserNs, cpuSystemNs, energyNJ, wakeups, diskReadBytes, diskWriteBytes
            FROM EnergyHistory WHERE timestamp >= ? AND timestamp < ? AND timestamp < ? AND energyNJ > 0
            ORDER BY timestamp, sampleId
            """, arguments: [start, end, snapshotUpper])
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
            // Legacy rows from v0.9.x and earlier store raw mach ticks, so apply the timebase here.
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
                let rawKey = LegacyRawAppKey(window: timestamp / 30_000 * 30_000, appID: appId, pid: row.pid)
                if var value = rawApps[rawKey] {
                    value.energy += energy; value.cpu += cpuNs; value.wakeups += wakeups
                    value.diskRead += diskRead; value.diskWrite += diskWrite
                    rawApps[rawKey] = value
                } else {
                    rawApps[rawKey] = LegacyRawAppValue(parentPID: row.parentPid, energy: energy, cpu: cpuNs,
                                                        wakeups: wakeups, diskRead: diskRead, diskWrite: diskWrite)
                }
            }
        }
        for (key, value) in rawApps {
            try db.execute(sql: """
                INSERT INTO AppSampleRaw(ts, appId, pid, parentPid, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes)
                VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                """, arguments: [key.window, key.appID, key.pid, value.parentPID, value.energy,
                                 value.cpu, value.wakeups, value.diskRead, value.diskWrite])
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
        var rawBuckets: [LegacyRawBucketKey: Int64] = [:]
        let bucketRows = try Row.fetchCursor(source, sql: """
            SELECT timestamp, bucketName, energyNJ FROM SystemBuckets
            WHERE timestamp >= ? AND timestamp < ? AND timestamp < ? AND energyNJ > 0 ORDER BY timestamp, bucketName
            """, arguments: [start, end, snapshotUpper])
        while let sourceRow = try bucketRows.next() {
            let row = LegacyBucketRow(timestamp: sourceRow["timestamp"], bucketName: sourceRow["bucketName"], energyNJ: sourceRow["energyNJ"])
            let timestamp = row.timestamp
            let name = row.bucketName
            let energy = row.energyNJ
            _ = try upsertBucket(db, name: name)
            bucketHours[name, default: 0] += energy
            if timestamp >= minuteCutoff { bucketMinutes["\(timestamp / 60_000)|\(name)", default: 0] += energy }
            if timestamp >= rawCutoff {
                let window = timestamp / 30_000 * 30_000
                rawBuckets[LegacyRawBucketKey(window: window, name: name), default: 0] += energy
            }
        }
        for (key, energy) in rawBuckets {
            let id = try upsertBucket(db, name: key.name)
            try db.execute(sql: "INSERT INTO BucketSampleRaw(ts, bucketId, metricVersion, energyNJ) VALUES (?, ?, 0, ?)", arguments: [key.window, id, energy])
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

    /// Records the newest imported legacy minute and hour. Queries for
    /// `metricVersion == 0` use these as their tail cutoff, separate from the
    /// current version's rollup watermarks.
    private static func writeLegacyMarks(_ db: Database) throws {
        let minuteMax = [
            try Int64.fetchOne(db, sql: "SELECT MAX(minute) FROM AppUsageMinute WHERE metricVersion=0"),
            try Int64.fetchOne(db, sql: "SELECT MAX(minute) FROM BucketMinute WHERE metricVersion=0")
        ].compactMap { $0 }.max()
        let hourMax = [
            try Int64.fetchOne(db, sql: "SELECT MAX(hour) FROM AppUsageHour WHERE metricVersion=0"),
            try Int64.fetchOne(db, sql: "SELECT MAX(hour) FROM BucketHour WHERE metricVersion=0")
        ].compactMap { $0 }.max()
        if let minuteMax { try putMeta(db, key: "legacy.minuteMark", value: String(minuteMax)) }
        if let hourMax { try putMeta(db, key: "legacy.hourMark", value: String(hourMax)) }
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

    private static func readVerificationTotals(_ src: Database, rawCutoff: Int64, upperBound: Int64) throws -> VerificationTotals {
        let oldApps = try Row.fetchAll(src, sql: "SELECT COALESCE(bundleIdentifier, processName) AS groupKey, SUM(energyNJ) AS energy FROM EnergyHistory WHERE energyNJ > 0 AND timestamp < ? GROUP BY 1", arguments: [upperBound])
        let oldBuckets = try Row.fetchAll(src, sql: "SELECT bucketName, SUM(energyNJ) AS energy FROM SystemBuckets WHERE energyNJ > 0 AND timestamp < ? GROUP BY bucketName", arguments: [upperBound])
        return VerificationTotals(
            apps: Dictionary(uniqueKeysWithValues: oldApps.compactMap { row -> (String, Int64)? in
                guard let key: String = row["groupKey"], let value: Int64 = row["energy"] else { return nil }; return (key, value)
            }),
            buckets: Dictionary(uniqueKeysWithValues: oldBuckets.compactMap { row -> (String, Int64)? in
                guard let key: String = row["bucketName"], let value: Int64 = row["energy"] else { return nil }; return (key, value)
            }),
            batteryCount: try Int.fetchOne(src, sql: "SELECT COUNT(*) FROM BatteryStatus WHERE timestamp < ?", arguments: [upperBound]) ?? 0,
            eventCount: try Int.fetchOne(src, sql: "SELECT COUNT(*) FROM PowerEvents WHERE timestamp < ?", arguments: [upperBound]) ?? 0,
            rawAppEnergy: try Int64.fetchOne(src, sql: "SELECT COALESCE(SUM(energyNJ), 0) FROM EnergyHistory WHERE energyNJ > 0 AND timestamp >= ? AND timestamp < ?", arguments: [rawCutoff, upperBound]) ?? 0,
            rawBucketEnergy: try Int64.fetchOne(src, sql: "SELECT COALESCE(SUM(energyNJ), 0) FROM SystemBuckets WHERE energyNJ > 0 AND timestamp >= ? AND timestamp < ?", arguments: [rawCutoff, upperBound]) ?? 0
        )
    }

    private static func verify(_ oldTotals: VerificationTotals, rawCutoff: Int64,
                               upperBound: Int64, checkRaw: Bool = true, _ dst: Database) throws {
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
        let batteryNew = try Int.fetchOne(dst, sql: "SELECT COUNT(*) FROM BatteryStatus WHERE timestamp < ?", arguments: [upperBound]) ?? 0
        if batteryOld != batteryNew { throw LegacyImportError.verificationFailed("Battery row count differs (legacy \(batteryOld), new \(batteryNew)).") }
        let eventNew = try Int.fetchOne(dst, sql: "SELECT COUNT(*) FROM PowerEvents WHERE timestamp < ?", arguments: [upperBound]) ?? 0
        if oldTotals.eventCount != eventNew { throw LegacyImportError.verificationFailed("Power event row count differs (legacy \(oldTotals.eventCount), new \(eventNew)).") }
        if checkRaw {
            let appRaw = try Int64.fetchOne(dst, sql: "SELECT COALESCE(SUM(energyNJ), 0) FROM AppSampleRaw WHERE metricVersion=0 AND ts >= ? AND ts < ?", arguments: [rawCutoff, upperBound]) ?? 0
            let bucketRaw = try Int64.fetchOne(dst, sql: "SELECT COALESCE(SUM(energyNJ), 0) FROM BucketSampleRaw WHERE metricVersion=0 AND ts >= ? AND ts < ?", arguments: [rawCutoff, upperBound]) ?? 0
            if oldTotals.rawAppEnergy != appRaw || oldTotals.rawBucketEnergy != bucketRaw {
                throw LegacyImportError.verificationFailed("Raw metricVersion 0 energy totals do not match the legacy retention window.")
            }
        }
    }

    private static func copyBatteryAndEvents(source: DatabaseQueue, db: Database, upperBound: Int64, progress: (@Sendable (Int) -> Void)?) throws {
        try source.read { src in
            let batteries = try Row.fetchCursor(src, sql: "SELECT * FROM BatteryStatus WHERE timestamp < ? ORDER BY timestamp", arguments: [upperBound])
            var copiedBatteries = 0
            while let row = try batteries.next() {
                try Task.checkCancellation()
                let timestamp: Int64 = row["timestamp"]
                if let existing = try Row.fetchOne(db, sql: "SELECT * FROM BatteryStatus WHERE timestamp = ?", arguments: [timestamp]) {
                    // Compared one column at a time: a single chained expression
                    // exceeds the type checker's time limit on newer Swift compilers.
                    let doublesEqual = ["levelPercent", "temperatureC"].allSatisfy { column in
                        (existing[column] as Double?) == (row[column] as Double?)
                    }
                    let intsEqual = ["capacityMAh", "designMAh", "cycleCount", "voltageMV", "amperageMA", "timeRemainingMin"].allSatisfy { column in
                        (existing[column] as Int?) == (row[column] as Int?)
                    }
                    let boolsEqual = ["isCharging", "isACPlugged"].allSatisfy { column in
                        (existing[column] as Bool) == (row[column] as Bool)
                    }
                    let equal = doublesEqual && intsEqual && boolsEqual
                    guard equal else { throw LegacyImportError.verificationFailed("Battery payload conflicts at timestamp \(timestamp).") }
                }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO BatteryStatus(timestamp, levelPercent, capacityMAh, designMAh, cycleCount, voltageMV, amperageMA, temperatureC, timeRemainingMin, isCharging, isACPlugged)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [timestamp, row["levelPercent"] as Double?, row["capacityMAh"] as Int?, row["designMAh"] as Int?, row["cycleCount"] as Int?, row["voltageMV"] as Int?, row["amperageMA"] as Int?, row["temperatureC"] as Double?, row["timeRemainingMin"] as Int?, row["isCharging"] as Bool, row["isACPlugged"] as Bool])
                copiedBatteries += 1
                progress?(copiedBatteries)
            }
            let events = try Row.fetchCursor(src, sql: "SELECT * FROM PowerEvents WHERE timestamp < ? ORDER BY timestamp", arguments: [upperBound])
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
                    INSERT OR REPLACE INTO PowerEvents(timestamp, eventType, durationSeconds, metadata)
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
    /// Starts migration asynchronously when an unfinished legacy file exists.
    /// The returned task owns the import work; callers can observe progress
    /// without awaiting completion during application startup.
    func startLegacyImportIfNeeded(
        at legacyURL: URL,
        rawRetentionDays: Int = 7,
        progress: (@Sendable (LegacyImportProgress) -> Void)? = nil
    ) async throws -> Task<Void, Error>? {
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return nil }
        let importer = LegacyDatabaseImporter(history: self, legacyURL: legacyURL,
                                              rawRetentionDays: rawRetentionDays, progress: progress)
        if try await importStatus().state == .done,
           ((try? await importer.completedSourceRevisionChanged()) ?? false) != true { return nil }
        return importer.start()
    }

    func deleteLegacyDatabaseImmediately(at legacyURL: URL) async throws {
        try await deleteLegacyDatabase(at: legacyURL, requireExpiry: false)
    }

    func deleteLegacyDatabaseIfExpired(at legacyURL: URL, now: Date = Date(),
                                       monotonicNow: TimeInterval? = nil) async throws -> Bool {
        guard let deleteAfter = try await dbPool.read({ db in try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key='legacy.deleteAfter'") }) else {
            return false
        }
        let safeNowMS = try await safeNow(now: now, monotonicNow: monotonicNow)
        guard safeNowMS >= deleteAfter else { return false }
        // Revalidate while the source still exists. A post-import corruption
        // or destination loss must leave the only recovery copy untouched.
        let state = try await importStatus().state
        let hasCompletionRecord = try await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.doneAt'") != nil
        }
        let hasVerifiedAt = try await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.verifiedAt'") != nil
        }
        if state == .done, hasCompletionRecord, !hasVerifiedAt,
           FileManager.default.fileExists(atPath: legacyURL.path) {
            try await LegacyDatabaseImporter(history: self, legacyURL: legacyURL,
                                             now: { now }, rawRetentionDays: try await rawRetentionDays()).run()
            try await dbPool.write { db in
                try db.execute(sql: "INSERT INTO Meta(key,value) VALUES ('legacy.verifiedAt', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                               arguments: [String(Int64(now.timeIntervalSince1970 * 1000))])
            }
        }
        try await deleteLegacyDatabase(at: legacyURL, requireExpiry: true, now: now,
                                       monotonicNow: monotonicNow)
        return true
    }

    private func deleteLegacyDatabase(at legacyURL: URL, requireExpiry: Bool, now: Date = Date(),
                                      monotonicNow: TimeInterval? = nil) async throws {
        let stateValue = try await dbPool.read { db in try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") }
        let state = LegacyImportState(rawValue: stateValue ?? "none") ?? .none
        guard state == .done else { throw LegacyImportError.deletionNotAllowed(state) }
        if requireExpiry {
            let expiry = try await dbPool.read { db in try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key='legacy.deleteAfter'") }
            let safeNowMS = try await safeNow(now: now, monotonicNow: monotonicNow)
            guard let expiry, safeNowMS >= expiry else { return }
        }
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: legacyURL.path + suffix)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
    }
}
