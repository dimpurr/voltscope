import Foundation
import GRDB
import XCTest
@testable import VoltscopeCore

/// Opt-in microbenchmarks for the routine 330-process flush and seven-day chart query.
/// Run with VOLTSCOPE_SELF_COST_BENCHMARK=1 swift test --disable-keychain --filter SelfCostBenchmarkTests.
final class SelfCostBenchmarkTests: XCTestCase {
    func testFlush330ProcessesAndSevenDayQuery() async throws {
        guard ProcessInfo.processInfo.environment["VOLTSCOPE_SELF_COST_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VOLTSCOPE_SELF_COST_BENCHMARK=1 to run the self-cost microbenchmark")
        }

        let flushDB = try HistoryDatabase.makeInMemory()
        let nowMS = Int64(Date().timeIntervalSince1970 * 1000) / 30_000 * 30_000
        var apps: [SampledApp] = []
        apps.reserveCapacity(330)
        for index in 0..<330 {
            let groupIndex = index / 3
            apps.append(SampledApp(groupKey: "benchmark.app.\(groupIndex)",
                                   bundleIdentifier: "benchmark.app.\(groupIndex)",
                                   displayName: "Benchmark \(groupIndex)", pid: Int32(10_000 + index),
                                   energyNJ: Int64(index + 1), cpuNs: Int64((index + 1) * 100), wakeups: 1,
                                   diskReadBytes: 64, diskWriteBytes: 32))
        }
        var flushTimes: [Double] = []
        for iteration in 0..<7 {
            try await flushDB.writeTick(timestamp: nowMS + Int64(iteration * 30_000), apps: apps, buckets: [],
                                        coverage: SampleCoverage(visible: 330, unreadable: 0))
            let start = DispatchTime.now().uptimeNanoseconds
            try await flushDB.flushPendingWindow()
            flushTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }

        let queryDB = try HistoryDatabase.makeInMemory()
        let hourNow = Int64(Date().timeIntervalSince1970 / 3600)
        try await queryDB.dbPool.write { db in
            var ids: [Int64] = []
            ids.reserveCapacity(330)
            for index in 0..<330 {
                let key = "benchmark.query.app.\(index)"
                let id = try Int64.fetchOne(db, sql: """
                    INSERT INTO App (groupKey, bundleIdentifier, displayName, firstSeen, lastSeen)
                    VALUES (?, ?, ?, ?, ?) RETURNING id
                    """, arguments: [key, key, "Query \(index)", hourNow * 3600_000, hourNow * 3600_000])!
                ids.append(id)
            }
            for offset in 0..<168 {
                let hour = hourNow - Int64(167 - offset)
                for index in 0..<330 {
                    try AppUsageHour(hour: hour, appId: ids[index], metricVersion: EnergyMetric.currentVersion,
                                     energyNJ: Int64(index + offset + 1), cpuNs: Int64((index + 1) * 1000),
                                     wakeups: 1, diskReadBytes: 64, diskWriteBytes: 32, samples: 6).insert(db)
                }
            }
        }
        let interval = DateInterval(start: Date(timeIntervalSince1970: Double((hourNow - 168) * 3600)), end: Date())
        var queryTimes: [Double] = []
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            let rows = try await queryDB.historyEnergy(in: interval, range: .d7)
            queryTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(rows.count, 330 * 28)
        }

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }
        print(String(format: "SELF_COST_BENCHMARK flush330_ms median=%.3f samples=%@", median(flushTimes), flushTimes.map { String(format: "%.3f", $0) }.joined(separator: ",")))
        print(String(format: "SELF_COST_BENCHMARK query7d_ms median=%.3f rollupRows=%d chartPoints=%d samples=%@", median(queryTimes), 330 * 168, 330 * 28, queryTimes.map { String(format: "%.3f", $0) }.joined(separator: ",")))
    }
}
