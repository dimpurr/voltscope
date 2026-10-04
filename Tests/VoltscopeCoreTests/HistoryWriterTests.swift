import XCTest
import GRDB
@testable import VoltscopeCore

final class HistoryWriterTests: XCTestCase {
    private final class SnapshotSequenceForHistoryWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[ProcessSnapshot]]

        init(_ values: [[ProcessSnapshot]]) { self.values = values }

        func next() -> (snapshots: [ProcessSnapshot], unreadableCount: Int) {
            lock.lock(); defer { lock.unlock() }
            return (values.isEmpty ? [] : values.removeFirst(), 0)
        }
    }

    private func processSnapshot(pid: Int32, start: UInt64, energy: UInt64) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, parentPid: 1, bundleIdentifier: "bounded.coordinator",
                        processName: "Queue", path: "/Queue", cpuUserNs: 0,
                        cpuSystemNs: 0, energyTotal: energy, wakeupsTotal: 0,
                        diskReadTotal: 0, diskWriteTotal: 0, procStartAbstime: start)
    }

    private func epoch(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Int64 {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Int64(components.date!.timeIntervalSince1970 * 1000)
    }

    private func rows<T: FetchableRecord>(_ db: HistoryDatabase, _ type: T.Type, sql: String) throws -> [Row] {
        try db.dbPool.read { conn in try Row.fetchAll(conn, sql: sql) }
    }

    private func sum(_ db: HistoryDatabase, sql: String) async throws -> Int64 {
        try await db.dbPool.read { conn in try Int64.fetchOne(conn, sql: sql) ?? 0 }
    }

    func testOneWrittenTickIsReadableThroughHistoryQueries() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.writeTick(timestamp: ts,
            apps: [SampledApp(groupKey: "tick.app", bundleIdentifier: "tick.app", displayName: "Tick",
                              pid: 42, energyNJ: 900, cpuNs: 1200)],
            buckets: [SampledBucket(name: "CPU", energyNJ: 1500)],
            coverage: SampleCoverage(visible: 12, unreadable: 3))
        try await db.flushPendingWindow()
        let interval = DateInterval(start: Date(timeIntervalSince1970: Double(ts - 30_000) / 1000),
                                    end: Date(timeIntervalSince1970: Double(ts + 1) / 1000))
        let app = try await db.historyEnergy(in: interval, range: .live)
        let hardware = try await db.historyHardware(in: interval, range: .live)
        let coverage = try await db.latestCoverage()
        XCTAssertEqual(app.map(\.energyNJ), [900])
        XCTAssertEqual(app.map(\.cpuNS), [1200])
        XCTAssertEqual(hardware.map(\.totalEnergyNJ), [1500])
        XCTAssertEqual(coverage?.unreadable, 3)
    }

    func testLateRawSampleAfterRollupRemainsVisibleInHourlyHistory() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let minute = epoch(2026, 1, 2, 3, 10)
        let first = SampledApp(groupKey: "late.app", bundleIdentifier: "late.app", displayName: "Late",
                               pid: 42, energyNJ: 10, cpuNs: 100)
        try await db.writeTick(timestamp: minute, apps: [first], buckets: [],
                               coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await db.flushPendingWindow()
        try await db.runMaintenance(now: Date(timeIntervalSince1970: Double(minute + 2 * 60 * 60_000) / 1000))

        try await db.writeTick(timestamp: minute + 1_000, apps: [
            SampledApp(groupKey: "late.app", bundleIdentifier: "late.app", displayName: "Late",
                       pid: 42, energyNJ: 5, cpuNs: 50)
        ], buckets: [], coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await db.flushPendingWindow()

        let interval = DateInterval(start: Date(timeIntervalSince1970: Double(minute) / 1000),
                                    end: Date(timeIntervalSince1970: Double(minute + 60 * 60_000) / 1000))
        let result = try await db.historyEnergy(in: interval, range: .h1)
        XCTAssertEqual(result.reduce(Int64(0)) { $0 + $1.energyNJ }, 15)
        let week = DateInterval(start: Date(timeIntervalSince1970: Double(minute) / 1000),
                                end: Date(timeIntervalSince1970: Double(minute + 7 * 86_400_000) / 1000))
        let hourlyResult = try await db.historyEnergy(in: week, range: .d7)
        XCTAssertEqual(hourlyResult.reduce(Int64(0)) { $0 + $1.energyNJ }, 15)
    }

    func testLateCoverageAfterHourRollupUpdatesCoverageHour() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let first = epoch(2026, 1, 2, 3, 10)
        try await db.writeTick(timestamp: first, apps: [], buckets: [],
                               coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await db.flushPendingWindow()
        try await db.runMaintenance(now: Date(timeIntervalSince1970: Double(first + 2 * 60 * 60_000) / 1000))

        try await db.writeTick(timestamp: first + 30_000, apps: [], buckets: [],
                               coverage: SampleCoverage(visible: 9, unreadable: 2))
        try await db.flushPendingWindow()
        try await db.writeTick(timestamp: first + 30_000, apps: [], buckets: [],
                               coverage: SampleCoverage(visible: 4, unreadable: 1))
        try await db.flushPendingWindow()

        let row = try db.dbPool.read { conn in
            return try Row.fetchOne(conn, sql: "SELECT ticks, visibleSum, unreadableSum FROM CoverageHour WHERE hour = ?",
                                    arguments: [first / 3_600_000])
        }
        XCTAssertEqual(row?["ticks"] as Int64?, 2)
        XCTAssertEqual(row?["visibleSum"] as Int64?, 5, "replacing a timestamp adjusts sums without adding a tick")
        XCTAssertEqual(row?["unreadableSum"] as Int64?, 1)
    }

    func testClockJumpForwardDoesNotPruneRawHistoryEarly() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let timestamp = epoch(2026, 10, 3, 12)
        try await db.dbPool.write { conn in
            try conn.execute(sql: "INSERT OR REPLACE INTO Meta (key, value) VALUES ('settings.rawRetentionDays', '2')")
        }
        try await db.writeTick(timestamp: timestamp,
            apps: [SampledApp(groupKey: "clock.app", displayName: "Clock", pid: 7, energyNJ: 11, cpuNs: 20)],
            buckets: [], coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await db.flushPendingWindow()
        let baseline = Date(timeIntervalSince1970: Double(timestamp + 2 * 60 * 60_000) / 1000)
        try await db.pruneHistory(now: baseline)
        try await db.pruneHistory(now: baseline.addingTimeInterval(17 * 86_400))

        let raw = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE ts = ?", arguments: [timestamp]) ?? 0
        }
        XCTAssertEqual(raw, 1)
    }

    func testSleepInclusiveClockAdvancesRetentionCutoffAcrossSixteenHours() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let baselineMS = epoch(2026, 10, 3, 12)
        let sampleMS = baselineMS - 36 * 60 * 60_000
        let monotonicStart: TimeInterval = 5_000
        try await db.dbPool.write { conn in
            try conn.execute(sql: "INSERT OR REPLACE INTO Meta (key, value) VALUES ('settings.rawRetentionDays', '2')")
        }
        try await db.writeTick(timestamp: sampleMS,
            apps: [SampledApp(groupKey: "sleep.clock", displayName: "Sleep Clock", pid: 9,
                              energyNJ: 11, cpuNs: 20)],
            buckets: [], coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await db.flushPendingWindow()
        try await db.dbPool.write { conn in
            try conn.execute(sql: "INSERT OR REPLACE INTO Meta (key, value) VALUES ('retention.safeWallClockMS', ?)",
                             arguments: [String(baselineMS)])
            try conn.execute(sql: "INSERT OR REPLACE INTO Meta (key, value) VALUES ('retention.safeMonotonicMS', ?)",
                             arguments: [String(Int64(monotonicStart * 1000))])
        }

        try await db.pruneHistory(now: Date(timeIntervalSince1970: Double(baselineMS) / 1000),
                                  monotonicNow: monotonicStart)
        let afterSleepMS = baselineMS + 16 * 60 * 60_000
        try await db.pruneHistory(now: Date(timeIntervalSince1970: Double(afterSleepMS) / 1000),
                                  monotonicNow: monotonicStart + 16 * 60 * 60)

        let raw = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE ts = ?", arguments: [sampleMS]) ?? 0
        }
        let safeNow = try await db.dbPool.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key = 'retention.safeWallClockMS'")
        }
        XCTAssertEqual(raw, 0, "16 hours of sleep-inclusive elapsed time should advance the two-day raw cutoff")
        XCTAssertEqual(safeNow, afterSleepMS)
    }

    func testRebootedMonotonicClockReanchorsToHistoryWithoutEarlyPruning() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let sampleMS = epoch(2026, 10, 1, 12)
        let previousSafeMS = sampleMS + 4 * 86_400_000
        try await db.dbPool.write { conn in
            try conn.execute(sql: "INSERT OR REPLACE INTO Meta (key, value) VALUES ('settings.rawRetentionDays', '2')")
        }
        try await db.writeTick(timestamp: sampleMS,
            apps: [SampledApp(groupKey: "reboot.clock", displayName: "Reboot Clock", pid: 10,
                              energyNJ: 13, cpuNs: 24)],
            buckets: [], coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await db.flushPendingWindow()
        try await db.dbPool.write { conn in
            try conn.execute(sql: "INSERT OR REPLACE INTO Meta (key, value) VALUES ('retention.safeWallClockMS', ?)",
                             arguments: [String(previousSafeMS)])
            try conn.execute(sql: "INSERT OR REPLACE INTO Meta (key, value) VALUES ('retention.safeMonotonicMS', '604800000')")
        }

        let nowMS = sampleMS + 4 * 86_400_000
        try await db.pruneHistory(now: Date(timeIntervalSince1970: Double(nowMS) / 1000), monotonicNow: 1)

        let raw = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE ts = ?", arguments: [sampleMS]) ?? 0
        }
        let safeNow = try await db.dbPool.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key = 'retention.safeWallClockMS'")
        }
        XCTAssertEqual(raw, 1, "reboot re-anchoring must not use the previous boot's advanced cutoff")
        XCTAssertEqual(safeNow, sampleMS + 5 * 60_000)
    }

    func testSevenDayQueryExcludesPartialLeftHourAfterRawPrune() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let start = epoch(2026, 10, 3, 12, 30)
        let outOfRangeSample = start - 15 * 60_000
        let inRangeSample = start + 15 * 60_000
        let firstCompleteHourSample = start + 45 * 60_000
        try await db.dbPool.write { conn in
            try conn.execute(sql: "INSERT OR REPLACE INTO Meta (key, value) VALUES ('settings.rawRetentionDays', '2')")
        }
        for (timestamp, pid) in [(outOfRangeSample, Int32(7)), (inRangeSample, Int32(8)),
                                 (firstCompleteHourSample, Int32(9))] {
            try await db.writeTick(timestamp: timestamp,
                apps: [SampledApp(groupKey: "edge.app", bundleIdentifier: "edge.app", displayName: "Edge",
                                  pid: pid, energyNJ: 10, cpuNs: 20)], buckets: [],
                coverage: SampleCoverage(visible: 1, unreadable: 0))
        }
        try await db.flushPendingWindow()
        let monotonicStart: TimeInterval = 1_000
        try await db.runMaintenance(now: Date(timeIntervalSince1970: Double(inRangeSample + 2 * 60 * 60_000) / 1000),
                                    monotonicNow: monotonicStart)
        let end = start + 7 * 86_400_000
        try await db.runMaintenance(now: Date(timeIntervalSince1970: Double(end) / 1000),
                                    monotonicNow: monotonicStart + 7 * 86_400)

        let rawRows = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE ts IN (?, ?, ?)",
                             arguments: [outOfRangeSample, inRangeSample, firstCompleteHourSample]) ?? 0
        }
        XCTAssertEqual(rawRows, 0, "the fixture must exercise the expired-raw path")

        let result = try await db.historyEnergy(in: DateInterval(start: Date(timeIntervalSince1970: Double(start) / 1000),
                                                                 end: Date(timeIntervalSince1970: Double(end) / 1000)), range: .d7)
        XCTAssertEqual(result.reduce(Int64(0)) { $0 + $1.energyNJ }, 10,
                       "the partial 12:00 hour is excluded; hourly summaries from 13:00 onward remain in range")
    }

    func testWindowFlushKeepsSeparatePIDsUnderOneApp() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let timestamp = epoch(2026, 1, 2, 3, 4)
        try await db.writeTick(timestamp: timestamp, apps: [
            SampledApp(groupKey: "shared.app", bundleIdentifier: "shared.app", displayName: "Shared",
                       path: "/Applications/Shared.app", pid: 101, energyNJ: 10, cpuNs: 100),
            SampledApp(groupKey: "shared.app", bundleIdentifier: "shared.app", displayName: "Shared",
                       path: "/Applications/Shared.app", pid: 102, energyNJ: 20, cpuNs: 200),
            SampledApp(groupKey: "shared.app", bundleIdentifier: "shared.app", displayName: "Shared",
                       path: "/Applications/Shared.app", pid: 103, energyNJ: 30, cpuNs: 300)
        ], buckets: [], coverage: SampleCoverage(visible: 3, unreadable: 0))
        try await db.flushPendingWindow()

        let persisted = try db.dbPool.read { conn in
            let appCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM App WHERE groupKey='shared.app'") ?? 0
            let rows = try Row.fetchAll(conn, sql: """
                SELECT r.pid, r.energyNJ FROM AppSampleRaw r JOIN App a ON a.id=r.appId
                WHERE a.groupKey='shared.app' ORDER BY r.pid
                """)
            return (appCount, rows)
        }
        XCTAssertEqual(persisted.0, 1)
        XCTAssertEqual(persisted.1.compactMap { $0["pid"] as Int32? }, [101, 102, 103])
        XCTAssertEqual(persisted.1.compactMap { $0["energyNJ"] as Int64? }, [10, 20, 30])
    }

    func testCPUOnlyRowsRankWithoutCreatingEnergyJoules() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.writeTick(timestamp: ts,
            apps: [
                SampledApp(groupKey: "cpu.slow", displayName: "Slow", pid: 1, energyNJ: 0, cpuNs: 100),
                SampledApp(groupKey: "cpu.busy", displayName: "Busy", pid: 2, energyNJ: 0, cpuNs: 900)
            ], buckets: [], coverage: SampleCoverage(visible: 2, unreadable: 0), energyUnavailable: true)
        try await db.flushPendingWindow()
        let rows = try await db.appBreakdown(sinceMinutes: 1, energyAvailable: false)
        XCTAssertEqual(rows.map(\.processName), ["Busy", "Slow"])
        XCTAssertTrue(rows.allSatisfy { $0.totalEnergyNJ == 0 })
    }

    func testSixTicksCoalesceAndWindowBoundaryFlushesWithoutLosingTotals() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let start = epoch(2026, 1, 2, 3, 4)
        for tick in 0..<6 {
            try await db.writeTick(timestamp: start + Int64(tick * 5_000),
                apps: [SampledApp(groupKey: "window.app", displayName: "Window", pid: 55,
                                  energyNJ: Int64(tick + 1), cpuNs: 10, wakeups: 1,
                                  diskReadBytes: 2, diskWriteBytes: 3)],
                buckets: [SampledBucket(name: "CPU", energyNJ: Int64(tick + 1))],
                coverage: SampleCoverage(visible: Int64(tick + 1), unreadable: 1))
        }
        let secondWindow = start / 30_000 * 30_000 + 30_000
        try await db.writeTick(timestamp: secondWindow,
            apps: [SampledApp(groupKey: "window.app", displayName: "Window", pid: 55,
                              energyNJ: 7, cpuNs: 11)], buckets: [],
            coverage: SampleCoverage(visible: 9, unreadable: 0))
        let firstWindow = try db.dbPool.read { conn in
            return try Row.fetchOne(conn, sql: "SELECT ts, energyNJ, cpuNs, wakeups, diskReadBytes, diskWriteBytes FROM AppSampleRaw")
        }
        XCTAssertEqual(firstWindow?["ts"] as Int64?, start / 30_000 * 30_000)
        XCTAssertEqual(firstWindow?["energyNJ"] as Int64?, 21)
        XCTAssertEqual(firstWindow?["cpuNs"] as Int64?, 60)
        XCTAssertEqual(firstWindow?["wakeups"] as Int64?, 6)
        XCTAssertEqual(firstWindow?["diskReadBytes"] as Int64?, 12)
        XCTAssertEqual(firstWindow?["diskWriteBytes"] as Int64?, 18)
        let bucketEnergy = try await sum(db, sql: "SELECT SUM(energyNJ) FROM BucketSampleRaw")
        XCTAssertEqual(bucketEnergy, 21)
        let coverage = try await db.latestCoverage()
        XCTAssertEqual(coverage?.visible, 6) // Last scan in the completed window.
        try await db.flushPendingWindow()
        let counts = try await db.dbPool.read { conn in try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppSampleRaw") ?? 0 }
        XCTAssertEqual(counts, 2)
    }

    func testCoordinatorStopFlushesPartialWindow() async throws {
        let db = try HistoryDatabase.makeInMemory()
        try await db.writeTick(timestamp: epoch(2026, 1, 2, 3, 4) + 4_000,
            apps: [SampledApp(groupKey: "quit.app", displayName: "Quit", pid: 70,
                              energyNJ: 99, cpuNs: 101)], buckets: [],
            coverage: SampleCoverage(visible: 1, unreadable: 0))
        let stopped = await SamplingCoordinator(database: db).stop()
        XCTAssertTrue(stopped)
        let persisted = try await db.dbPool.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw") ?? 0
        }
        XCTAssertEqual(persisted, 99)
    }

    func testCoordinatorReportsFailedShutdownFlushAndCanRetry() async throws {
        let db = try HistoryDatabase.makeInMemory()
        try await db.writeTick(timestamp: epoch(2026, 1, 2, 3, 4),
            apps: [SampledApp(groupKey: "shutdown.retry", displayName: "Retry", pid: 75,
                              energyNJ: 29, cpuNs: 29)], buckets: [],
            coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                CREATE TEMP TRIGGER fail_raw_insert BEFORE INSERT ON AppSampleRaw
                BEGIN SELECT RAISE(FAIL, 'injected write failure'); END
                """)
        }
        let coordinator = SamplingCoordinator(database: db)

        let firstStop = await coordinator.stop()
        XCTAssertFalse(firstStop)
        try await db.dbPool.write { conn in
            try conn.execute(sql: "DROP TRIGGER fail_raw_insert")
        }
        let retryStop = await coordinator.stop()
        XCTAssertTrue(retryStop)
        let total = try await sum(db, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw")
        XCTAssertEqual(total, 29)
    }

    func testFailedWindowBoundaryFlushRetainsBatchForRetry() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let firstWindow = epoch(2026, 1, 2, 3, 4)
        try await db.writeTick(timestamp: firstWindow,
            apps: [SampledApp(groupKey: "retry.app", displayName: "Retry", pid: 71,
                              energyNJ: 10, cpuNs: 10)], buckets: [],
            coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                CREATE TEMP TRIGGER fail_raw_insert BEFORE INSERT ON AppSampleRaw
                BEGIN SELECT RAISE(FAIL, 'injected write failure'); END
                """)
        }

        do {
            try await db.writeTick(timestamp: firstWindow + 30_000,
                apps: [SampledApp(groupKey: "retry.app", displayName: "Retry", pid: 71,
                                  energyNJ: 1, cpuNs: 1)], buckets: [],
                coverage: SampleCoverage(visible: 1, unreadable: 0))
            XCTFail("The injected trigger should reject the completed window")
        } catch {
            // The failed completed window must remain available for a later retry.
        }

        try await db.dbPool.write { conn in
            try conn.execute(sql: "DROP TRIGGER fail_raw_insert")
        }
        try await db.flushPendingWindow()

        let total = try await sum(db, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw")
        XCTAssertEqual(total, 11)
    }

    func testFailedExplicitFlushRetainsBatchForRetry() async throws {
        let db = try HistoryDatabase.makeInMemory()
        try await db.writeTick(timestamp: epoch(2026, 1, 2, 3, 4),
            apps: [SampledApp(groupKey: "retry.flush", displayName: "Retry", pid: 72,
                              energyNJ: 13, cpuNs: 13)], buckets: [],
            coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                CREATE TEMP TRIGGER fail_raw_insert BEFORE INSERT ON AppSampleRaw
                BEGIN SELECT RAISE(FAIL, 'injected write failure'); END
                """)
        }
        do {
            try await db.flushPendingWindow()
            XCTFail("The injected trigger should reject the explicit flush")
        } catch {
            // Retry after removing the injected storage failure.
        }
        try await db.dbPool.write { conn in
            try conn.execute(sql: "DROP TRIGGER fail_raw_insert")
        }
        try await db.flushPendingWindow()

        let total = try await sum(db, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw")
        XCTAssertEqual(total, 13)
    }

    func testFailedWindowQueueIsBoundedAndFlushCanDrainIt() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let start = epoch(2026, 1, 2, 3, 4)
        try await db.writeTick(timestamp: start,
            apps: [SampledApp(groupKey: "bounded.retry", displayName: "Retry", pid: 74,
                              energyNJ: 10, cpuNs: 10)], buckets: [],
            coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                CREATE TEMP TRIGGER fail_raw_insert BEFORE INSERT ON AppSampleRaw
                BEGIN SELECT RAISE(FAIL, 'injected write failure'); END
                """)
        }

        for window in 1...8 {
            do {
                try await db.writeTick(timestamp: start + Int64(window * 30_000),
                    apps: [SampledApp(groupKey: "bounded.retry", displayName: "Retry", pid: 74,
                                      energyNJ: Int64(window), cpuNs: Int64(window))], buckets: [],
                    coverage: SampleCoverage(visible: 1, unreadable: 0))
            } catch {
                // Each completed batch stays queued while the trigger rejects writes.
            }
        }
        do {
            try await db.writeTick(timestamp: start + 9 * 30_000,
                apps: [SampledApp(groupKey: "bounded.retry", displayName: "Retry", pid: 74,
                                  energyNJ: 9, cpuNs: 9)], buckets: [],
                coverage: SampleCoverage(visible: 1, unreadable: 0))
            XCTFail("The writer should apply backpressure at its pending-window bound")
        } catch {
            // The current window remains intact and the ninth queued window is rejected.
        }

        try await db.dbPool.write { conn in
            try conn.execute(sql: "DROP TRIGGER fail_raw_insert")
        }
        try await db.flushPendingWindow()

        let total = try await sum(db, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw")
        let count = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppSampleRaw") ?? 0
        }
        XCTAssertEqual(total, 46)
        XCTAssertEqual(count, 9)
    }

    func testRejectedProcessTickCanBeRecoveredFromCumulativeCounter() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let start = epoch(2026, 1, 2, 3, 4)
        let sequence = SnapshotSequenceForHistoryWriter([
            [processSnapshot(pid: 90, start: 1, energy: 100)],
            [processSnapshot(pid: 90, start: 1, energy: 130)],
            [processSnapshot(pid: 90, start: 1, energy: 140)]
        ])
        let sampler = ProcessSampler(energyAvailable: true, snapshotReader: { sequence.next() })
        let coordinator = SamplingCoordinator(database: db, processSampler: sampler)
        func tickDate(_ offset: Int64) -> Date {
            Date(timeIntervalSince1970: Double(start + offset) / 1000)
        }
        _ = await coordinator.runProcessTick(emit: false, at: tickDate(0))

        try await db.writeTick(timestamp: start,
            apps: [SampledApp(groupKey: "bounded.coordinator", displayName: "Queue", pid: 91,
                              energyNJ: 10, cpuNs: 10)], buckets: [],
            coverage: SampleCoverage(visible: 1, unreadable: 0))
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                CREATE TEMP TRIGGER fail_raw_insert BEFORE INSERT ON AppSampleRaw
                BEGIN SELECT RAISE(FAIL, 'injected write failure'); END
                """)
        }
        for window in 1...8 {
            do {
                try await db.writeTick(timestamp: start + Int64(window * 30_000),
                    apps: [SampledApp(groupKey: "bounded.coordinator", displayName: "Queue", pid: 91,
                                      energyNJ: 1, cpuNs: 1)], buckets: [],
                    coverage: SampleCoverage(visible: 1, unreadable: 0))
            } catch { }
        }

        _ = await coordinator.runProcessTick(emit: true, at: tickDate(270_000))
        do {
            try await db.writeTick(timestamp: start + 300_000,
                apps: [SampledApp(groupKey: "bounded.coordinator", displayName: "Queue", pid: 92,
                                  energyNJ: 1, cpuNs: 1)], buckets: [],
                coverage: SampleCoverage(visible: 1, unreadable: 0))
            XCTFail("The queue must still be full after the coordinator rejected the process tick")
        } catch let error as HistoryWindowBufferError {
            if case .pendingLimitReached = error { } else { XCTFail("Unexpected buffer error: \(error)") }
        } catch {
            XCTFail("Unexpected write error: \(error)")
        }

        try await db.dbPool.write { conn in try conn.execute(sql: "DROP TRIGGER fail_raw_insert") }
        try await db.flushPendingWindow()
        _ = await coordinator.runProcessTick(emit: true, at: tickDate(300_000))
        try await db.flushPendingWindow()

        let total = try await sum(db, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw WHERE pid = 90")
        XCTAssertEqual(total, 40, "the rejected 30 nJ delta must be replayed with the next 10 nJ delta")
    }

    func testMinuteRollupUsesRawTimestampRangeIndex() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let plans = try await db.dbPool.read { conn in
            let appPlan = try Row.fetchAll(conn, sql: """
                EXPLAIN QUERY PLAN
                SELECT ts / 60000, appId, metricVersion, SUM(energyNJ)
                FROM AppSampleRaw
                WHERE ts >= 6060000 AND ts < 12000000 AND metricVersion <> 0
                GROUP BY ts / 60000, appId, metricVersion
                """).compactMap { $0["detail"] as String? }.joined(separator: " | ")
            let bucketPlan = try Row.fetchAll(conn, sql: """
                EXPLAIN QUERY PLAN
                SELECT ts / 60000, bucketId, metricVersion, SUM(energyNJ)
                FROM BucketSampleRaw
                WHERE ts >= 6060000 AND ts < 12000000 AND metricVersion <> 0
                GROUP BY ts / 60000, bucketId, metricVersion
                """).compactMap { $0["detail"] as String? }.joined(separator: " | ")
            return (appPlan, bucketPlan)
        }
        XCTAssertTrue(plans.0.contains("SEARCH AppSampleRaw USING INDEX AppSampleRaw_ts"), plans.0)
        XCTAssertTrue(plans.1.contains("SEARCH BucketSampleRaw USING INDEX BucketSampleRaw_ts"), plans.1)
    }

    func testSleepEventFlushesPartialWindow() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let timestamp = epoch(2026, 1, 2, 3, 4)
        try await db.writeTick(timestamp: timestamp,
            apps: [SampledApp(groupKey: "sleep.app", displayName: "Sleep", pid: 73,
                              energyNJ: 23, cpuNs: 23)], buckets: [],
            coverage: SampleCoverage(visible: 1, unreadable: 0))

        await SamplingCoordinator(database: db).recordEvent(
            PowerEvent(timestamp: timestamp + 1, eventType: .sleep)
        )

        let total = try await sum(db, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw")
        XCTAssertEqual(total, 23)
    }

    func testMinuteRetentionKeepsFull24HourQueryComplete() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: Double(epoch(2026, 5, 2, 12)) / 1000)
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        for (timestamp, energy) in [(nowMS - 3 * 86_400_000, Int64(999)), (nowMS - 23 * 3_600_000, Int64(10)), (nowMS - 1_800_000, Int64(20))] {
            try await db.writeTick(timestamp: timestamp,
                apps: [SampledApp(groupKey: "retained", displayName: "Retained", pid: 8,
                                  energyNJ: energy, cpuNs: energy)], buckets: [],
                coverage: SampleCoverage(visible: 1, unreadable: 0))
        }
        try await db.runMaintenance(now: now)
        let oldMinutes = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppUsageMinute WHERE minute < ?",
                             arguments: [nowMS / 60_000 - 2 * 24 * 60]) ?? 0
        }
        XCTAssertEqual(oldMinutes, 0)
        let interval = DateInterval(start: now.addingTimeInterval(-24 * 3_600), end: now)
        let rows = try await db.historyEnergy(in: interval, range: .h24)
        XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.energyNJ }, 30)
    }

    func testTickWritingRollupsAreIdempotentAcrossHourAndDayBoundaries() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let start = epoch(2025, 1, 1, 23, 58)
        for (offset, energy, version) in [(0, 10, 1), (2, 20, 1), (4, 7, 0)] {
            try await db.writeTick(
                timestamp: start + Int64(offset * 60_000),
                apps: [
                    SampledApp(groupKey: "app", bundleIdentifier: "app", displayName: "App", pid: 44,
                               energyNJ: Int64(energy), cpuNs: Int64(energy * 10), wakeups: 1),
                    SampledApp(groupKey: "filtered", displayName: "Filtered", pid: 45,
                               energyNJ: 0, cpuNs: 90)
                ],
                buckets: [SampledBucket(name: "cpu", energyNJ: Int64(energy * 2))],
                coverage: SampleCoverage(visible: 2, unreadable: 1),
                metricVersion: version
            )
        }
        // CPU-only rows are retained only when the caller marks energy unavailable.
        try await db.writeTick(
            timestamp: start + 6 * 60_000,
            apps: [SampledApp(groupKey: "cpu-only", displayName: "CPU", pid: 46, energyNJ: 0, cpuNs: 123)],
            buckets: [], coverage: SampleCoverage(visible: 1, unreadable: 0), energyUnavailable: true
        )

        let now = Date(timeIntervalSince1970: Double(start + 3 * 60 * 60_000) / 1000)
        try await db.runMaintenance(now: now)
        let firstMinutes = try rows(db, AppUsageMinute.self, sql: "SELECT * FROM AppUsageMinute ORDER BY minute, appId, metricVersion")
        let firstAppHours = try rows(db, AppUsageHour.self, sql: "SELECT * FROM AppUsageHour ORDER BY hour, appId, metricVersion")
        let firstBucketHours = try rows(db, BucketHour.self, sql: "SELECT * FROM BucketHour ORDER BY hour, bucketId, metricVersion")
        let firstCoverage = try rows(db, CoverageHour.self, sql: "SELECT * FROM CoverageHour ORDER BY hour")
        try await db.runMaintenance(now: now)
        let secondMinutes = try rows(db, AppUsageMinute.self, sql: "SELECT * FROM AppUsageMinute ORDER BY minute, appId, metricVersion")
        let secondAppHours = try rows(db, AppUsageHour.self, sql: "SELECT * FROM AppUsageHour ORDER BY hour, appId, metricVersion")
        let secondBucketHours = try rows(db, BucketHour.self, sql: "SELECT * FROM BucketHour ORDER BY hour, bucketId, metricVersion")
        let secondCoverage = try rows(db, CoverageHour.self, sql: "SELECT * FROM CoverageHour ORDER BY hour")
        XCTAssertEqual(firstMinutes, secondMinutes)
        XCTAssertEqual(firstAppHours, secondAppHours)
        XCTAssertEqual(firstBucketHours, secondBucketHours)
        XCTAssertEqual(firstCoverage, secondCoverage)

        let totals = try await db.dbPool.read { conn in
            let rawEnergy = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw") ?? 0
            let minuteEnergy = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppUsageMinute") ?? 0
            let hourEnergy = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppUsageHour") ?? 0
            let rawBucketEnergy = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM BucketSampleRaw") ?? 0
            let hourBucketEnergy = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM BucketHour") ?? 0
            let filteredApps = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM App WHERE groupKey = 'filtered'") ?? 0
            let cpuOnlyApps = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM App WHERE groupKey = 'cpu-only'") ?? 0
            let coverageTicks = try Int64.fetchOne(conn, sql: "SELECT SUM(ticks) FROM CoverageHour") ?? 0
            return (rawEnergy, minuteEnergy, hourEnergy, rawBucketEnergy, hourBucketEnergy,
                    filteredApps, cpuOnlyApps, coverageTicks)
        }
        XCTAssertEqual(totals.0, 37)
        XCTAssertEqual(totals.1, totals.0)
        XCTAssertEqual(totals.2, totals.0)
        XCTAssertEqual(totals.3, 74)
        XCTAssertEqual(totals.4, totals.3)
        XCTAssertEqual(totals.5, 0)
        XCTAssertEqual(totals.6, 1)
        XCTAssertEqual(totals.7, 4)

        let versionTotals = try await db.dbPool.read { conn in
            try Row.fetchAll(conn, sql: "SELECT metricVersion, SUM(energyNJ) AS energy FROM AppUsageHour GROUP BY metricVersion ORDER BY metricVersion")
                .map { ($0["metricVersion"] as Int, $0["energy"] as Int64) }
        }
        XCTAssertEqual(versionTotals.map(\.0), [0, 1])
        XCTAssertEqual(versionTotals.map(\.1), [7, 30])
    }

    func testMinuteOnlyRunCanBeCompletedByFullMaintenance() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let ts = epoch(2025, 2, 3, 10, 4)
        for minute in [0, 1, 2] {
            try await db.writeTick(
                timestamp: ts + Int64(minute * 60_000),
                apps: [SampledApp(groupKey: "resume", displayName: "Resume", pid: 1, energyNJ: 5, cpuNs: 8)],
                buckets: [SampledBucket(name: "gpu", energyNJ: 11)],
                coverage: SampleCoverage(visible: 1, unreadable: 0)
            )
        }
        let now = Date(timeIntervalSince1970: Double(ts + 3 * 60 * 60_000) / 1000)
        try await db.rollupMinutes(now: now)
        let afterMinuteStep = try await db.dbPool.read { conn in
            let hourCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppUsageHour") ?? 0
            let minuteWatermark = try String.fetchOne(
                conn, sql: "SELECT value FROM Meta WHERE key = 'rollup.minuteWatermark'")
            let hourWatermark = try String.fetchOne(
                conn, sql: "SELECT value FROM Meta WHERE key = 'rollup.hourWatermark'")
            return (hourCount, minuteWatermark, hourWatermark)
        }
        XCTAssertEqual(afterMinuteStep.0, 0)
        XCTAssertEqual(afterMinuteStep.1, String(Int64(now.timeIntervalSince1970 / 60) - 2))
        XCTAssertNil(afterMinuteStep.2)

        try await db.runMaintenance(now: now)
        let after = try await db.dbPool.read { conn in
            (
                try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppUsageHour") ?? 0,
                try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM BucketHour") ?? 0,
                try Int64.fetchOne(conn, sql: "SELECT SUM(ticks) FROM CoverageHour") ?? 0
            )
        }
        XCTAssertEqual(after.0, 15)
        XCTAssertEqual(after.1, 33)
        XCTAssertEqual(after.2, 3)
        let hourWatermark = try await db.dbPool.read { conn in
            try String.fetchOne(conn, sql: "SELECT value FROM Meta WHERE key = 'rollup.hourWatermark'")
        }
        XCTAssertEqual(hourWatermark, String(Int64(now.timeIntervalSince1970 / 3600) - 1))
    }

    func testHourRollupWaitsForMinuteWatermarkAndRebuildsIdempotently() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let hourStart = epoch(2025, 2, 3, 10)
        for (minute, energy) in [(58, 13), (59, 17)] {
            try await db.writeTick(
                timestamp: hourStart + Int64(minute * 60_000),
                apps: [SampledApp(groupKey: "boundary", displayName: "Boundary", pid: 7,
                                  energyNJ: Int64(energy), cpuNs: Int64(energy * 2))],
                buckets: [SampledBucket(name: "cpu", energyNJ: Int64(energy * 3))],
                coverage: SampleCoverage(visible: Int64(minute), unreadable: 1)
            )
        }

        let firstRun = Date(timeIntervalSince1970: Double(hourStart + 60 * 60_000 + 30_000) / 1000)
        try await db.runMaintenance(now: firstRun)
        let beforeHourSeal = try await db.dbPool.read { conn in
            (
                try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppUsageHour") ?? 0,
                try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM BucketHour") ?? 0,
                try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM CoverageHour") ?? 0
            )
        }
        XCTAssertEqual(beforeHourSeal.0, 0)
        XCTAssertEqual(beforeHourSeal.1, 0)
        XCTAssertEqual(beforeHourSeal.2, 0)

        let secondRun = Date(timeIntervalSince1970: Double(hourStart + 65 * 60_000) / 1000)
        try await db.runMaintenance(now: secondRun)
        let rawAppEnergy = try await sum(db, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw")
        let appHourEnergy = try await sum(db, sql: "SELECT SUM(energyNJ) FROM AppUsageHour")
        let rawBucketEnergy = try await sum(db, sql: "SELECT SUM(energyNJ) FROM BucketSampleRaw")
        let bucketHourEnergy = try await sum(db, sql: "SELECT SUM(energyNJ) FROM BucketHour")
        let coverageTicks = try await sum(db, sql: "SELECT SUM(ticks) FROM CoverageHour")
        let coverageVisible = try await sum(db, sql: "SELECT SUM(visibleSum) FROM CoverageHour")
        let coverageUnreadable = try await sum(db, sql: "SELECT SUM(unreadableSum) FROM CoverageHour")
        XCTAssertEqual(rawAppEnergy, 30)
        XCTAssertEqual(appHourEnergy, rawAppEnergy)
        XCTAssertEqual(rawBucketEnergy, 90)
        XCTAssertEqual(bucketHourEnergy, rawBucketEnergy)
        XCTAssertEqual(coverageTicks, 2)
        XCTAssertEqual(coverageVisible, 117)
        XCTAssertEqual(coverageUnreadable, 2)

        try await db.dbPool.write { conn in
            try conn.execute(sql: "DELETE FROM Meta WHERE key IN ('rollup.minuteWatermark', 'rollup.hourWatermark')")
        }
        try await db.runMaintenance(now: secondRun)
        let rebuiltAppMinuteEnergy = try await sum(db, sql: "SELECT SUM(energyNJ) FROM AppUsageMinute")
        let rebuiltAppHourEnergy = try await sum(db, sql: "SELECT SUM(energyNJ) FROM AppUsageHour")
        let rebuiltBucketMinuteEnergy = try await sum(db, sql: "SELECT SUM(energyNJ) FROM BucketMinute")
        let rebuiltBucketHourEnergy = try await sum(db, sql: "SELECT SUM(energyNJ) FROM BucketHour")
        let rebuiltCoverageTicks = try await sum(db, sql: "SELECT SUM(ticks) FROM CoverageHour")
        let rebuiltCoverageVisible = try await sum(db, sql: "SELECT SUM(visibleSum) FROM CoverageHour")
        let rebuiltCoverageUnreadable = try await sum(db, sql: "SELECT SUM(unreadableSum) FROM CoverageHour")
        XCTAssertEqual(rebuiltAppMinuteEnergy, rawAppEnergy)
        XCTAssertEqual(rebuiltAppHourEnergy, appHourEnergy)
        XCTAssertEqual(rebuiltBucketMinuteEnergy, rawBucketEnergy)
        XCTAssertEqual(rebuiltBucketHourEnergy, bucketHourEnergy)
        XCTAssertEqual(rebuiltCoverageTicks, coverageTicks)
        XCTAssertEqual(rebuiltCoverageVisible, coverageVisible)
        XCTAssertEqual(rebuiltCoverageUnreadable, coverageUnreadable)
    }

    func testConfiguredThreeDayRetentionLeavesHoursUntouched() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let old = epoch(2025, 3, 1, 12)
        let recent = old + 5 * 86_400_000
        for (ts, energy) in [(old, 4), (recent, 9)] {
            try await db.writeTick(
                timestamp: ts,
                apps: [SampledApp(groupKey: "retain", displayName: "Retain", pid: 3, energyNJ: Int64(energy), cpuNs: 1)],
                buckets: [SampledBucket(name: "cpu", energyNJ: Int64(energy))],
                coverage: SampleCoverage(visible: 1, unreadable: 0)
            )
        }
        let now = Date(timeIntervalSince1970: Double(recent + 3 * 60 * 60_000) / 1000)
        try await db.runMaintenance(now: now)
        let initialTotals = try await db.dbPool.read { conn in
            let raw = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw") ?? 0
            let hours = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppUsageHour") ?? 0
            return (raw, hours)
        }
        XCTAssertEqual(initialTotals.0, 13, "the default retention keeps both samples within seven days")
        try await db.dbPool.write { conn in
            try MetaEntry(key: "settings.rawRetentionDays", value: "3").insert(conn)
        }
        let later = now.addingTimeInterval(86_400)
        try await db.runMaintenance(now: later)

        let values = try await db.dbPool.read { conn in
            let appRaw = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppSampleRaw") ?? 0
            let bucketRaw = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM BucketSampleRaw") ?? 0
            let appHours = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM AppUsageHour") ?? 0
            let bucketHours = try Int64.fetchOne(conn, sql: "SELECT SUM(energyNJ) FROM BucketHour") ?? 0
            let coverageTicks = try Int64.fetchOne(conn, sql: "SELECT SUM(ticks) FROM CoverageHour") ?? 0
            return (appRaw, bucketRaw, appHours, bucketHours, coverageTicks)
        }
        XCTAssertEqual(values.0, 9)
        XCTAssertEqual(values.1, 9)
        XCTAssertEqual(values.2, initialTotals.1)
        XCTAssertEqual(values.3, initialTotals.1)
        XCTAssertEqual(values.4, 2)
    }
}
