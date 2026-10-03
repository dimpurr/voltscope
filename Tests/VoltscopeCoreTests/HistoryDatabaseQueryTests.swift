import Foundation
import GRDB
import XCTest
@testable import VoltscopeCore

final class HistoryDatabaseQueryTests: XCTestCase {
    private struct AppRollupKey: Hashable {
        let time: Int64
        let appId: Int64
        let version: Int
    }

    private struct BucketRollupKey: Hashable {
        let time: Int64
        let bucketId: Int64
        let version: Int
    }

    private struct PointKey: Hashable {
        let appID: String
        let bucketMS: Int64
    }

    private struct HardwarePointKey: Hashable {
        let bucketName: String
        let bucketMS: Int64
    }

    private struct RawFixture {
        let ts: Int64
        let appId: Int64
        let appKey: String
        let name: String
        let pid: Int32
        let version: Int
        let energy: Int64
        let bucketId: Int64
        let bucketName: String
    }

    private func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private func interval(_ start: Int64, _ end: Int64) -> DateInterval {
        DateInterval(start: date(start), end: date(end))
    }

    private func fixture(_ range: HistoryRange, version: Int = EnergyMetric.currentVersion) async throws -> (HistoryDatabase, [RawFixture], Int64) {
        let db = try HistoryDatabase.makeInMemory()
        let seconds = Int64(range.minutes) * 60
        let end = seconds * 1000
        let alpha = try await db.upsertApp(groupKey: "com.example.alpha", bundleIdentifier: "com.example.alpha", displayName: "Alpha", path: "/Apps/Alpha.app", ts: 0)
        let beta = try await db.upsertApp(groupKey: "com.example.beta", bundleIdentifier: "com.example.beta", displayName: "Beta", path: "/Apps/Beta.app", ts: 0)
        let cpu = try await db.upsertBucket(name: "CPU")
        let gpu = try await db.upsertBucket(name: "GPU")
        let points: [(Int64, Int64, String, String, Int32, Int64, Int64, String)] = [
            (0, alpha, "com.example.alpha", "Alpha", 11, 7, cpu, "CPU"),
            (35_000, alpha, "com.example.alpha", "Alpha", 11, 11, cpu, "CPU"),
            (105_000, beta, "com.example.beta", "Beta", 22, 3, gpu, "GPU"),
            (end / 3 + 15_000, alpha, "com.example.alpha", "Alpha", 11, 13, gpu, "GPU"),
            (end - 120_000, beta, "com.example.beta", "Beta", 22, 17, cpu, "CPU"),
            (end - 30_000, alpha, "com.example.alpha", "Alpha", 11, 19, cpu, "CPU")
        ].filter { $0.0 >= 0 && $0.0 < end }
        let rows = points.map { RawFixture(ts: $0.0, appId: $0.1, appKey: $0.2, name: $0.3, pid: $0.4, version: version, energy: $0.5, bucketId: $0.6, bucketName: $0.7) }
        let watermark: Int64? = switch range {
        case .live: nil
        case .d7: seconds / 3600 - 2
        default: seconds / 60 - 2
        }
        try await db.dbPool.write { conn in
            for row in rows {
                try AppSampleRaw(ts: row.ts, appId: row.appId, pid: row.pid, parentPid: nil, metricVersion: row.version,
                                 energyNJ: row.energy, cpuNs: row.energy * 2, wakeups: 1,
                                 diskReadBytes: row.energy * 3, diskWriteBytes: row.energy * 4).insert(conn)
                try BucketSampleRaw(ts: row.ts, bucketId: row.bucketId, metricVersion: row.version, energyNJ: row.energy).insert(conn)
            }
            if let watermark {
                let unit: Int64 = range == .d7 ? 3_600_000 : 60_000
                let cutoff = (watermark + 1) * unit
                let covered = rows.filter { $0.ts < cutoff }
                let appGroups = Dictionary(grouping: covered, by: { AppRollupKey(time: $0.ts / unit, appId: $0.appId, version: $0.version) })
                for (key, values) in appGroups {
                    let energy = values.reduce(Int64(0)) { $0 + $1.energy }
                    let cpuNs = values.reduce(Int64(0)) { $0 + $1.energy * 2 }
                    if range == .d7 {
                        try AppUsageHour(hour: key.time, appId: key.appId, metricVersion: key.version, energyNJ: energy,
                                         cpuNs: cpuNs, wakeups: Int64(values.count), diskReadBytes: energy * 3,
                                         diskWriteBytes: energy * 4, samples: Int64(values.count)).insert(conn)
                    } else {
                        try AppUsageMinute(minute: key.time, appId: key.appId, metricVersion: key.version, energyNJ: energy,
                                           cpuNs: cpuNs, wakeups: Int64(values.count), diskReadBytes: energy * 3,
                                           diskWriteBytes: energy * 4, samples: Int64(values.count)).insert(conn)
                    }
                }
                let bucketGroups = Dictionary(grouping: covered, by: { BucketRollupKey(time: $0.ts / unit, bucketId: $0.bucketId, version: $0.version) })
                for (key, values) in bucketGroups {
                    let energy = values.reduce(Int64(0)) { $0 + $1.energy }
                    if range == .d7 {
                        try BucketHour(hour: key.time, bucketId: key.bucketId, metricVersion: key.version, energyNJ: energy).insert(conn)
                    } else {
                        try BucketMinute(minute: key.time, bucketId: key.bucketId, metricVersion: key.version, energyNJ: energy).insert(conn)
                    }
                }
                let key = range == .d7 ? "rollup.hourWatermark" : "rollup.minuteWatermark"
                try conn.execute(sql: "INSERT INTO Meta (key, value) VALUES (?, ?)", arguments: [key, String(watermark)])
            }
        }
        return (db, rows, end)
    }

