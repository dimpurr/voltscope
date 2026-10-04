import Foundation
import GRDB
import XCTest
@testable import VoltscopeCore

/// Opt-in ten-day storage simulation. Run with
/// VOLTSCOPE_STORAGE_SIMULATION=1 swift test --disable-keychain --filter HistoryStorageSteadyStateTests.
final class HistoryStorageSteadyStateTests: XCTestCase {
    private struct StorageMetrics {
        let pageCount: Int
        let pageSize: Int
        let freelistCount: Int
        let databaseBytes: Int64
        let walBytes: Int64
        let rawRows: Int
        let batteryRows: Int
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    private func makeTemporaryDatabase() throws -> HistoryDatabase {
        let db = try HistoryDatabase.makeTemporaryFile()
        if let fileURL = db.fileURL {
            temporaryDirectories.append(fileURL.deletingLastPathComponent())
        }
        return db
    }

    private func metrics(_ db: HistoryDatabase) async throws -> StorageMetrics {
        let databaseStats = try await db.dbPool.read { conn in
            (try Int.fetchOne(conn, sql: "PRAGMA page_count") ?? 0,
             try Int.fetchOne(conn, sql: "PRAGMA freelist_count") ?? 0,
             try Int.fetchOne(conn, sql: "PRAGMA page_size") ?? 0,
             try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppSampleRaw") ?? 0,
             try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM BatteryStatus") ?? 0)
        }
        guard let url = db.fileURL else { throw XCTSkip("Storage metrics require a file-backed database") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let walAttributes = try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")
        return StorageMetrics(pageCount: databaseStats.0, pageSize: databaseStats.2,
                              freelistCount: databaseStats.1,
                              databaseBytes: attributes[.size] as? Int64 ?? 0,
                              walBytes: walAttributes?[.size] as? Int64 ?? 0,
                              rawRows: databaseStats.3, batteryRows: databaseStats.4)
    }

    func testPruneMaintenanceReclaimsPagesWithoutGrowingFile() async throws {
        let db = try makeTemporaryDatabase()
        let nowMS = Int64(Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970 * 1000)
        let sampleStart = nowMS - 9 * 86_400_000
        var processes: [SampledApp] = []
        for index in 0..<8 {
            let value = Int64(index + 1)
            processes.append(SampledApp(groupKey: "reclaim.app", bundleIdentifier: "reclaim.app",
                                        displayName: "Reclaim", pid: Int32(20_000 + index),
                                        energyNJ: value, cpuNs: value * 10))
        }

        // 1,000 distinct 30-second windows create enough old raw and minute rows
        // to span multiple pages while hour rollups remain as retained history.
        for window in 0..<1_000 {
            try await db.writeTick(timestamp: sampleStart + Int64(window) * 30_000, apps: processes,
                                   buckets: [SampledBucket(name: "CPU", energyNJ: 100)],
                                   coverage: SampleCoverage(visible: 8, unreadable: 0))
        }
        let rollupNow = Date(timeIntervalSince1970: Double(sampleStart + 1_001 * 30_000) / 1000)
        let monotonicStart: TimeInterval = 1_000
        try await db.runMaintenance(now: rollupNow, monotonicNow: monotonicStart)
        let beforePrune = try await metrics(db)
        try await db.runMaintenance(now: Date(timeIntervalSince1970: Double(nowMS) / 1000),
                                    monotonicNow: monotonicStart + 9 * 86_400)
        let afterPrune = try await metrics(db)
        print("STORAGE_RECLAMATION before_pages=\(beforePrune.pageCount) before_freelist=\(beforePrune.freelistCount) before_db_bytes=\(beforePrune.databaseBytes) before_wal_bytes=\(beforePrune.walBytes) after_pages=\(afterPrune.pageCount) after_freelist=\(afterPrune.freelistCount) after_db_bytes=\(afterPrune.databaseBytes) after_wal_bytes=\(afterPrune.walBytes)")

        XCTAssertLessThan(afterPrune.pageCount, beforePrune.pageCount,
                          "incremental vacuum should return deleted pages from the database file")
        XCTAssertEqual(afterPrune.freelistCount, 0,
                        "incremental vacuum should drain the freelist after pruning")
        XCTAssertLessThanOrEqual(afterPrune.databaseBytes, beforePrune.databaseBytes,
                                 "the file should shrink or stay level after old history is pruned")
        XCTAssertLessThanOrEqual(afterPrune.databaseBytes + afterPrune.walBytes,
                                 beforePrune.databaseBytes + beforePrune.walBytes,
                                 "pruning and checkpointing should not increase total database plus WAL storage")
        let retainedRows = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppSampleRaw") ?? 0
        }
        XCTAssertEqual(retainedRows, 0)
    }

    func testTenDayStorageSimulation() async throws {
        guard ProcessInfo.processInfo.environment["VOLTSCOPE_STORAGE_SIMULATION"] == "1" else {
            throw XCTSkip("Set VOLTSCOPE_STORAGE_SIMULATION=1 to run the ten-day storage simulation")
        }

        let db = try makeTemporaryDatabase()
        let startMS: Int64 = 1_767_225_600_000 // 2026-01-01T00:00:00Z
        let processCount = 3
        let windowStride = 6 // Observe one of every six 30-second windows (three minutes).
        let extrapolationFactor = 660 // 3 sampled processes * 480 windows * 660 = 330 * 2,880.
        var apps: [SampledApp] = []
        for index in 0..<processCount {
            let appID = "simulation.app.\(index)"
            let value = Int64(index + 1)
            apps.append(SampledApp(groupKey: appID, bundleIdentifier: appID,
                                   displayName: "Simulation \(index)", pid: Int32(30_000 + index),
                                   energyNJ: value, cpuNs: value * 100,
                                   wakeups: 1, diskReadBytes: 64, diskWriteBytes: 32))
        }
        var daily: [StorageMetrics] = []

        for day in 0..<10 {
            let dayStart = startMS + Int64(day) * 86_400_000
            for window in 0..<2_880 {
                guard window.isMultiple(of: windowStride) else { continue }
                try await db.writeTick(timestamp: dayStart + Int64(window) * 30_000, apps: apps,
                                       buckets: [SampledBucket(name: "CPU", energyNJ: 10_000)],
                                       coverage: SampleCoverage(visible: Int64(processCount), unreadable: 0))
            }
            for tick in 0..<2_880 {
                try await db.writeBatterySnapshot(BatterySnapshot(
                    timestamp: dayStart + Int64(tick) * 30_000, levelPercent: 75,
                    capacityMAh: 5_000, designMAh: 6_000, cycleCount: 100,
                    voltageMV: 12_000, amperageMA: -500, temperatureC: 30,
                    timeRemainingMin: 120, isCharging: false, isACPlugged: false))
            }
            let maintenanceClock = Date(timeIntervalSince1970: Double(dayStart + 86_400_000) / 1000)
            try await db.runMaintenance(now: maintenanceClock)
            let current = try await metrics(db)
            daily.append(current)
            print(String(format: "STORAGE_SIMULATION day=%02d page_count=%d page_size=%d freelist_count=%d db_bytes=%lld wal_bytes=%lld raw_rows=%d battery_rows=%d extrapolation_factor=%d",
                         day + 1, current.pageCount, current.pageSize, current.freelistCount,
                         current.databaseBytes, current.walBytes, current.rawRows, current.batteryRows,
                         extrapolationFactor))
        }

        XCTAssertEqual(daily.count, 10)
        XCTAssertEqual(daily[8].rawRows, daily[9].rawRows,
                       "raw row count should reach a steady state after the seven-day retention fills")
        XCTAssertEqual(daily[9].batteryRows - daily[8].batteryRows, 2_880,
                       "battery snapshots are recorded every 30 seconds and are not currently pruned")
        XCTAssertGreaterThan(daily[9].databaseBytes, daily[8].databaseBytes,
                             "the full database continues growing while unbounded battery history is retained")
    }
}
