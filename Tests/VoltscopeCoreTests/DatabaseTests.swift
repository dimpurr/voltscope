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
        let db = try HistoryDatabase.makeInMemory()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.writeTick(timestamp: now, apps: [
            SampledApp(groupKey: "heavy", displayName: "Heavy", pid: 1, energyNJ: 5_000_000_000, cpuNs: 1),
            SampledApp(groupKey: "light", displayName: "Light", pid: 2, energyNJ: 1_000, cpuNs: 1)
        ], buckets: [], coverage: SampleCoverage(visible: 2, unreadable: 0))
        try await db.flushPendingWindow()
        let top = try await db.topApps(sinceMinutes: 60, limit: 5)
        XCTAssertEqual(top.first?.processName, "Heavy")
    }

    func testTopAppsCollapsesByBundleIdentifier() async throws {
        // Two helper rows with the same bundle identifier should collapse into one TopAppEnergy.
        let db = try HistoryDatabase.makeInMemory()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.writeTick(timestamp: now, apps: [
            SampledApp(groupKey: "com.google.Chrome", bundleIdentifier: "com.google.Chrome", displayName: "Chrome", pid: 10, energyNJ: 2_000_000, cpuNs: 1),
            SampledApp(groupKey: "com.google.Chrome", bundleIdentifier: "com.google.Chrome", displayName: "Chrome Helper", pid: 11, energyNJ: 3_000_000, cpuNs: 1),
            SampledApp(groupKey: "loginwindow", displayName: "loginwindow", pid: 12, energyNJ: 500, cpuNs: 1)
        ], buckets: [], coverage: SampleCoverage(visible: 3, unreadable: 0))
        try await db.flushPendingWindow()
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
        XCTAssertTrue(first.samples.isEmpty, "first sample should be baseline-only")
    }

    func testSecondTickEmitsRows() async throws {
        let sampler = ProcessSampler()
        _ = sampler.sampleAll()
        // Give the system a moment to accumulate something measurable.
        try await Task.sleep(nanoseconds: 200_000_000)
        let second = sampler.sampleAll()
        XCTAssertTrue(
            samplesMatchExpectedActivity(second.samples, energyAvailable: sampler.energyAvailable),
            "second sample should report activity using the metrics available on this Mac"
        )
    }

    func testSampleActivityExpectationRejectsEmptyResultsAndAcceptsEachPlatform() {
        let baseline = snapshot(energy: 1_000, cpuUser: 100, cpuSystem: 50)
        let energySample = delta(baseline, snapshot(energy: 1_001, cpuUser: 200, cpuSystem: 75))!
        let cpuSample = delta(
            baseline,
            snapshot(energy: 1_000, cpuUser: 200, cpuSystem: 75),
            energyAvailable: false
        )!

        XCTAssertFalse(samplesMatchExpectedActivity([], energyAvailable: true))
        XCTAssertFalse(samplesMatchExpectedActivity([], energyAvailable: false))
        XCTAssertTrue(samplesMatchExpectedActivity([energySample], energyAvailable: true))
        XCTAssertTrue(samplesMatchExpectedActivity([cpuSample], energyAvailable: false))
        XCTAssertFalse(samplesMatchExpectedActivity([cpuSample], energyAvailable: true))
        XCTAssertFalse(samplesMatchExpectedActivity([energySample], energyAvailable: false))
    }

    private func samplesMatchExpectedActivity(_ samples: [EnergySample], energyAvailable: Bool) -> Bool {
        guard !samples.isEmpty else { return false }
        if energyAvailable {
            // Apple Silicon reports per-process DPE energy.
            return samples.allSatisfy { $0.energyNJ > 0 }
        }
        // Intel reports CPU activity without per-process DPE energy.
        return samples.allSatisfy {
            $0.energyNJ == 0 && ($0.cpuUserNs > 0 || $0.cpuSystemNs > 0)
        }
    }

    private func snapshot(
        pid: Int32 = 4321,
        start: UInt64 = 1_000,
        energy: UInt64,
        bundleIdentifier: String = "com.example.test",
        cpuUser: UInt64 = 0,
        cpuSystem: UInt64 = 0,
        wakeups: UInt64 = 0,
        diskRead: UInt64 = 0,
        diskWrite: UInt64 = 0
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            parentPid: 1,
            bundleIdentifier: bundleIdentifier,
            processName: "TestProc",
            path: "/usr/bin/test",
            cpuUserNs: cpuUser,
            cpuSystemNs: cpuSystem,
            energyTotal: energy,
            wakeupsTotal: wakeups,
            diskReadTotal: diskRead,
            diskWriteTotal: diskWrite,
            procStartAbstime: start
        )
    }

    private func delta(_ prior: ProcessSnapshot?, _ current: ProcessSnapshot, energyAvailable: Bool = true) -> EnergySample? {
        ProcessSampler.deltaSample(
            from: prior,
            to: current,
            timestamp: 1_700_000_000_000,
            year: 2026,
            month: 10,
            day: 2,
            hour: 12,
            minute: 0,
            energyAvailable: energyAvailable
        )
    }

    func testZeroEnergyDeltaWithCPUWorkEmitsNoRow() {
        let prior = snapshot(energy: 5_000, cpuUser: 100, cpuSystem: 50)
        let current = snapshot(energy: 5_000, cpuUser: 3_100, cpuSystem: 2_050)
        // CPU time advanced, but no new energy was billed: no row.
        XCTAssertNil(delta(prior, current))
    }

    func testUnavailableEnergyRetainsCPUWorkThroughRollupsAndHistoryOrdering() async throws {
        let prior = snapshot(energy: 5_000, cpuUser: 100, cpuSystem: 50)
        let busy = delta(prior, snapshot(energy: 5_000, cpuUser: 3_100, cpuSystem: 2_050), energyAvailable: false)
        let light = delta(prior, snapshot(pid: 4322, start: 1_001, energy: 5_000,
                                          bundleIdentifier: "com.example.light", cpuUser: 1_100, cpuSystem: 550), energyAvailable: false)
        XCTAssertEqual(busy?.energyNJ, 0)
        XCTAssertEqual(busy?.cpuUserNs, 3_000)
        XCTAssertEqual(busy?.cpuSystemNs, 2_000)
        XCTAssertEqual(light?.energyNJ, 0)
        XCTAssertEqual(light?.cpuUserNs, 1_000)
        XCTAssertEqual(light?.cpuSystemNs, 500)

        let db = try HistoryDatabase.makeInMemory()
        let now = Date()
        let nowMinute = Int64(now.timeIntervalSince1970 / 60)
        let timestamp = (nowMinute - 180) * 60_000
        let samples = [busy, light].compactMap { $0 }
        try await db.writeTick(timestamp: timestamp, apps: samples.map { sample in
            SampledApp(groupKey: sample.bundleIdentifier ?? sample.processName,
                       bundleIdentifier: sample.bundleIdentifier, displayName: sample.processName,
                       path: sample.path, pid: sample.pid, parentPid: sample.parentPid,
                       energyNJ: sample.energyNJ, cpuNs: sample.cpuUserNs + sample.cpuSystemNs,
                       wakeups: sample.wakeups, diskReadBytes: sample.diskReadBytes,
                       diskWriteBytes: sample.diskWriteBytes)
        }, buckets: [], coverage: SampleCoverage(visible: 2, unreadable: 0), energyUnavailable: true)
        try await db.flushPendingWindow()

        let raw = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppSampleRaw WHERE energyNJ=0 AND cpuNs>0") ?? 0
        }
        XCTAssertEqual(raw, 2)

        try await db.runMaintenance(now: now)
        let rollups = try await db.dbPool.read { conn in
            (
                try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppUsageMinute WHERE energyNJ=0 AND cpuNs>0") ?? 0,
                try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppUsageHour WHERE energyNJ=0 AND cpuNs>0") ?? 0
            )
        }
        XCTAssertEqual(rollups.0, 2)
        XCTAssertEqual(rollups.1, 2)

        let hourStart = timestamp / 3_600_000 * 3_600_000
        let interval = DateInterval(start: Date(timeIntervalSince1970: Double(hourStart) / 1000),
                                    end: Date(timeIntervalSince1970: Double(hourStart + 3_600_000) / 1000))
        let rows = try await db.historyAppBreakdown(in: interval, range: .d7, energyAvailable: false)
        XCTAssertEqual(rows.map(\.totalCPUNS), [5_000, 1_500])
        XCTAssertTrue(rows.allSatisfy { $0.totalEnergyNJ == 0 })
    }

    func testPositiveEnergyDeltaEmitsRowWithCorrectDeltas() {
        let prior = snapshot(energy: 1_000, cpuUser: 10, cpuSystem: 5,
                             wakeups: 2, diskRead: 100, diskWrite: 200)
        let current = snapshot(energy: 4_500, cpuUser: 110, cpuSystem: 45,
                               wakeups: 12, diskRead: 400, diskWrite: 700)
        let row = delta(prior, current)
        XCTAssertEqual(row?.energyNJ, 3_500)
        XCTAssertEqual(row?.cpuUserNs, 100)
        XCTAssertEqual(row?.cpuSystemNs, 40)
        XCTAssertEqual(row?.wakeups, 10)
        XCTAssertEqual(row?.diskReadBytes, 300)
        XCTAssertEqual(row?.diskWriteBytes, 500)
        XCTAssertEqual(row?.pid, 4321)
        XCTAssertEqual(row?.processName, "TestProc")
        XCTAssertEqual(row?.timestamp, 1_700_000_000_000)
    }

    func testCounterRegressionClampsToZeroAndEmitsNoRow() {
        XCTAssertEqual(ProcessSampler.saturatingDelta(4_000, 9_000), 0)
        let prior = snapshot(energy: 9_000, cpuUser: 5_000)
        let current = snapshot(energy: 4_000, cpuUser: 100)
        // A regressed cumulative counter (e.g. PID reuse) is treated as no delta.
        XCTAssertNil(delta(prior, current))
    }

    func testFirstSightingEmitsNoRow() {
        let current = snapshot(energy: 8_000, cpuUser: 500)
        // No baseline yet: the sampler only records it.
        XCTAssertNil(delta(nil, current))
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