    private func expectedEnergy(_ rows: [RawFixture], range: HistoryRange, version: Int) -> [HistoryEnergyPoint] {
        let width = Int64(range.bucketSeconds) * 1000
        let groups = Dictionary(grouping: rows.filter { $0.version == version }, by: { PointKey(appID: $0.appKey, bucketMS: ($0.ts / width) * width) })
        return groups.map { key, values in
            HistoryEnergyPoint(appID: key.appID, name: values[0].name, bundleIdentifier: key.appID,
                               path: key.appID.hasSuffix("alpha") ? "/Apps/Alpha.app" : "/Apps/Beta.app",
                               isSystem: false, date: date(key.bucketMS), energyNJ: values.reduce(0) { $0 + $1.energy },
                               cpuNS: values.reduce(0) { $0 + $1.energy * 2 })
        }.sorted { $0.date == $1.date ? $0.appID < $1.appID : $0.date < $1.date }
    }

    func testAllRangesMatchDirectRawAggregationIncludingRawTail() async throws {
        for range in HistoryRange.allCases {
            let (db, raw, end) = try await fixture(range)
            let actual = try await db.historyEnergy(in: interval(0, end), range: range)
            XCTAssertEqual(actual, expectedEnergy(raw, range: range, version: EnergyMetric.currentVersion), "range \(range.rawValue)")
            let tail = raw.filter { $0.ts >= end - 60_000 }
            XCTAssertFalse(tail.isEmpty)
            XCTAssertTrue(actual.contains { point in tail.contains { $0.appKey == point.appID && $0.energy > 0 && point.date == date(($0.ts / Int64(range.bucketSeconds * 1000)) * Int64(range.bucketSeconds * 1000)) } }, "tail should contribute for \(range.rawValue)")
        }
    }

