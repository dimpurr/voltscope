import XCTest
import GRDB
@testable import VoltscopeCore

private final class ImportTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<Void, Error>?
    private var cancelRequested = false

    func set(_ task: Task<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        stored = task
        if cancelRequested { task.cancel() }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelRequested = true
        stored?.cancel()
    }
}

private final class RunOverlapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximum = 0

    func recordOverlap() {
        lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
        Thread.sleep(forTimeInterval: 0.02)
        lock.lock(); active -= 1; lock.unlock()
    }
}

private final class ImportGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func blockFirstCall() {
        lock.lock(); count += 1; let shouldBlock = count == 1; lock.unlock()
        if shouldBlock { entered.signal(); release.wait() }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Returns true only for the first caller.
    func trySet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

private final class ImportTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); value.addTimeInterval(interval); lock.unlock()
    }
}

private final class MaintenanceDuringBatteryCopy: @unchecked Sendable {
    private let history: HistoryDatabase
    private let clock: ImportTestClock
    private let lock = NSLock()
    private var nowCallCount = 0
    private var didScheduleMaintenance = false
    private var maintenanceError: Error?
    private let maintenanceFinished = DispatchGroup()

    init(history: HistoryDatabase, clock: ImportTestClock) {
        self.history = history
        self.clock = clock
    }

    func batteryCopyProgress(_ copied: Int) {
        lock.lock()
        let shouldStart = copied == 1 && !didScheduleMaintenance
        if shouldStart { didScheduleMaintenance = true }
        lock.unlock()
        guard shouldStart else { return }

        clock.advance(by: 3 * 60 * 60)
        maintenanceFinished.enter()
        Task.detached { [history, clock] in
            do {
                try await history.runMaintenance(now: clock.now())
            } catch {
                self.recordMaintenanceError(error)
            }
            self.maintenanceFinished.leave()
        }
    }

    private func recordMaintenanceError(_ error: Error) {
        lock.lock()
        maintenanceError = error
        lock.unlock()
    }

    func nowAfterBatteryCopy() -> Date {
        lock.lock()
        nowCallCount += 1
        let waitForMaintenance = nowCallCount == 3
        lock.unlock()
        if waitForMaintenance { maintenanceFinished.wait() }
        return clock.now()
    }

    func waitForMaintenance() {
        maintenanceFinished.wait()
    }

    func assertVerificationResampled(file: StaticString = #filePath, line: UInt = #line) {
        lock.lock()
        let resampled = nowCallCount >= 3
        lock.unlock()
        XCTAssertTrue(resampled, "verification must resample the clock after battery and event copying", file: file, line: line)
    }

    func assertMaintenanceSucceeded(file: StaticString = #filePath, line: UInt = #line) {
        lock.lock()
        let error = maintenanceError
        lock.unlock()
        XCTAssertNil(error, "maintenance failed: \(String(describing: error))", file: file, line: line)
    }
}

/// Commits positive-energy rows into a legacy WAL database from a separate
/// connection and truncates the WAL after each commit, mimicking an old
/// process that is still running while the import reads the file.
private final class LegacyLateWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: DatabaseQueue
    private let base: Int64
    private var offset: Int64 = 0
    private(set) var inserted = 0
    private(set) var lastError: Error?

    init(writer: DatabaseQueue, base: Int64) {
        self.writer = writer
        self.base = base
    }

    func commitNextHour(energyNJ: Int64) {
        lock.lock()
        offset += 1
        let timestamp = base + offset * 3_600_000
        lock.unlock()
        do {
            try writer.write { db in
                var sample = EnergySample(timestamp: timestamp, pid: 900, bundleIdentifier: "com.test.late",
                                          processName: "Late", path: nil, parentPid: nil, cpuUserNs: 1, cpuSystemNs: 1,
                                          energyNJ: energyNJ, wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0,
                                          year: 2023, month: 11, day: 14, hour: 12, minute: 0)
                try sample.insert(db)
            }
            // A checkpoint must run outside a transaction; a concurrent reader
            // can still block TRUNCATE, which the old process tolerates.
            try? writer.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            lock.lock(); inserted += 1; lock.unlock()
        } catch {
            lock.lock(); lastError = error; lock.unlock()
        }
    }
}

private struct ImportTotals {
    let appEnergy: Int64
    let bucketEnergy: Int64
    let rawCount: Int
    let minuteCount: Int
    let batteryCount: Int
    let eventCount: Int
    let cpuNs: Int64
    let state: String
}

private struct BenchmarkStats {
    let state: String
    let appHours: Int64
    let bucketHours: Int64
    let batteries: Int64
    let error: String
}

final class LegacyDatabaseImporterTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories.removeAll()
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-import-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func makeLegacy(at url: URL, days: Int = 3) throws {
        let writer = try DatabaseQueue(path: url.path)
        _ = try AppDatabase(dbPool: writer)
        let base = Int64(1_700_000_000_000)
        try writer.write { db in
            for day in 0..<days {
                let timestamp = base + Int64(day) * 86_400_000 + 12 * 3_600_000
                for (i, app) in [("com.test.alpha", "Alpha"), ("com.test.beta", "Beta")].enumerated() {
                    var sample = EnergySample(
                        timestamp: timestamp + Int64(i * 1_000), pid: Int32(20 + i),
                        bundleIdentifier: app.0, processName: app.1, path: "/Applications/\(app.1).app",
                        parentPid: nil, cpuUserNs: 100 + Int64(day), cpuSystemNs: 50,
                        energyNJ: Int64(101 + day + i), wakeups: 3, diskReadBytes: 4, diskWriteBytes: 5,
                        year: 2023, month: 11, day: 14 + day, hour: 12, minute: 0
                    )
                    try sample.insert(db)
                }
                var zero = EnergySample(
                    timestamp: timestamp + 3_000, pid: 99, bundleIdentifier: nil, processName: "Zero",
                    path: nil, parentPid: nil, cpuUserNs: 999, cpuSystemNs: 999, energyNJ: 0,
                    wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0,
                    year: 2023, month: 11, day: 14 + day, hour: 12, minute: 0
                )
                try zero.insert(db)
                try SystemBucket(timestamp: timestamp, bucketName: "cpu", energyNJ: Int64(201 + day)).insert(db)
                try SystemBucket(timestamp: timestamp + 1, bucketName: "gpu", energyNJ: Int64(301 + day)).insert(db)
                try SystemBucket(timestamp: timestamp + 2, bucketName: "cpu", energyNJ: 2).insert(db)
                try BatterySnapshot(timestamp: timestamp, levelPercent: 80, capacityMAh: 4000, designMAh: 5000,
                                    cycleCount: 100, voltageMV: 12000, amperageMA: -500, temperatureC: 30,
                                    timeRemainingMin: 90, isCharging: false, isACPlugged: true).insert(db)
                try PowerEvent(timestamp: timestamp, eventType: .wake, durationSeconds: 2, metadata: "fixture").insert(db)
            }
        }
    }

    private func legacyFixtureNow(days: Int) -> Date {
        let latestTimestamp = Int64(1_700_000_000_000) + Int64(days - 1) * 86_400_000 + 12 * 3_600_000 + 3_000
        return Date(timeIntervalSince1970: Double(latestTimestamp) / 1000)
    }

    private func makeHistory() throws -> HistoryDatabase {
        let db = try HistoryDatabase.makeTemporaryFile()
        if let url = db.fileURL { directories.append(url.deletingLastPathComponent()) }
        return db
    }

    private func makeWALWriter(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5.0)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint=0")
        }
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    func testImportsAppBucketBatteryAndEventRowsWithExactEnergyAndScaledCPU() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 32)
        let history = try makeHistory()
        let fixtureNow = legacyFixtureNow(days: 32)
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 125, denom: 3), now: { fixtureNow }, rawRetentionDays: 7)

        try await importer.start().value

        let totals = try await history.dbPool.read { db -> ImportTotals in
            let appEnergy = try Int64.fetchOne(db, sql: "SELECT SUM(energyNJ) FROM AppUsageHour WHERE metricVersion=0") ?? 0
            let bucketEnergy = try Int64.fetchOne(db, sql: "SELECT SUM(energyNJ) FROM BucketHour WHERE metricVersion=0") ?? 0
            let rawCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0") ?? 0
            let rawWindowsAligned = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0 AND ts % 30000 != 0") ?? 0
            let bucketRawCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM BucketSampleRaw WHERE metricVersion=0") ?? 0
            let minuteCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppUsageMinute WHERE metricVersion=0") ?? 0
            let batteryCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM BatteryStatus") ?? 0
            let eventCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM PowerEvents") ?? 0
            let cpuNs = try Int64.fetchOne(db, sql: "SELECT SUM(cpuNs) FROM AppUsageHour WHERE metricVersion=0") ?? 0
            let state = try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") ?? ""
            XCTAssertEqual(rawWindowsAligned, 0)
            XCTAssertEqual(bucketRawCount, 16, "same-window CPU bucket samples are coalesced, including the boundary window")
            return ImportTotals(appEnergy: appEnergy, bucketEnergy: bucketEnergy, rawCount: rawCount,
                                minuteCount: minuteCount, batteryCount: batteryCount, eventCount: eventCount,
                                cpuNs: cpuNs, state: state)
        }
        XCTAssertEqual(totals.appEnergy, 7_488)
        XCTAssertEqual(totals.bucketEnergy, 17_120)
        XCTAssertEqual(totals.rawCount, 16, "positive-energy app rows in retained windows are kept")
        XCTAssertEqual(totals.minuteCount, 6, "only the final two days of minute rows are retained")
        XCTAssertEqual(totals.batteryCount, 32)
        XCTAssertEqual(totals.eventCount, 32)
        var scaledCPU: Int64 = 0
        // v0.9.x and earlier stored raw mach ticks in cpuUserNs/cpuSystemNs; import applies the timebase once.
        for day in 0..<32 {
            let sampleCPU = (Int64(150) + Int64(day)) * Int64(125) / Int64(3)
            scaledCPU += 2 * sampleCPU
        }
        XCTAssertEqual(totals.cpuNs, scaledCPU)
        XCTAssertEqual(totals.state, "done")
        let deadlines = try await history.dbPool.read { db in
            (
                try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key='legacy.doneAt'") ?? 0,
                try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key='legacy.deleteAfter'") ?? 0
            )
        }
        XCTAssertGreaterThanOrEqual(deadlines.1 - deadlines.0, 7 * 86_400_000 - 10)
        XCTAssertLessThanOrEqual(deadlines.1 - deadlines.0, 7 * 86_400_000 + 10)
        let preserved = try await history.dbPool.read { db in
            (try Double.fetchOne(db, sql: "SELECT levelPercent FROM BatteryStatus WHERE timestamp = 1700043200000"),
             try String.fetchOne(db, sql: "SELECT eventType FROM PowerEvents WHERE timestamp = 1700043200000"))
        }
        XCTAssertEqual(preserved.0, 80)
        XCTAssertEqual(preserved.1, "wake")

        let oneToOne = try makeHistory()
        try await LegacyDatabaseImporter(history: oneToOne, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1)).start().value
        let cpu = try await oneToOne.dbPool.read { db in try Int64.fetchOne(db, sql: "SELECT SUM(cpuNs) FROM AppUsageHour WHERE metricVersion=0") ?? 0 }
        var oneToOneCPU: Int64 = 0
        for day in 0..<32 { oneToOneCPU += 2 * (Int64(150) + Int64(day)) }
        XCTAssertEqual(cpu, oneToOneCPU)
    }

    func testFutureZeroEnergyTimestampUsesPersistedClampedWindowAnchor() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 3)
        let future = Int64(1_700_000_000_000 + 90 * 86_400_000)
        let writer = try DatabaseQueue(path: legacyURL.path)
        try await writer.write { db in try db.execute(sql: "UPDATE EnergyHistory SET timestamp = ? WHERE energyNJ = 0", arguments: [future]) }
        let history = try makeHistory()
        let fixedNow = Date(timeIntervalSince1970: Double(1_700_000_000_000 + 2 * 86_400_000) / 1000)
        let box = ImportTaskBox()
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1), now: { fixedNow }, progress: { progress in
            if progress.importedHours == 1 { box.cancel() }
        })
        let task = importer.start()
        box.set(task)
        do {
            try await task.value
            XCTFail("the fixture should interrupt after the first committed hour")
        } catch is CancellationError {
            // The anchor and first hour are durable before cancellation.
        }

        let values = try await history.dbPool.read { db in
            (try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.windowAnchor'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppUsageMinute WHERE metricVersion=0"))
        }
        XCTAssertEqual(values.0, String(1_700_000_000_000 + 2 * 86_400_000))
        XCTAssertEqual(values.1, 2)
        XCTAssertEqual(values.2, 2)
        let resumedNow = Date(timeIntervalSince1970: Double(1_700_000_000_000 + 100 * 86_400_000) / 1000)
        try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1), now: { resumedNow }).run()
        let anchorAfterResume = try await history.dbPool.read { db in try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.windowAnchor'") }
        XCTAssertEqual(anchorAfterResume, values.0)
        let resumedCounts = try await history.dbPool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppUsageMinute WHERE metricVersion=0"))
        }
        XCTAssertEqual(resumedCounts.0, 2, "rows committed before the retention window moved remain until maintenance prunes them")
        XCTAssertEqual(resumedCounts.1, 6)
    }

    func testConflictingBatteryAndEventPayloadsFailVerification() async throws {
        for conflict in ["battery", "event"] {
            let dir = try directory()
            let legacyURL = dir.appendingPathComponent("db.sqlite")
            try makeLegacy(at: legacyURL, days: 1)
            let history = try makeHistory()
            try await history.dbPool.write { db in
                if conflict == "battery" {
                    try BatterySnapshot(timestamp: 1_700_043_200_000, levelPercent: 12, capacityMAh: nil, designMAh: nil,
                                        cycleCount: nil, voltageMV: nil, amperageMA: nil, temperatureC: nil,
                                        timeRemainingMin: nil, isCharging: false, isACPlugged: false).insert(db)
                } else {
                    try db.execute(sql: "INSERT INTO PowerEvents(timestamp, eventType, durationSeconds, metadata) VALUES (1700043200000, 'sleep', 9, 'different')")
                }
            }
            do {
                try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1)).run()
                XCTFail("a conflicting \(conflict) payload must fail verification")
            } catch let error as LegacyImportError {
                guard case .verificationFailed = error else { return XCTFail("unexpected error: \(error)") }
            }
        }
    }

    func testMatchingSamplerRowsAtLegacyTimestampsAreReplayedFromSnapshot() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        let history = try makeHistory()
        try await history.dbPool.write { db in
            try BatterySnapshot(timestamp: 1_700_043_200_000, levelPercent: 80, capacityMAh: 4000,
                                designMAh: 5000, cycleCount: 100, voltageMV: 12000,
                                amperageMA: -500, temperatureC: 30, timeRemainingMin: 90,
                                isCharging: false, isACPlugged: true).insert(db)
            try PowerEvent(timestamp: 1_700_043_200_000, eventType: .wake,
                           durationSeconds: 2, metadata: "fixture").insert(db)
            try db.execute(sql: "CREATE TABLE CopyAudit(tableName TEXT NOT NULL)")
            try db.execute(sql: """
                CREATE TRIGGER audit_battery_copy AFTER INSERT ON BatteryStatus
                WHEN NEW.timestamp = 1700043200000
                BEGIN INSERT INTO CopyAudit(tableName) VALUES ('BatteryStatus'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER audit_event_copy AFTER INSERT ON PowerEvents
                WHEN NEW.timestamp = 1700043200000
                BEGIN INSERT INTO CopyAudit(tableName) VALUES ('PowerEvents'); END
                """)
        }

        try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                         timebase: LegacyTimebase(numer: 1, denom: 1)).run()

        let result = try await history.dbPool.read { db in
            (
                try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM CopyAudit WHERE tableName='BatteryStatus'"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM CopyAudit WHERE tableName='PowerEvents'")
            )
        }
        XCTAssertEqual(result.0, "done")
        XCTAssertEqual(result.1, 1)
        XCTAssertEqual(result.2, 1)
    }

    func testUnexpectedExtraPowerEventFailsCountVerification() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        let history = try makeHistory()
        try await history.dbPool.write { db in
            try db.execute(sql: "INSERT INTO PowerEvents(timestamp, eventType, durationSeconds, metadata) VALUES (1700043200001, 'plug', NULL, NULL)")
        }
        do {
            try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1)).run()
            XCTFail("an unexpected event row must fail verification")
        } catch let error as LegacyImportError {
            guard case .verificationFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testConcurrentPostSnapshotBatteryAndEventRowsDoNotFailImportAndFailedStateRetries() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 3)
        let history = try makeHistory()
        let lateTimestamp: Int64 = 1_700_000_000_000 + Int64(2) * 86_400_000 + Int64(12) * 3_600_000 + 5_000
        // Model an earlier failed launch. The next run must take the failed -> pending path.
        try await history.dbPool.write { db in
            try db.execute(sql: "INSERT INTO Meta(key, value) VALUES ('legacy.state', 'failed')")
            try db.execute(sql: "INSERT INTO Meta(key, value) VALUES ('legacy.error', 'previous verification failure')")
        }
        let wroteSamplerRows = LockedFlag()
        let samplerWriteFinished = DispatchSemaphore(value: 0)
        let importer = LegacyDatabaseImporter(
            history: history,
            legacyURL: legacyURL,
            timebase: LegacyTimebase(numer: 1, denom: 1),
            progress: { _ in
                guard wroteSamplerRows.trySet() else { return }
                // The source snapshot ends at the final legacy timestamp; these
                // sampler writes happen after that snapshot while import is active,
                // on a separate task and writer transaction.
                Task.detached {
                    defer { samplerWriteFinished.signal() }
                    do {
                        try await history.writeBatterySnapshot(BatterySnapshot(
                            timestamp: lateTimestamp, levelPercent: 79, capacityMAh: 3990,
                            designMAh: 5000, cycleCount: 100, voltageMV: 12000,
                            amperageMA: -400, temperatureC: 30, timeRemainingMin: 90,
                            isCharging: false, isACPlugged: true
                        ))
                        try await history.writePowerEvent(PowerEvent(
                            timestamp: lateTimestamp + 1, eventType: .plug,
                            durationSeconds: nil, metadata: nil
                        ))
                    } catch {
                        // The final row-count assertions fail if either write is missing.
                    }
                }
                samplerWriteFinished.wait()
            }
        )

        try await importer.run()

        let result = try await history.dbPool.read { db in
            (
                try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'"),
                try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.error'"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM BatteryStatus"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM PowerEvents"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM BatteryStatus WHERE timestamp < ?", arguments: [lateTimestamp]),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM PowerEvents WHERE timestamp < ?", arguments: [lateTimestamp])
            )
        }
        XCTAssertTrue(wroteSamplerRows.trySet() == false, "the importer should have written concurrent sampler rows")
        XCTAssertEqual(result.0, "done")
        XCTAssertNil(result.1)
        XCTAssertEqual(result.2, 4)
        XCTAssertEqual(result.3, 4)
        XCTAssertEqual(result.4, 3)
        XCTAssertEqual(result.5, 3)
    }

    func testConcurrentRunsAreSingleFlightAndKeepRawRowsUniqueByReplay() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 8)
        let history = try makeHistory()
        let overlap = RunOverlapRecorder()
        let fixtureNow = legacyFixtureNow(days: 8)
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1), now: { fixtureNow }, progress: { _ in
            overlap.recordOverlap()
        })
        async let first: Void = importer.run()
        async let second: Void = importer.run()
        _ = try await (first, second)

        let counts = try await history.dbPool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM BucketSampleRaw WHERE metricVersion=0") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppUsageHour WHERE metricVersion=0") ?? 0)
        }
        XCTAssertEqual(counts.0, 16)
        XCTAssertEqual(counts.1, 16)
        XCTAssertEqual(counts.2, 16)
        XCTAssertEqual(overlap.maximum, 1, "only one run may be active at a time")
    }

    func testReplayingCommittedHourReplacesRawRowsAndVerifiesRawTotals() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        let history = try makeHistory()
        let fixtureNow = legacyFixtureNow(days: 1)
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1), now: { fixtureNow })
        try await importer.run()
        let cursor = try await history.dbPool.read { db in try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key='legacy.cursorHour'")! }
        try await history.dbPool.write { db in
            try db.execute(sql: "UPDATE Meta SET value=? WHERE key='legacy.cursorHour'", arguments: [String(cursor - 1)])
            try db.execute(sql: "UPDATE Meta SET value='importing' WHERE key='legacy.state'")
        }
        try await importer.run()
        let stateAndRows = try await history.dbPool.read { db in
            (try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0"),
             try Int64.fetchOne(db, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw WHERE metricVersion=0"))
        }
        XCTAssertEqual(stateAndRows.0, "done")
        XCTAssertEqual(stateAndRows.1, 2)
        XCTAssertEqual(stateAndRows.2, 203)
    }

    func testImportedMetricVersionQueriesUseTwoDayMinutesAndPermanentHours() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 32)
        let history = try makeHistory()
        try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1)).run()

        for range in [HistoryRange.h1, .h6, .h24, .d7] {
            let interval = DateInterval(start: Date(timeIntervalSince1970: 1_700_691_200), end: Date(timeIntervalSince1970: 1_702_764_800))
            let rows = try await history.historyEnergy(in: interval, range: range, metricVersion: EnergyMetric.legacyVersion)
            let expected: Int64 = range == .d7 ? 5_808 : 789
            XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.energyNJ }, expected, "legacy totals follow the retained tier for \(range.rawValue)")
        }

        let minuteOnlyInterval = DateInterval(start: Date(timeIntervalSince1970: Double(1_700_000_000_000 + 8 * 86_400_000) / 1000),
                                              end: Date(timeIntervalSince1970: Double(1_700_000_000_000 + 25 * 86_400_000) / 1000))
        let minuteOnly = try await history.historyEnergy(in: minuteOnlyInterval, range: .h1, metricVersion: EnergyMetric.legacyVersion)
        XCTAssertEqual(minuteOnly.reduce(Int64(0)) { $0 + $1.energyNJ }, 0, "minute rows older than two days are intentionally pruned")
        let tiers = try await history.dbPool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0 AND ts < ?", arguments: [1_700_000_000_000 + 25 * 86_400_000]) ?? 0,
             try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.minuteMark'"),
             try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.hourMark'"),
             try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='rollup.minuteWatermark'"),
             try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='rollup.hourWatermark'"))
        }
        XCTAssertEqual(tiers.0, 0, "the 8–25 day interval is outside the raw retention window")
        XCTAssertNotNil(tiers.1)
        XCTAssertNotNil(tiers.2)
        XCTAssertNil(tiers.3, "the importer must not advance the current-version minute watermark")
        XCTAssertNil(tiers.4, "the importer must not advance the current-version hour watermark")
    }

    func testImportConvergesOnCommitsMadeDuringImportWithWALCheckpoint() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 3)
        let walWriter = try makeWALWriter(at: legacyURL)
        let lastFixtureTimestamp: Int64 = 1_700_000_000_000 + 2 * 86_400_000 + 12 * 3_600_000
        let late = LegacyLateWriter(writer: walWriter, base: lastFixtureTimestamp)
        let history = try makeHistory()
        let fired = LockedFlag()
        let fixtureNow = legacyFixtureNow(days: 3)
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                              timebase: LegacyTimebase(numer: 1, denom: 1),
                                              now: { fixtureNow },
                                              progress: { progress in
            guard progress.importedHours == 1, fired.trySet() else { return }
            late.commitNextHour(energyNJ: 1_001)
            late.commitNextHour(energyNJ: 1_002)
            late.commitNextHour(energyNJ: 1_003)
        })
        try await importer.run()

        let totals = try await history.dbPool.read { db -> (Int64, Int, String) in
            let appHours = try Int64.fetchOne(db, sql: "SELECT SUM(energyNJ) FROM AppUsageHour WHERE metricVersion=0") ?? 0
            let rawLate = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0 AND energyNJ >= 1001") ?? 0
            let state = try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") ?? ""
            return (appHours, rawLate, state)
        }
        XCTAssertEqual(totals.2, "done")
        XCTAssertEqual(totals.0, 615 + 3_006, "fixture energy plus every commit made during the import")
        XCTAssertEqual(totals.1, 3, "all commits made during the import must be present")
        XCTAssertNil(late.lastError)
        withExtendedLifetime(walWriter) {}
    }

    func testSustainedCommitsBeyondRoundBudgetStayVerifying() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        let walWriter = try makeWALWriter(at: legacyURL)
        let lastFixtureTimestamp: Int64 = 1_700_000_000_000 + 12 * 3_600_000
        let late = LegacyLateWriter(writer: walWriter, base: lastFixtureTimestamp)
        let history = try makeHistory()
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                              timebase: LegacyTimebase(numer: 1, denom: 1),
                                              progress: { _ in late.commitNextHour(energyNJ: 777) })
        try await importer.run()

        let state = try await history.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'")
        }
        XCTAssertEqual(state, "verifying", "a database that keeps changing must not be marked done")
        XCTAssertGreaterThan(late.inserted, 0)
        XCTAssertNil(late.lastError)
        let doneAt = try await history.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.doneAt'")
        }
        XCTAssertNil(doneAt)

        // Once the writer stops, a later run converges and completes.
        try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                         timebase: LegacyTimebase(numer: 1, denom: 1)).run()
        let resumedState = try await history.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'")
        }
        XCTAssertEqual(resumedState, "done")
        withExtendedLifetime(walWriter) {}
    }

    func testCurrentVersionSamplesWrittenAfterImportRemainVisibleInEveryRange() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        let t0: Int64 = 1_700_000_000_000 + 12 * 3_600_000
        let hourStart = (t0 / 3_600_000) * 3_600_000
        let fixedNow = Date(timeIntervalSince1970: Double(t0 + 10 * 60_000) / 1000)
        let history = try makeHistory()
        try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                         timebase: LegacyTimebase(numer: 1, denom: 1),
                                         now: { fixedNow }).run()

        // Written after the import, in the same hour and before the newest
        // legacy minute. A shared watermark would seal these away.
        try await history.writeTick(timestamp: hourStart + 60_000,
                                    apps: [SampledApp(groupKey: "com.current", bundleIdentifier: "com.current", displayName: "Current", pid: 1, energyNJ: 17, cpuNs: 1)],
                                    buckets: [], coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await history.writeTick(timestamp: hourStart + 120_000,
                                    apps: [SampledApp(groupKey: "com.current", bundleIdentifier: "com.current", displayName: "Current", pid: 1, energyNJ: 23, cpuNs: 1)],
                                    buckets: [], coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await history.flushPendingWindow()

        let interval = DateInterval(start: Date(timeIntervalSince1970: Double(hourStart) / 1000),
                                    end: Date(timeIntervalSince1970: Double(hourStart + 3_600_000) / 1000))
        for range in [HistoryRange.h1, .h6, .h24, .d7] {
            let current = try await history.historyEnergy(in: interval, range: range, metricVersion: EnergyMetric.currentVersion)
            XCTAssertEqual(current.reduce(Int64(0)) { $0 + $1.energyNJ }, 40, "current-version samples written after import for \(range.rawValue)")
            let legacy = try await history.historyEnergy(in: interval, range: range, metricVersion: EnergyMetric.legacyVersion)
            XCTAssertEqual(legacy.reduce(Int64(0)) { $0 + $1.energyNJ }, 203, "legacy total stays single-counted for \(range.rawValue)")
        }
    }

    func testBatteryAndEventRowsNewerThanEnergyOrBucketsAreImported() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 3)
        // Sleeping stamps the event after the last energy tick and the upgrade
        // runs on the next boot, so the battery row and the sleep event are
        // newer than any energy or bucket row. A snapshot bound taken from
        // energy alone would copy and verify only up to that older bound.
        let base: Int64 = 1_700_000_000_000
        let day: Int64 = 86_400_000
        let hour: Int64 = 3_600_000
        let lastEnergyTimestamp = base + 2 * day + 12 * hour + 3_000
        let lateTimestamp = lastEnergyTimestamp + 3 * hour
        let writer = try DatabaseQueue(path: legacyURL.path)
        try await writer.write { db in
            try BatterySnapshot(timestamp: lateTimestamp, levelPercent: 41, capacityMAh: 4_000, designMAh: 5_000,
                                cycleCount: 101, voltageMV: 11_900, amperageMA: -400, temperatureC: 31,
                                timeRemainingMin: 80, isCharging: false, isACPlugged: true).insert(db)
            try PowerEvent(timestamp: lateTimestamp, eventType: .sleep, durationSeconds: 7, metadata: "late").insert(db)
        }
        let history = try makeHistory()
        let startupTask = try await history.startLegacyImportIfNeeded(at: legacyURL, rawRetentionDays: 7)
        XCTAssertNotNil(startupTask)
        try await startupTask?.value

        let result = try await history.dbPool.read { db -> (String, Int, Int, Double?, String?) in
            (
                try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") ?? "",
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM BatteryStatus") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM PowerEvents") ?? 0,
                try Double.fetchOne(db, sql: "SELECT levelPercent FROM BatteryStatus WHERE timestamp = ?", arguments: [lateTimestamp]),
                try String.fetchOne(db, sql: "SELECT eventType FROM PowerEvents WHERE timestamp = ?", arguments: [lateTimestamp])
            )
        }
        XCTAssertEqual(result.0, "done")
        XCTAssertEqual(result.1, 4, "the battery row committed after the last energy tick must be imported")
        XCTAssertEqual(result.2, 4, "the power event committed after the last energy tick must be imported")
        XCTAssertEqual(result.3, 41)
        XCTAssertEqual(result.4, "sleep")
        withExtendedLifetime(writer) {}
    }

    func testMaintenanceKeepsImportedLegacyBoundaryRows() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        let writer = try DatabaseQueue(path: legacyURL.path)
        _ = try AppDatabase(dbPool: writer)
        // The newest commit defines the window anchor. Its offset inside a
        // minute and an hour is nonzero, so the 7-day raw cutoff and the
        // 2-day minute cutoff each fall inside a bucket instead of on its
        // edge. Each boundary bucket then has energy on both sides of the
        // cutoff, which a recompute from the finer tier alone cannot see.
        let anchor: Int64 = 1_700_000_010_000
        let rawCutoff = anchor - 7 * 86_400_000
        let minuteCutoff = anchor - 2 * 86_400_000
        let timestamps = [rawCutoff - 1_000, rawCutoff + 1_000, minuteCutoff - 1_000, minuteCutoff + 1_000, anchor]
        try await writer.write { db in
            for (ts, energy) in zip(timestamps, [5, 7, 11, 13, 17]) {
                try Self.insertEnergy(db, timestamp: ts, energyNJ: Int64(energy))
            }
            for ts in timestamps {
                try SystemBucket(timestamp: ts, bucketName: "cpu", energyNJ: 2).insert(db)
            }
        }
        let history = try makeHistory()
        let now = Date(timeIntervalSince1970: Double(anchor) / 1000)
        try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                         timebase: LegacyTimebase(numer: 1, denom: 1),
                                         now: { now }).start().value

        let before = try await legacyTierEnergy(history)
        XCTAssertEqual(before.appMinutes, 41)
        XCTAssertEqual(before.appHours, 53)
        XCTAssertEqual(before.bucketMinutes, 6)
        XCTAssertEqual(before.bucketHours, 10)

        try await history.runMaintenance(now: now)
        let after = try await legacyTierEnergy(history)
        XCTAssertEqual(after.appMinutes, before.appMinutes, "the 2-day boundary minute must keep its imported total")
        XCTAssertEqual(after.bucketMinutes, before.bucketMinutes, "the 2-day boundary bucket minute must keep its imported total")
        XCTAssertEqual(after.appHours, before.appHours, "the hour tier must keep its imported total")
        XCTAssertEqual(after.bucketHours, before.bucketHours, "the hour tier must keep its imported total")
        withExtendedLifetime(writer) {}
    }

    func testInterruptedBoundaryCursorResumesAndReReadsTheOpenHour() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 2)
        let base: Int64 = 1_700_000_000_000
        let day: Int64 = 86_400_000
        let hour: Int64 = 3_600_000
        let maxTimestamp = base + day + 12 * hour + 3_000
        let boundaryHour = maxTimestamp / hour
        let history = try makeHistory()
        let fixtureNow = legacyFixtureNow(days: 2)
        let box = ImportTaskBox()
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                              timebase: LegacyTimebase(numer: 1, denom: 1),
                                              now: { fixtureNow },
                                              progress: { progress in
            if progress.importedHours == progress.totalHours { box.cancel() }
        })
        let task = importer.start()
        box.set(task)
        do {
            try await task.value
            XCTFail("cancellation after the boundary hour should interrupt the pass")
        } catch is CancellationError {
            // The boundary hour committed its rows and its cursor together.
        }
        let cursor = try await history.dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key='legacy.cursorHour'")
        }
        XCTAssertEqual(cursor, boundaryHour - 1, "the open-hour cursor must be stored as hour - 1 with its rows")

        // A row lands in the still-open hour after the interrupted pass.
        // Resuming must re-read that hour instead of starting past it.
        let newTimestamp = maxTimestamp + 1
        let writer = try DatabaseQueue(path: legacyURL.path)
        try await writer.write { db in
            try Self.insertEnergy(db, timestamp: newTimestamp, energyNJ: 500)
        }
        try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                         timebase: LegacyTimebase(numer: 1, denom: 1),
                                         now: { fixtureNow }).run()
        let result = try await history.dbPool.read { db -> (String, Int64, Int) in
            (
                try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") ?? "",
                try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(energyNJ),0) FROM AppUsageHour WHERE metricVersion=0") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0 AND energyNJ = 500") ?? 0
            )
        }
        XCTAssertEqual(result.0, "done")
        XCTAssertEqual(result.1, 908, "the resumed pass must re-read the open hour and include the new row")
        XCTAssertEqual(result.2, 1)
        withExtendedLifetime(writer) {}
    }

    private struct LegacyTierEnergy {
        let appMinutes: Int64
        let appHours: Int64
        let bucketMinutes: Int64
        let bucketHours: Int64
    }

    private func legacyTierEnergy(_ history: HistoryDatabase) async throws -> LegacyTierEnergy {
        try await history.dbPool.read { db in
            LegacyTierEnergy(
                appMinutes: try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(energyNJ),0) FROM AppUsageMinute WHERE metricVersion=0") ?? 0,
                appHours: try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(energyNJ),0) FROM AppUsageHour WHERE metricVersion=0") ?? 0,
                bucketMinutes: try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(energyNJ),0) FROM BucketMinute WHERE metricVersion=0") ?? 0,
                bucketHours: try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(energyNJ),0) FROM BucketHour WHERE metricVersion=0") ?? 0
            )
        }
    }

    private static func insertEnergy(_ db: Database, timestamp: Int64, energyNJ: Int64) throws {
        var sample = EnergySample(timestamp: timestamp, pid: 700, bundleIdentifier: "com.test.boundary",
                                  processName: "Boundary", path: nil, parentPid: nil,
                                  cpuUserNs: 1, cpuSystemNs: 1, energyNJ: energyNJ,
                                  wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0,
                                  year: 2023, month: 11, day: 14, hour: 12, minute: 0)
        try sample.insert(db)
    }

    func testCancelledWaiterLeavesRunLockQueueAndNeverStartsImport() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 2)
        let history = try makeHistory()
        let gate = ImportGate()
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1), progress: { _ in
            gate.blockFirstCall()
        })
        let holder = Task { try await importer.run() }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        let waiter = Task { try await importer.run() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        gate.release.signal()
        try await holder.value
        do {
            try await waiter.value
            XCTFail("cancelled lock waiter must not start another run")
        } catch is CancellationError {
            // The waiter is removed while the holder continues.
        }
        XCTAssertEqual(gate.calls, 25, "the holder should visit each of the fixture's 25 hours exactly once")
        let state = try await history.dbPool.read { db in try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") }
        XCTAssertEqual(state, "done")
    }

    func testCancellationDuringBatteryCopyDoesNotMarkImportFailedAndResumes() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        let history = try makeHistory()
        let box = ImportTaskBox()
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1), batteryCopyProgress: { copied in
            if copied == 1 { box.cancel() }
        })
        let task = importer.start()
        box.set(task)
        do {
            try await task.value
            XCTFail("cancellation during battery copy should interrupt the transaction")
        } catch is CancellationError {
            // The battery transaction rolls back and the import remains resumable.
        }
        let stateAndBatteryCount = try await history.dbPool.read { db in
            (try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM BatteryStatus") ?? 0)
        }
        XCTAssertEqual(stateAndBatteryCount.0, "verifying")
        XCTAssertEqual(stateAndBatteryCount.1, 0)
        try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1)).run()
        let resumedState = try await history.dbPool.read { db in try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") }
        XCTAssertEqual(resumedState, "done")
    }

    func testCancelledImportResumesAndMatchesUninterruptedResult() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 4)
        let resumed = try makeHistory()
        let box = ImportTaskBox()
        let importer = LegacyDatabaseImporter(history: resumed, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1), progress: { progress in
            if progress.importedHours == 1 { box.cancel() }
        })
        let task = importer.start()
        box.set(task)
        do {
            try await task.value
            XCTFail("cancellation should interrupt after one committed hour")
        } catch is CancellationError {
            // Cursor and first-hour rows committed together.
        }
        let cancelledState = try await resumed.dbPool.read { db in try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") }
        XCTAssertEqual(cancelledState, "importing")

        try await LegacyDatabaseImporter(history: resumed, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1)).start().value
        let complete = try makeHistory()
        try await LegacyDatabaseImporter(history: complete, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1)).start().value
        let resumedRows = try await tierRows(resumed)
        let completeRows = try await tierRows(complete)
        XCTAssertEqual(resumedRows, completeRows)
    }

    func testInterruptedImportResumesAfterMaintenanceAdvancesRawRetentionWindow() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 9)
        let history = try makeHistory()
        let anchorMilliseconds: Int64 = 1_700_000_000_000 + 8 * 86_400_000 + 12 * 3_600_000
        let anchor = Date(timeIntervalSince1970: Double(anchorMilliseconds) / 1000)
        let clock = ImportTestClock(anchor)
        let box = ImportTaskBox()
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                              timebase: LegacyTimebase(numer: 1, denom: 1),
                                              now: { clock.now() }, rawRetentionDays: 7,
                                              progress: { progress in
            if progress.importedHours == progress.totalHours { box.cancel() }
        })
        let task = importer.start()
        box.set(task)
        do {
            try await task.value
            XCTFail("cancellation after all import hours should interrupt before verification completes")
        } catch is CancellationError {
            // All source hours and the resumable cursor have committed.
        }

        clock.advance(by: 3 * 60 * 60)
        try await history.runMaintenance(now: clock.now())
        let retainedAfterMaintenance = try await history.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0") ?? 0
        }
        XCTAssertEqual(retainedAfterMaintenance, 14, "maintenance should prune the source day's raw rows that fell outside the moving cutoff")
        // This is the persisted state produced by the affected candidate when
        // it attempts verification after the retention window has moved.
        try await history.dbPool.write { db in
            try db.execute(sql: "UPDATE Meta SET value='failed' WHERE key='legacy.state'")
            try db.execute(sql: "INSERT INTO Meta(key, value) VALUES ('legacy.error', 'Raw metricVersion 0 energy totals do not match the legacy retention window.') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        }

        try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                         timebase: LegacyTimebase(numer: 1, denom: 1),
                                         now: { clock.now() }, rawRetentionDays: 7).run()
        let result = try await history.dbPool.read { db in
            (try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") ?? "",
             try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.error'"))
        }
        XCTAssertEqual(result.0, "done")
        XCTAssertNil(result.1)
    }

    func testMaintenanceDuringBatteryCopyAdvancesVerificationCutoff() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 9)
        let history = try makeHistory()
        let anchorMilliseconds: Int64 = 1_700_000_000_000 + 8 * 86_400_000 + 12 * 3_600_000
        let clock = ImportTestClock(Date(timeIntervalSince1970: Double(anchorMilliseconds) / 1000))
        let maintenance = MaintenanceDuringBatteryCopy(history: history, clock: clock)
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                              timebase: LegacyTimebase(numer: 1, denom: 1),
                                              now: { maintenance.nowAfterBatteryCopy() }, rawRetentionDays: 7,
                                              batteryCopyProgress: maintenance.batteryCopyProgress)

        try await importer.start().value

        maintenance.waitForMaintenance()
        maintenance.assertMaintenanceSucceeded()
        maintenance.assertVerificationResampled()
        let result = try await history.dbPool.read { db in
            (try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") ?? "",
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0") ?? 0)
        }
        XCTAssertEqual(result.0, "done")
        XCTAssertEqual(result.1, 14, "verification should use the retention cutoff after maintenance advanced the clock")
    }

    func testMissingRawRowStillFailsVerificationInsideCurrentRetentionWindow() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 9)
        let history = try makeHistory()
        let anchorMilliseconds: Int64 = 1_700_000_000_000 + 8 * 86_400_000 + 12 * 3_600_000
        let anchor = Date(timeIntervalSince1970: Double(anchorMilliseconds) / 1000)
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                              timebase: LegacyTimebase(numer: 1, denom: 1),
                                              now: { anchor }, rawRetentionDays: 7)
        try await importer.start().value
        try await history.dbPool.write { db in
            try db.execute(sql: "DELETE FROM AppSampleRaw WHERE metricVersion=0 AND ts=(SELECT MIN(ts) FROM AppSampleRaw WHERE metricVersion=0)")
            try db.execute(sql: "UPDATE Meta SET value='failed' WHERE key='legacy.state'")
        }

        do {
            try await importer.run()
            XCTFail("a missing raw row that remains in the current retention window must fail verification")
        } catch let error as LegacyImportError {
            guard case .verificationFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        let state = try await history.dbPool.read { db in try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") }
        XCTAssertEqual(state, "failed")
    }

    func testRepeatedRunIsIdempotent() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL)
        let history = try makeHistory()
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL, timebase: LegacyTimebase(numer: 1, denom: 1))
        try await importer.start().value
        let first = try await tierRows(history)
        try await importer.start().value
        let second = try await tierRows(history)
        XCTAssertEqual(second, first)
    }

    func testUnexpectedLegacyVersionZeroDataFailsVerification() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL)
        let history = try makeHistory()
        try await history.dbPool.write { db in
            let app = try history.upsertApp(db, groupKey: "unexpected", bundleIdentifier: nil, displayName: "Unexpected", path: nil, ts: 1)
            try db.execute(sql: "INSERT INTO AppUsageHour(hour, appId, metricVersion, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes, samples) VALUES (0, ?, 0, 7, 0, 0, 0, 0, 1)", arguments: [app])
        }
        do {
            try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL).start().value
            XCTFail("an unexpected version-zero app must fail verification")
        } catch let error as LegacyImportError {
            guard case .verificationFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        let state = try await history.dbPool.read { db in try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") }
        XCTAssertEqual(state, "failed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testDeletionRejectsImportingVerifyingAndFailedStatesAndAllowsDone() async throws {
        let history = try makeHistory()
        let dir = try directory()
        let oldFile = dir.appendingPathComponent("db.sqlite")
        try Data([1]).write(to: oldFile)
        try Data([2]).write(to: URL(fileURLWithPath: oldFile.path + "-wal"))
        try Data([3]).write(to: URL(fileURLWithPath: oldFile.path + "-shm"))

        for state in ["importing", "verifying", "failed"] {
            try await history.dbPool.write { db in
                try db.execute(sql: "INSERT INTO Meta(key,value) VALUES ('legacy.state', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [state])
            }
            do {
                try await history.deleteLegacyDatabaseImmediately(at: oldFile)
                XCTFail("deletion should be rejected in \(state)")
            } catch let error as LegacyImportError {
                XCTAssertEqual(error, .deletionNotAllowed(LegacyImportState(rawValue: state)!))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        }
        try await history.dbPool.write { db in
            try db.execute(sql: "INSERT INTO Meta(key,value) VALUES ('legacy.state','done') ON CONFLICT(key) DO UPDATE SET value='done'")
        }
        try await history.deleteLegacyDatabaseImmediately(at: oldFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path + "-shm"))
    }

    func testExpiryEntryPointRequiresDoneAndExpiredDeadline() async throws {
        let history = try makeHistory()
        let dir = try directory()
        let oldFile = dir.appendingPathComponent("db.sqlite")
        try Data([1]).write(to: oldFile)
        try await history.dbPool.write { db in
            try db.execute(sql: "INSERT INTO Meta(key,value) VALUES ('legacy.state','failed')")
            try db.execute(sql: "INSERT INTO Meta(key,value) VALUES ('legacy.deleteAfter','0')")
        }
        do {
            _ = try await history.deleteLegacyDatabaseIfExpired(at: oldFile)
            XCTFail("expired deletion must still require done")
        } catch let error as LegacyImportError {
            XCTAssertEqual(error, .deletionNotAllowed(.failed))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
    }

    func testExpiredEntryPointDeletesAllLegacyFilesAfterDone() async throws {
        let history = try makeHistory()
        let dir = try directory()
        let oldFile = dir.appendingPathComponent("db.sqlite")
        for (suffix, byte) in [("", UInt8(1)), ("-wal", 2), ("-shm", 3)] {
            try Data([byte]).write(to: URL(fileURLWithPath: oldFile.path + suffix))
        }
        try await history.dbPool.write { db in
            try db.execute(sql: "INSERT INTO Meta(key,value) VALUES ('legacy.state','done')")
            try db.execute(sql: "INSERT INTO Meta(key,value) VALUES ('legacy.deleteAfter','0')")
        }
        let deleted = try await history.deleteLegacyDatabaseIfExpired(at: oldFile, now: Date())
        XCTAssertTrue(deleted)
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path + suffix))
        }
    }

    func testTemporaryLegacyLifecycleImportsVerifiesThenDeletesAfterExpiry() async throws {
        let history = try makeHistory()
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                         timebase: LegacyTimebase(numer: 1, denom: 1)).start().value
        let status = try await history.importStatus()
        XCTAssertEqual(status.state, .done)
        XCTAssertNotNil(status.deleteAfter)
        let imported = try await history.dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT SUM(energyNJ) FROM AppUsageHour WHERE metricVersion=0") ?? 0
        }
        XCTAssertGreaterThan(imported, 0)
        let repeatedTask = try await history.startLegacyImportIfNeeded(at: legacyURL)
        XCTAssertNil(repeatedTask, "a verified legacy source is not imported twice")
        try await history.dbPool.write { db in
            try db.execute(sql: "UPDATE Meta SET value='0' WHERE key='legacy.deleteAfter'")
        }
        let deleted = try await history.deleteLegacyDatabaseIfExpired(at: legacyURL, now: Date())
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testMissingLegacyTablesPersistFailureForSettingsAndRetry() async throws {
        let history = try makeHistory()
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        _ = try DatabaseQueue(path: legacyURL.path)

        let started = try await history.startLegacyImportIfNeeded(at: legacyURL)
        let work = try XCTUnwrap(started)
        do {
            try await work.value
            XCTFail("Expected import preflight to fail")
        } catch {
            let status = try await history.importStatus()
            XCTAssertEqual(status.state, .failed)
            XCTAssertTrue(status.error?.isEmpty == false)
        }
        let retryTask = try await history.startLegacyImportIfNeeded(at: legacyURL)
        let retry = try XCTUnwrap(retryTask)
        do { try await retry.value; XCTFail("Expected retry to fail") } catch {}
        let retriedStatus = try await history.importStatus()
        XCTAssertEqual(retriedStatus.state, .failed)
    }

    func testTruncatedAndInvalidPageSourcesFailWithoutSchedulingDeletion() async throws {
        for corruptPage in [false, true] {
            let dir = try directory()
            let legacyURL = dir.appendingPathComponent("db.sqlite")
            try makeLegacy(at: legacyURL, days: 1)
            if corruptPage {
                try Data(repeating: 0xA5, count: 4096).write(to: legacyURL)
            } else {
                let data = try Data(contentsOf: legacyURL)
                try data.prefix(max(32, data.count / 2)).write(to: legacyURL)
            }
            let history = try makeHistory()
            do {
                try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                                 timebase: LegacyTimebase(numer: 1, denom: 1)).run()
                XCTFail("a damaged source must fail preflight or reading")
            } catch { }
            let status = try await history.importStatus()
            XCTAssertEqual(status.state, .failed)
            XCTAssertTrue(status.error?.isEmpty == false)
            XCTAssertNil(status.deleteAfter)
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        }
    }

    func testMissingLegacyColumnPersistsVisibleFailureWithoutDeletionDeadline() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        let writer = try DatabaseQueue(path: legacyURL.path)
        try await writer.write { db in try db.execute(sql: "ALTER TABLE EnergyHistory DROP COLUMN cpuSystemNs") }
        let history = try makeHistory()
        do {
            try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                             timebase: LegacyTimebase(numer: 1, denom: 1)).run()
            XCTFail("a legacy schema missing a required column must fail")
        } catch { }
        let status = try await history.importStatus()
        XCTAssertEqual(status.state, .failed)
        XCTAssertTrue(status.error?.contains("cpuSystemNs") == true)
        XCTAssertNil(status.deleteAfter)
    }

    func testWriteFailureCanResumeAndConvergeWithNewWALRowWithoutDuplicates() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        let history = try makeHistory()
        try await history.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER inject_import_failure BEFORE INSERT ON AppUsageHour
                BEGIN SELECT RAISE(ABORT, 'injected destination write failure'); END
                """)
        }
        do {
            try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                             timebase: LegacyTimebase(numer: 1, denom: 1)).run()
            XCTFail("the injected destination write failure should escape")
        } catch { }
        let failed = try await history.importStatus()
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(failed.error?.contains("injected destination write failure") == true)
        XCTAssertNil(failed.deleteAfter)

        try await history.dbPool.write { db in try db.execute(sql: "DROP TRIGGER inject_import_failure") }
        let writer = try makeWALWriter(at: legacyURL)
        let lateWriter = LegacyLateWriter(writer: writer, base: 1_700_043_200_000)
        let inserted = LockedFlag()
        let fixtureNow = legacyFixtureNow(days: 1)
        let resumed = LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                             timebase: LegacyTimebase(numer: 1, denom: 1),
                                             now: { fixtureNow },
                                             progress: { progress in
            if progress.importedHours == 1 && inserted.trySet() {
                lateWriter.commitNextHour(energyNJ: 1_001)
            }
        })
        try await resumed.run()
        XCTAssertNil(lateWriter.lastError)
        XCTAssertEqual(lateWriter.inserted, 1)
        let result = try await history.dbPool.read { db in
            (try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'"),
             try Int64.fetchOne(db, sql: "SELECT SUM(energyNJ) FROM AppUsageHour WHERE metricVersion=0") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE metricVersion=0") ?? 0,
             try Int64.fetchOne(db, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw WHERE metricVersion=0") ?? 0)
        }
        XCTAssertEqual(result.0, "done")
        XCTAssertEqual(result.1, 1_204)
        XCTAssertEqual(result.2, 3)
        XCTAssertEqual(result.3, 1_204)
    }

    func testReadOnlyDestinationWriteFailureDoesNotMarkDoneOrSetDeletionDeadline() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        let writable = try makeHistory()
        let destinationURL = try XCTUnwrap(writable.fileURL)
        var configuration = Configuration()
        configuration.readonly = true
        let readOnlyPool = try DatabasePool(path: destinationURL.path, configuration: configuration)
        let readOnlyHistory = try HistoryDatabase(dbPool: readOnlyPool, fileURL: destinationURL)
        do {
            try await LegacyDatabaseImporter(history: readOnlyHistory, legacyURL: legacyURL,
                                             timebase: LegacyTimebase(numer: 1, denom: 1)).run()
            XCTFail("a read-only destination must reject import writes")
        } catch { }
        let status = try await readOnlyHistory.importStatus()
        XCTAssertNotEqual(status.state, .done)
        XCTAssertNil(status.deleteAfter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testCompletedImportStaysDoneWhenUserAlreadyRemovedLegacySource() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        let history = try makeHistory()
        let importer = LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                               timebase: LegacyTimebase(numer: 1, denom: 1))
        try await importer.run()
        try FileManager.default.removeItem(at: legacyURL)
        try await importer.run()
        let status = try await history.importStatus()
        XCTAssertEqual(status.state, .done)
        XCTAssertNil(status.error)
        XCTAssertNotNil(status.deleteAfter)
    }

    func testExpiredDeletionRevalidatesDestinationBeforeRemovingLegacySource() async throws {
        let dir = try directory()
        let legacyURL = dir.appendingPathComponent("db.sqlite")
        try makeLegacy(at: legacyURL, days: 1)
        let history = try makeHistory()
        try await LegacyDatabaseImporter(history: history, legacyURL: legacyURL,
                                         timebase: LegacyTimebase(numer: 1, denom: 1)).run()
        try await history.dbPool.write { db in
            try db.execute(sql: "DELETE FROM AppUsageHour WHERE metricVersion=0")
            try db.execute(sql: "UPDATE Meta SET value='0' WHERE key='legacy.deleteAfter'")
        }
        do {
            _ = try await history.deleteLegacyDatabaseIfExpired(at: legacyURL, now: Date())
            XCTFail("an inconsistent completed import must preserve the source for recovery")
        } catch let error as LegacyImportError {
            guard case .verificationFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        let status = try await history.importStatus()
        XCTAssertEqual(status.state, .failed)
        XCTAssertTrue(status.error?.isEmpty == false)
        XCTAssertNil(status.deleteAfter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testReadOnlyPerformanceImportWhenExplicitlyConfigured() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["VOLTSCOPE_LEGACY_BENCHMARK_SOURCE"] else {
            throw XCTSkip("Set VOLTSCOPE_LEGACY_BENCHMARK_SOURCE to run the full-database benchmark.")
        }
        let outputPath = ProcessInfo.processInfo.environment["VOLTSCOPE_LEGACY_BENCHMARK_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("voltscope-import-benchmark.sqlite").path
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path), "benchmark destination must be new")

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            if !db.configuration.readonly { try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL") }
        }
        let pool = try DatabasePool(path: outputURL.path, configuration: configuration)
        let history = try HistoryDatabase(dbPool: pool, fileURL: outputURL)
        let start = Date()
        try await LegacyDatabaseImporter(
            history: history,
            legacyURL: URL(fileURLWithPath: sourcePath),
            timebase: .system
        ).start().value
        let elapsed = Date().timeIntervalSince(start)
        let stats = try await history.dbPool.read { db -> BenchmarkStats in
            let state = try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.state'") ?? ""
            let appHours = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM AppUsageHour WHERE metricVersion=0") ?? 0
            let bucketHours = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM BucketHour WHERE metricVersion=0") ?? 0
            let batteries = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM BatteryStatus") ?? 0
            let error = try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key='legacy.error'") ?? ""
            return BenchmarkStats(state: state, appHours: appHours, bucketHours: bucketHours, batteries: batteries, error: error)
        }
        func fileSize(_ path: String) -> Int64 {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber
            return size?.int64Value ?? 0
        }
        let mainBytes = fileSize(outputURL.path)
        let sidecarBytes = fileSize(outputURL.path + "-wal") + fileSize(outputURL.path + "-shm")
        print("LEGACY_BENCHMARK elapsed_seconds=\(elapsed) main_bytes=\(mainBytes) sidecar_bytes=\(sidecarBytes) app_hour_rows=\(stats.appHours) bucket_hour_rows=\(stats.bucketHours) battery_rows=\(stats.batteries) state=\(stats.state) error=\(stats.error)")
        XCTAssertEqual(stats.state, "done")
        XCTAssertEqual(stats.error, "")
    }

    private func tierRows(_ history: HistoryDatabase) async throws -> String {
        try await history.dbPool.read { db in
            let tables = ["App", "AppUsageMinute", "AppUsageHour", "AppSampleRaw", "Bucket", "BucketMinute", "BucketHour", "BucketSampleRaw", "BatteryStatus", "PowerEvents"]
            return try tables.map { table in
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1")
                return "\(table):" + rows.map { String(describing: $0) }.joined(separator: "|")
            }.joined(separator: "\n")
        }
    }
}
