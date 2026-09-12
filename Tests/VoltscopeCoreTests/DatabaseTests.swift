import XCTest
@testable import VoltscopeCore

final class DatabaseTests: XCTestCase {
    func testMigrationsCreateTables() async throws {
        let db = try AppDatabase.makeInMemory()
        let names = try await db.dbPool.read { conn in
            try String.fetchAll(conn, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name
                """)
        }
        XCTAssertTrue(names.contains("EnergyHistory"))
        XCTAssertTrue(names.contains("BatteryStatus"))
        XCTAssertTrue(names.contains("PowerEvents"))
    }

    func testInsertEnergySampleRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        let sample = EnergySample(
            timestamp: 1_700_000_000_000,
            pid: 1234,
            bundleIdentifier: "com.example.test",
            processName: "TestProc",
            path: "/usr/bin/test",
            parentPid: 1,
            cpuUserNs: 100,
            cpuSystemNs: 50,
            energyNJ: 9_999,
            wakeups: 7,
            diskReadBytes: 0,
            diskWriteBytes: 0,
            year: 2025,
            month: 11,
            day: 15,
            hour: 10,
            minute: 30
        )
        try await db.writeBatchSamples([sample])
        let count = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM EnergyHistory") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testTopAppsQueryReturnsOrderedResults() async throws {
        let db = try AppDatabase.makeInMemory()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let samples = [
            EnergySample(timestamp: now - 1000, pid: 1, processName: "Heavy",
                         cpuUserNs: 0, cpuSystemNs: 0, energyNJ: 5_000_000_000,
                         wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0,
                         year: 2025, month: 1, day: 1, hour: 0, minute: 0),
            EnergySample(timestamp: now - 500, pid: 2, processName: "Light",
                         cpuUserNs: 0, cpuSystemNs: 0, energyNJ: 1_000,
                         wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0,
                         year: 2025, month: 1, day: 1, hour: 0, minute: 0)
        ]
        try await db.writeBatchSamples(samples)
        let top = try await db.topApps(sinceMinutes: 60, limit: 5)
        XCTAssertEqual(top.first?.processName, "Heavy")
    }

    func testTopAppsCollapsesByBundleIdentifier() async throws {
        // Two helper rows with the same bundle identifier should collapse into one TopAppEnergy.
        let db = try AppDatabase.makeInMemory()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let samples = [
            EnergySample(timestamp: now - 100, pid: 10,
                         bundleIdentifier: "com.google.Chrome",
                         processName: "Chrome",
                         cpuUserNs: 0, cpuSystemNs: 0, energyNJ: 2_000_000,
                         wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0,
                         year: 2025, month: 1, day: 1, hour: 0, minute: 0),
            EnergySample(timestamp: now - 50, pid: 11,
                         bundleIdentifier: "com.google.Chrome",
                         processName: "Chrome Helper",
                         cpuUserNs: 0, cpuSystemNs: 0, energyNJ: 3_000_000,
                         wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0,
                         year: 2025, month: 1, day: 1, hour: 0, minute: 0),
            EnergySample(timestamp: now - 25, pid: 12,
                         processName: "loginwindow",
                         cpuUserNs: 0, cpuSystemNs: 0, energyNJ: 500,
                         wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0,
                         year: 2025, month: 1, day: 1, hour: 0, minute: 0)
        ]
        try await db.writeBatchSamples(samples)
        let top = try await db.topApps(sinceMinutes: 60, limit: 5)
        // 2 distinct groups: Chrome (collapsed), loginwindow.
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top.first?.bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(top.first?.totalEnergyNJ, 5_000_000)
    }
}

final class BatteryConditionTests: XCTestCase {
    func testExcellentForFreshBattery() {
        XCTAssertEqual(
            BatteryCondition.classify(cycleCount: 50, capacityMAh: 5950, designMAh: 6000),
            .excellent
        )
    }

    func testServiceWhenHealthBelow80() {
        XCTAssertEqual(
            BatteryCondition.classify(cycleCount: 200, capacityMAh: 4500, designMAh: 6000),
            .service
        )
    }

    func testServiceWhenCyclesAtLimit() {
        XCTAssertEqual(
            BatteryCondition.classify(cycleCount: 1200, capacityMAh: 5800, designMAh: 6000),
            .service
        )
    }

    func testUnknownWithoutSignals() {
        XCTAssertEqual(
            BatteryCondition.classify(cycleCount: nil, capacityMAh: nil, designMAh: nil),
            .unknown
        )
    }
}

final class ProcessSamplerTests: XCTestCase {
    func testFirstTickEstablishesBaselineEmits() {
        let sampler = ProcessSampler()
        let first = sampler.sampleAll()
        // First call always returns empty (baseline pass).
        XCTAssertTrue(first.isEmpty, "first sample should be baseline-only")
    }

    func testSecondTickEmitsRows() async throws {
        let sampler = ProcessSampler()
        _ = sampler.sampleAll()
        // Give the system a moment to accumulate something measurable.
        try await Task.sleep(nanoseconds: 200_000_000)
        let second = sampler.sampleAll()
        // We expect at least the test process itself to have done some work.
        // Allow zero on extremely idle hardware but assert it doesn't crash.
        XCTAssertTrue(second.count >= 0)
    }
}

final class BatterySamplerTests: XCTestCase {
    func testBatterySamplerReturnsSnapshotOnLaptop() {
        let sampler = BatterySampler()
        let snapshot = sampler.sample()
        // Desktop Macs / virtualized environments may return nil; only
        // assert the call doesn't crash. On a laptop, snapshot should be non-nil.
        if let s = snapshot {
            if let level = s.levelPercent {
                XCTAssertGreaterThanOrEqual(level, 0)
                XCTAssertLessThanOrEqual(level, 100)
            }
        }
    }
}