    func testHistoryAppBreakdownUsesSameTierRoutingAsChart() async throws {
        let (db, _, end) = try await fixture(.d7)
        let window = interval(0, end)
        let chart = try await db.historyEnergy(in: window, range: .d7)
        let expected = Dictionary(uniqueKeysWithValues: HistoryMath.apps(chart).map {
            HistoryDatabase.AppBreakdownEntry(bundleIdentifier: $0.bundleIdentifier, processName: $0.name,
                                              path: $0.path, totalEnergyNJ: $0.energyNJ, totalCPUNS: $0.cpuNS,
                                              isSystem: $0.isSystem)
        }.map { ($0.id, $0) })
        let actual = try await db.historyAppBreakdown(in: window, range: .d7)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0.totalEnergyNJ) }),
                       expected.mapValues(\.totalEnergyNJ))
        XCTAssertGreaterThan(actual.reduce(Int64(0)) { $0 + $1.totalEnergyNJ }, 0)
    }

    func testRawCSVIntervalClipsToConfiguredRetention() async throws {
        let db = try HistoryDatabase.makeInMemory()
        try await db.setRawRetentionDays(2)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let requested = DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
        let actual = try await db.rawCSVInterval(in: requested, now: now)
        XCTAssertEqual(actual.start, now.addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(actual.end, now)
    }

    func testIntelMenuBarPresentationUsesCPUWithoutEnergyJoules() {
        XCTAssertEqual(MenuBarMetricPresentation.value(energyNJ: 0, cpuNS: 8_000_000_000, energyAvailable: false), 8_000_000_000)
        XCTAssertEqual(MenuBarMetricPresentation.systemSummary(count: 3, energyNJ: 0, cpuNS: 8_000_000_000, energyAvailable: false), "3 procs · 8.0 s CPU")
        XCTAssertEqual(MenuBarMetricPresentation.systemSummary(count: 3, energyNJ: 0, cpuNS: 8_000_000_000, energyAvailable: true), "3 procs · 0.00 J")
    }

    func testRoutedHistoryAppBreakdownKeepsIntelCPUOnlyRows() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let appID = try await db.upsertApp(groupKey: "com.example.intel", bundleIdentifier: "com.example.intel",
                                           displayName: "Intel App", path: "/Apps/Intel.app", ts: 0)
        try await db.dbPool.write { conn in
            try AppSampleRaw(ts: 1_000, appId: appID, pid: 77, parentPid: nil,
                             metricVersion: EnergyMetric.currentVersion, energyNJ: 0, cpuNs: 4_000_000_000,
                             wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0).insert(conn)
        }
        let rows = try await db.historyAppBreakdown(in: interval(0, 30_000), range: .live)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].totalEnergyNJ, 0)
        XCTAssertEqual(rows[0].totalCPUNS, 4_000_000_000)
    }

    func testIntelHistoryAndMenuBarRankBusyAppsByCPUTime() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let nowMS = Int64(Date().timeIntervalSince1970 * 1000)
        let idleID = try await db.upsertApp(groupKey: "a.idle", bundleIdentifier: "a.idle",
                                            displayName: "Idle", path: "/Apps/Idle.app", ts: nowMS)
        let busyID = try await db.upsertApp(groupKey: "z.busy", bundleIdentifier: "z.busy",
                                            displayName: "Busy", path: "/Apps/Busy.app", ts: nowMS)
        try await db.dbPool.write { conn in
            for (appID, cpuNS) in [(idleID, Int64(1_000_000_000)), (busyID, Int64(9_000_000_000))] {
                try AppSampleRaw(ts: nowMS, appId: appID, pid: 77, parentPid: nil,
                                 metricVersion: EnergyMetric.currentVersion, energyNJ: 0, cpuNs: cpuNS,
                                 wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0).insert(conn)
            }
        }

        let history = try await db.historyAppBreakdown(in: interval(nowMS - 30_000, nowMS + 30_000), range: .live,
                                                       energyAvailable: false)
        let menuBar = try await db.topApps(sinceMinutes: 30, energyAvailable: false)
        XCTAssertEqual(history.map(\.id), ["z.busy", "a.idle"])
        XCTAssertEqual(menuBar.map(\.id), ["z.busy", "a.idle"])
    }

    func testHardwareRollupsAndRawTailMatchRawTotals() async throws {
        for range in HistoryRange.allCases {
            let (db, raw, end) = try await fixture(range)
            let actual = try await db.historyHardware(in: interval(0, end), range: range)
            let width = Int64(range.bucketSeconds) * 1000
            let groups = Dictionary(grouping: raw, by: { HardwarePointKey(bucketName: $0.bucketName, bucketMS: ($0.ts / width) * width) })
            var expected: [(String, Int64, Int64)] = []
            for (key, values) in groups {
                let total = values.reduce(Int64(0)) { partial, row in partial + row.energy }
                expected.append((key.bucketName, key.bucketMS, total))
            }
            expected.sort { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
            var observed: [(String, Int64, Int64)] = []
            for item in actual {
                for point in item.sparkline {
                    let bucketMS = Int64(point.bucketStart.timeIntervalSince1970 * 1000)
                    observed.append((item.bucketName, bucketMS, point.energyNJ))
                }
            }
            observed.sort { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
            XCTAssertEqual(observed.map { "\($0.0)|\($0.1)|\($0.2)" }, expected.map { "\($0.0)|\($0.1)|\($0.2)" }, "range \(range.rawValue)")
        }
    }

    func testUnalignedBoundsUseRawForPartialTierEdges() async throws {
        let (db, _, _) = try await fixture(.h1)
        let partial = interval(30_000, 150_000)
        let energy = try await db.historyEnergy(in: partial, range: .h1)
        XCTAssertEqual(energy.map(\.energyNJ).reduce(0, +), 14)
        XCTAssertEqual(energy.first(where: { $0.appID == "com.example.alpha" })?.energyNJ, 11)
        XCTAssertEqual(energy.first(where: { $0.appID == "com.example.beta" })?.energyNJ, 3)
        let hardware = try await db.historyHardware(in: partial, range: .h1)
        XCTAssertEqual(hardware.first(where: { $0.bucketName == "CPU" })?.totalEnergyNJ, 11)
        XCTAssertEqual(hardware.first(where: { $0.bucketName == "GPU" })?.totalEnergyNJ, 3)
    }

    func testMetricVersionsAreIsolatedAndOlderBucketsAreReported() async throws {
        let (db, _, end) = try await fixture(.h1)
        let appId = try await db.upsertApp(groupKey: "com.example.alpha", bundleIdentifier: "com.example.alpha", displayName: "Alpha", path: "/Apps/Alpha.app", ts: 0)
        try await db.dbPool.write { conn in
            try AppSampleRaw(ts: end - 30_000, appId: appId, pid: 11, parentPid: nil, metricVersion: EnergyMetric.legacyVersion,
                             energyNJ: 10_000, cpuNs: 77, wakeups: 1, diskReadBytes: 0, diskWriteBytes: 0).insert(conn)
            try AppUsageMinute(minute: 3, appId: appId, metricVersion: EnergyMetric.legacyVersion, energyNJ: 20_000,
                               cpuNs: 55, wakeups: 1, diskReadBytes: 0, diskWriteBytes: 0, samples: 1).insert(conn)
        }
        let current = try await db.historyEnergy(in: interval(0, end), range: .h1)
        XCTAssertFalse(current.contains { $0.energyNJ >= 10_000 })
        let legacy = try await db.historyEnergy(in: interval(0, end), range: .h1, metricVersion: EnergyMetric.legacyVersion)
        XCTAssertEqual(legacy.reduce(0) { $0 + $1.energyNJ }, 30_000)
        let coverage = try await db.metricVersionCoverage(in: interval(0, end), range: .h1)
        XCTAssertTrue(coverage.hasOlderData)
        XCTAssertTrue(coverage.bucketStarts.contains(date(120_000)))
        XCTAssertTrue(coverage.bucketStarts.contains(date((end - 30_000) / 120_000 * 120_000)))
    }

    func testEmptyDatabaseQueriesAreEmpty() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let energy = try await db.historyEnergy(in: interval(0, 3_600_000), range: .h1)
        let hardware = try await db.historyHardware(in: interval(0, 3_600_000), range: .h1)
        let coverage = try await db.metricVersionCoverage(in: interval(0, 3_600_000), range: .h1)
        XCTAssertTrue(energy.isEmpty)
        XCTAssertTrue(hardware.isEmpty)
        XCTAssertFalse(coverage.hasOlderData)
    }

    func testHourOnlyOlderIntervalCanBeQueried() async throws {
        let (db, raw, end) = try await fixture(.d7)
        let point = try XCTUnwrap(raw.first)
        let legacyHour = AppUsageHour(hour: point.ts / 3_600_000, appId: point.appId, metricVersion: EnergyMetric.legacyVersion,
                                      energyNJ: 91, cpuNs: 12, wakeups: 1, diskReadBytes: 0, diskWriteBytes: 0, samples: 1)
        try await db.dbPool.write { conn in try legacyHour.insert(conn) }
        let oldIntervalEnd: Int64 = 3_600_000
        let legacy = try await db.historyEnergy(in: interval(0, oldIntervalEnd), range: .d7, metricVersion: EnergyMetric.legacyVersion)
        XCTAssertEqual(legacy.reduce(0) { $0 + $1.energyNJ }, 91)
        XCTAssertEqual(legacy.first?.date, date(0))
        let exported = try await db.historySamplesForCSV(in: interval(0, end))
        XCTAssertGreaterThan(exported.count, 0)
    }

    func testBatteryAndEventsKeepLegacyQueryBoundsAndPredecessor() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let before = BatterySnapshot(timestamp: 9_000, levelPercent: 51, capacityMAh: 4_000, designMAh: 4_500,
                                     cycleCount: 12, voltageMV: 11_000, amperageMA: -800, temperatureC: 30,
                                     timeRemainingMin: 90, isCharging: false, isACPlugged: false)
        let atEnd = BatterySnapshot(timestamp: 20_000, levelPercent: 50, capacityMAh: 4_000, designMAh: 4_500,
                                    cycleCount: 12, voltageMV: 11_000, amperageMA: -900, temperatureC: 31,
                                    timeRemainingMin: 80, isCharging: false, isACPlugged: false)
        try await db.dbPool.write { conn in
            try before.insert(conn)
            try atEnd.insert(conn)
            try PowerEvent(timestamp: 5_000, eventType: .sleep).insert(conn)
            try PowerEvent(timestamp: 12_000, eventType: .wake).insert(conn)
            try PowerEvent(timestamp: 21_000, eventType: .plug).insert(conn)
        }
        let snapshots = try await db.batteryHistory(in: interval(10_000, 20_000))
        XCTAssertEqual(snapshots, [before, atEnd])
        let events = try await db.historyEvents(in: interval(10_000, 20_000))
        XCTAssertEqual(events.map(\.timestamp), [5_000, 12_000])
    }

    func testCSVQueryReturnsRawDetailColumnsFromAppDictionary() async throws {
        XCTAssertEqual(HistoryDatabase.CSVSample.columnNames, [
            "timestamp_ms", "iso8601", "pid", "parent_pid", "bundle_id", "process_name", "path",
            "cpu_ns", "energy_nj", "wakeups", "disk_read_bytes", "disk_write_bytes", "metric_version"
        ])
        let (db, raw, end) = try await fixture(.live)
        let samples = try await db.historySamplesForCSV(in: interval(0, end))
        XCTAssertEqual(samples.count, raw.count)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.timestampMS, 0)
        XCTAssertEqual(Array(sample.iso8601.utf8), Array("1970-01-01T00:00:00Z".utf8))
        XCTAssertEqual(sample.pid, 11)
        XCTAssertNil(sample.parentPid)
        XCTAssertEqual(sample.bundleID, "com.example.alpha")
        XCTAssertEqual(sample.processName, "Alpha")
        XCTAssertEqual(sample.path, "/Apps/Alpha.app")
        XCTAssertEqual(sample.cpuNS, 14)
        XCTAssertEqual(sample.energyNJ, 7)
        XCTAssertEqual(sample.wakeups, 1)
        XCTAssertEqual(sample.diskReadBytes, 21)
        XCTAssertEqual(sample.diskWriteBytes, 28)
        XCTAssertEqual(sample.metricVersion, EnergyMetric.currentVersion)
        XCTAssertTrue(sample.iso8601.hasSuffix("Z"))

        let exportedLine = sample.csvLine(iso8601: "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(Array(exportedLine.utf8), Array("0,1970-01-01T00:00:00.000Z,11,,com.example.alpha,Alpha,/Apps/Alpha.app,14,7,1,21,28,1\n".utf8))
    }
}
