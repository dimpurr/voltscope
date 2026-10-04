import Foundation
import GRDB
import XCTest
@testable import VoltscopeCore

private final class CSVExportTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var callbackCount = 0

    func set(_ task: Task<Void, Error>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func recordCallback() {
        lock.lock()
        callbackCount += 1
        lock.unlock()
    }

    var recordedCallbacks: Int {
        lock.lock()
        defer { lock.unlock() }
        return callbackCount
    }
}

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
        let path: String
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
        let points: [(Int64, Int64, String, String, String, Int32, Int64, Int64, String)] = [
            (0, alpha, "com.example.alpha", "Alpha", "/Apps/Alpha.app", 11, 7, cpu, "CPU"),
            (35_000, alpha, "com.example.alpha", "Alpha", "/Apps/Alpha.app", 11, 11, cpu, "CPU"),
            (105_000, beta, "com.example.beta", "Beta", "/Apps/Beta.app", 22, 3, gpu, "GPU"),
            (end / 3 + 15_000, alpha, "com.example.alpha", "Alpha", "/Apps/Alpha.app", 11, 13, gpu, "GPU"),
            (end - 120_000, beta, "com.example.beta", "Beta", "/Apps/Beta.app", 22, 17, cpu, "CPU"),
            (end - 30_000, alpha, "com.example.alpha", "Alpha", "/Apps/Alpha.app", 11, 19, cpu, "CPU")
        ].filter { $0.0 >= 0 && $0.0 < end }
        let rows = points.map { RawFixture(ts: $0.0, appId: $0.1, appKey: $0.2, name: $0.3, path: $0.4, pid: $0.5, version: version, energy: $0.6, bucketId: $0.7, bucketName: $0.8) }
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
                               path: values[0].path,
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

    func testTierSwitchBoundariesGapsIdentityAndMetricVersionsForEveryRange() async throws {
        for range in HistoryRange.allCases {
            let db = try HistoryDatabase.makeInMemory()
            let firstAppID = try await db.upsertApp(groupKey: "com.example.stable.first", bundleIdentifier: "com.example.stable",
                                                    displayName: "Stable App", path: "/Apps/Stable.app", ts: 0)
            let secondAppID = try await db.upsertApp(groupKey: "com.example.stable.second", bundleIdentifier: "com.example.stable",
                                                     displayName: "Stable App", path: "/Apps/Stable.app", ts: 0)
            let bucketID = try await db.upsertBucket(name: "CPU")
            let tierMS: Int64 = range == .d7 ? 3_600_000 : 60_000
            let start = 20 * 86_400_000 / tierMS * tierMS
            let widthMS = Int64(range.bucketSeconds) * 1000
            let switchAt = start + 2 * tierMS
            let end = start + Int64(range.minutes) * 60_000
            let lateTS = switchAt + 4 * widthMS
            let currentRows: [(Int64, Int64, Int64, Int64)] = [
                (start + 30_000, 3, 6, firstAppID),
                (start + tierMS - 30_000, 5, 10, secondAppID),
                (switchAt, 7, 14, firstAppID),
                (switchAt + min(30_000, widthMS / 2), 11, 22, secondAppID),
                (lateTS, 13, 26, firstAppID)
            ]
            let legacyRows: [(Int64, Int64, Int64, Int64)] = [
                (start + 45_000, 101, 1_010, firstAppID),
                (switchAt + 45_000, 103, 1_030, firstAppID)
            ]
            let currentFixtures = currentRows.map {
                RawFixture(ts: $0.0, appId: $0.3, appKey: "com.example.stable", name: "Stable App",
                           path: "/Apps/Stable.app", pid: 71, version: EnergyMetric.currentVersion,
                           energy: $0.1, bucketId: bucketID, bucketName: "CPU")
            }
            try await db.dbPool.write { conn in
                for (ts, energy, cpu, appID) in currentRows + legacyRows {
                    let version = currentRows.contains { $0.0 == ts } ? EnergyMetric.currentVersion : EnergyMetric.legacyVersion
                    try AppSampleRaw(ts: ts, appId: appID, pid: 71, parentPid: nil, metricVersion: version,
                                     energyNJ: energy, cpuNs: cpu, wakeups: 1,
                                     diskReadBytes: 0, diskWriteBytes: 0).insert(conn)
                    try BucketSampleRaw(ts: ts, bucketId: bucketID, metricVersion: version, energyNJ: energy).insert(conn)
                }

                if range != .live {
                    for version in [EnergyMetric.legacyVersion, EnergyMetric.currentVersion] {
                        let values = (version == EnergyMetric.legacyVersion ? legacyRows : currentRows)
                        let watermark = switchAt / tierMS - (version == EnergyMetric.legacyVersion ? 2 : 1)
                        let cutoff = (watermark + 1) * tierMS
                        let covered = values.filter { $0.0 < cutoff }
                        guard !values.isEmpty else { continue }
                        let appGroups = Dictionary(grouping: covered, by: {
                            AppRollupKey(time: $0.0 / tierMS, appId: $0.3, version: version)
                        })
                        for (key, samples) in appGroups {
                            let energy = samples.reduce(Int64(0)) { $0 + $1.1 }
                            let cpu = samples.reduce(Int64(0)) { $0 + $1.2 }
                            if range == .d7 {
                                try AppUsageHour(hour: key.time, appId: key.appId, metricVersion: version, energyNJ: energy,
                                                 cpuNs: cpu, wakeups: Int64(samples.count), diskReadBytes: 0,
                                                 diskWriteBytes: 0, samples: Int64(samples.count)).insert(conn)
                            } else {
                                try AppUsageMinute(minute: key.time, appId: key.appId, metricVersion: version, energyNJ: energy,
                                                   cpuNs: cpu, wakeups: Int64(samples.count), diskReadBytes: 0,
                                                   diskWriteBytes: 0, samples: Int64(samples.count)).insert(conn)
                            }
                        }
                        let bucketGroups = Dictionary(grouping: covered, by: { BucketRollupKey(time: $0.0 / tierMS, bucketId: bucketID, version: version) })
                        for (key, samples) in bucketGroups {
                            let energy = samples.reduce(Int64(0)) { $0 + $1.1 }
                            if range == .d7 {
                                try BucketHour(hour: key.time, bucketId: key.bucketId, metricVersion: version, energyNJ: energy).insert(conn)
                            } else {
                                try BucketMinute(minute: key.time, bucketId: key.bucketId, metricVersion: version, energyNJ: energy).insert(conn)
                            }
                        }
                        let watermarkKey = range == .d7 ? "rollup.hourWatermark" : "rollup.minuteWatermark"
                        let legacyWatermarkKey = range == .d7 ? "legacy.hourMark" : "legacy.minuteMark"
                        let key = version == EnergyMetric.legacyVersion ? legacyWatermarkKey : watermarkKey
                        try conn.execute(sql: "INSERT INTO Meta(key, value) VALUES (?, ?)", arguments: [key, String(watermark)])
                    }
                }
            }

            let interval = interval(start, end)
            let actual = try await db.historyEnergy(in: interval, range: range)
            XCTAssertEqual(actual, expectedEnergy(currentFixtures, range: range, version: EnergyMetric.currentVersion),
                           "current per-bucket energy and CPU, range \(range.rawValue)")
            XCTAssertEqual(Set(actual.map(\.appID)), ["com.example.stable"], "stable color identity, range \(range.rawValue)")
            let bucketEnergy = try await db.historyHardware(in: interval, range: range).reduce(Int64(0)) { $0 + $1.totalEnergyNJ }
            XCTAssertEqual(bucketEnergy, currentRows.reduce(Int64(0)) { $0 + $1.1 }, "hardware energy, range \(range.rawValue)")

            let exactBoundary = try await db.historyEnergy(in: self.interval(switchAt, end), range: range)
            let expectedAtBoundary = currentRows.filter { $0.0 >= switchAt }
            XCTAssertEqual(exactBoundary.reduce(Int64(0)) { $0 + $1.energyNJ },
                           expectedAtBoundary.reduce(Int64(0)) { $0 + $1.1 },
                           "range beginning at the tier switch, range \(range.rawValue)")

            let occupied = Set(actual.map { Int64($0.date.timeIntervalSince1970 * 1000) })
            let expectedOccupied = Set(currentRows.map { ($0.0 / widthMS) * widthMS })
            XCTAssertEqual(occupied, expectedOccupied, "occupied bucket starts must match current raw rows, range \(range.rawValue)")
            let switchBucket = (switchAt / widthMS) * widthMS
            let lateBucket = (lateTS / widthMS) * widthMS
            let sleepBuckets = lateBucket / widthMS - switchBucket / widthMS - 1
            XCTAssertGreaterThanOrEqual(sleepBuckets, 3, "fixture sleep gap spans at least three buckets, range \(range.rawValue)")
            let sleepGap = Set((1...Int(sleepBuckets)).map { switchBucket + Int64($0) * widthMS })
            XCTAssertTrue(occupied.isDisjoint(with: sleepGap), "sleep gap buckets remain absent, range \(range.rawValue)")

            let legacy = try await db.historyEnergy(in: interval, range: range, metricVersion: EnergyMetric.legacyVersion)
            XCTAssertEqual(legacy.reduce(Int64(0)) { $0 + $1.energyNJ }, legacyRows.reduce(Int64(0)) { $0 + $1.1 },
                           "legacy version remains isolated, range \(range.rawValue)")
            XCTAssertEqual(legacy.reduce(Int64(0)) { $0 + ($1.cpuNS ?? 0) }, legacyRows.reduce(Int64(0)) { $0 + $1.2 },
                           "legacy CPU remains isolated, range \(range.rawValue)")

            if range == .d7 {
                let nonAlignedStart = start + 30 * 60_000
                let partialWindow = try await db.historyEnergy(in: self.interval(nonAlignedStart, end), range: range)
                let leftEdgeHour = nonAlignedStart / 3_600_000
                let partialFixtures = currentFixtures.filter { $0.ts / 3_600_000 >= leftEdgeHour }
                XCTAssertEqual(partialWindow, expectedEnergy(partialFixtures, range: range, version: EnergyMetric.currentVersion),
                               "7D query beginning off the hour includes its whole left-edge hour")
            }
        }
    }

    func testLondonDSTDaysKeepUTCBucketTotalsAndElapsedDuration() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let cases: [(DateComponents, Double, [String])] = [
            (DateComponents(year: 2026, month: 3, day: 29), 23 * 3_600,
             ["2026-03-29T00:00:00Z", "2026-03-29T18:00:00Z"]),
            (DateComponents(year: 2026, month: 10, day: 25), 25 * 3_600,
             ["2026-10-24T18:00:00Z", "2026-10-25T18:00:00Z"])
        ]
        let utcFormatter = ISO8601DateFormatter()
        for (components, expectedDuration, expectedBucketStarts) in cases {
            let db = try HistoryDatabase.makeInMemory()
            let appID = try await db.upsertApp(groupKey: "com.example.dst", bundleIdentifier: "com.example.dst",
                                               displayName: "DST App", path: "/Apps/DST.app", ts: 0)
            let localMidnight = try XCTUnwrap(calendar.date(from: components))
            let nextMidnight = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: localMidnight))
            XCTAssertEqual(nextMidnight.timeIntervalSince(localMidnight), expectedDuration)
            let firstMS = Int64(localMidnight.timeIntervalSince1970 * 1000)
            let lastMS = Int64(nextMidnight.timeIntervalSince1970 * 1000) - 30_000
            try await db.dbPool.write { conn in
                try AppUsageHour(hour: firstMS / 3_600_000, appId: appID, metricVersion: EnergyMetric.currentVersion,
                                 energyNJ: 17, cpuNs: 170, wakeups: 1, diskReadBytes: 0,
                                 diskWriteBytes: 0, samples: 1).insert(conn)
                try AppSampleRaw(ts: lastMS, appId: appID, pid: 88, parentPid: nil, metricVersion: EnergyMetric.currentVersion,
                                 energyNJ: 34, cpuNs: 340, wakeups: 1, diskReadBytes: 0, diskWriteBytes: 0).insert(conn)
                try conn.execute(sql: "INSERT INTO Meta(key, value) VALUES ('rollup.hourWatermark', ?)",
                                 arguments: [String(firstMS / 3_600_000)])
            }
            let points = try await db.historyEnergy(in: DateInterval(start: localMidnight, end: nextMidnight), range: .d7)
            XCTAssertEqual(points.reduce(Int64(0)) { $0 + $1.energyNJ }, 51)
            XCTAssertEqual(points.reduce(Int64(0)) { $0 + ($1.cpuNS ?? 0) }, 510)
            XCTAssertEqual(points.map(\.date), points.map(\.date).sorted(), "UTC epoch buckets stay ordered through DST")
            XCTAssertEqual(points.count, 2, "empty UTC buckets remain absent on DST day")
            XCTAssertEqual(points.map { utcFormatter.string(from: $0.date) }, expectedBucketStarts,
                           "7D points start on the expected UTC 6-hour grid")
        }
    }

    func testMaintenancePruneCutoffsPreserveHourHistoryAndSevenDayQuery() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let nowMS: Int64 = 40 * 86_400_000 / 3_600_000 * 3_600_000
        let rawCutoff = nowMS - 7 * 86_400_000
        let minuteCutoff = nowMS / 60_000 - 2 * 24 * 60
        let appID = try await db.upsertApp(groupKey: "com.example.retained", bundleIdentifier: "com.example.retained",
                                           displayName: "Retained App", path: "/Apps/Retained.app", ts: 0)
        let samples: [(Int64, Int64, Int64)] = [
            (rawCutoff - 30_000, 2, 20),
            (rawCutoff, 3, 30),
            ((minuteCutoff - 1) * 60_000, 5, 50),
            (minuteCutoff * 60_000, 7, 70),
            (nowMS - 30_000, 11, 110)
        ]
        try await db.dbPool.write { conn in
            for (ts, energy, cpu) in samples {
                try AppSampleRaw(ts: ts, appId: appID, pid: 99, parentPid: nil, metricVersion: EnergyMetric.currentVersion,
                                 energyNJ: energy, cpuNs: cpu, wakeups: 1, diskReadBytes: 0, diskWriteBytes: 0).insert(conn)
            }
        }
        let now = Date(timeIntervalSince1970: Double(nowMS) / 1000)
        try await db.rollupMinutes(now: now)
        try await db.rollupHours(now: now)
        try await db.pruneHistory(now: now)

        let retainedRaw = try await db.dbPool.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT COALESCE(SUM(energyNJ), 0) FROM AppSampleRaw") ?? 0
        }
        XCTAssertEqual(retainedRaw, 26, "raw cutoff is inclusive and expired raw rows are removed")
        let retainedMinutes = try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM AppUsageMinute WHERE minute < ?", arguments: [minuteCutoff]) ?? 0
        }
        XCTAssertEqual(retainedMinutes, 0, "minute cutoff removes only rows strictly before the 2-day boundary")
        let minuteBoundaryEnergy = try await db.dbPool.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT COALESCE(SUM(energyNJ), 0) FROM AppUsageMinute WHERE minute = ?", arguments: [minuteCutoff]) ?? 0
        }
        XCTAssertEqual(minuteBoundaryEnergy, 7, "the minute at the inclusive retention cutoff remains")

        let interval = self.interval(rawCutoff, nowMS)
        let sevenDay = try await db.historyEnergy(in: interval, range: .d7)
        XCTAssertEqual(sevenDay.reduce(Int64(0)) { $0 + $1.energyNJ }, 26)
        XCTAssertEqual(sevenDay.reduce(Int64(0)) { $0 + ($1.cpuNS ?? 0) }, 260)
        let nonAlignedSevenDay = try await db.historyEnergy(in: self.interval(rawCutoff + 30 * 60_000, nowMS), range: .d7)
        XCTAssertEqual(nonAlignedSevenDay.reduce(Int64(0)) { $0 + $1.energyNJ }, 26,
                       "a 7D query starting off the hour includes its summarized left-edge hour")

        let oldHours = try await db.dbPool.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT COALESCE(SUM(energyNJ), 0) FROM AppUsageHour WHERE hour < ?", arguments: [nowMS / 3_600_000 - 48]) ?? 0
        }
        XCTAssertEqual(oldHours, 10, "old hour energy survives both raw and minute pruning")
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

    func testVersionedCLIProcessesSumOnceWithinOneWindow() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let start = Int64(Date().timeIntervalSince1970 * 1000) / 30_000 * 30_000
        let versions = [
            ("2.1.286", "/Users/example/.local/share/claude/versions/2.1.286", Int32(286)),
            ("2.1.287", "/Users/example/.local/share/claude/versions/2.1.287", Int32(287))
        ]
        for tick in 0..<3 {
            let apps = versions.map { version, path, pid in
                let identity = AppIdentity.resolve(bundleIdentifier: nil, processName: version, path: path)
                return SampledApp(groupKey: identity.groupKey, displayName: identity.displayName, path: path,
                                  pid: pid, energyNJ: Int64((tick + 1) * (pid == 286 ? 100 : 200)), cpuNs: 10)
            }
            try await db.writeTick(timestamp: start + Int64(tick * 5_000), apps: apps, buckets: [],
                                   coverage: SampleCoverage(visible: 2, unreadable: 0))
        }
        try await db.flushPendingWindow()

        let rows = try await db.historyEnergy(in: interval(start, start + 30_000), range: .live)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].appID, "cli:claude")
        XCTAssertEqual(rows[0].name, "Claude Code")
        XCTAssertEqual(rows[0].energyNJ, 1_800)
        let storage = try await db.dbPool.read { conn in
            (try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM App")) ?? 0
        }
        XCTAssertEqual(storage, 1)
    }

    func testLegacyVersionedAppRowsMergeAtQueryTime() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let first = try await db.upsertApp(groupKey: "2.1.286", bundleIdentifier: nil, displayName: "2.1.286",
                                           path: "/Users/example/.local/share/claude/versions/2.1.286", ts: 0)
        let second = try await db.upsertApp(groupKey: "2.1.287", bundleIdentifier: nil, displayName: "2.1.287",
                                            path: "/Users/example/.local/share/claude/versions/2.1.287", ts: 0)
        try await db.dbPool.write { conn in
            for (appID, pid, energy) in [(first, Int32(286), Int64(125)), (second, Int32(287), Int64(275))] {
                try AppSampleRaw(ts: 1_000, appId: appID, pid: pid, parentPid: nil,
                                 metricVersion: EnergyMetric.currentVersion, energyNJ: energy, cpuNs: energy * 2,
                                 wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0).insert(conn)
            }
        }

        let rows = try await db.historyEnergy(in: interval(0, 30_000), range: .live)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].appID, "cli:claude")
        XCTAssertEqual(rows[0].energyNJ, 400)
        XCTAssertEqual(rows[0].cpuNS, 800)
        let apps = try await db.historyAppBreakdown(in: interval(0, 30_000), range: .live)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].processName, "Claude Code")
        XCTAssertEqual(apps[0].totalEnergyNJ, 400)
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

    func testCSVDefaultEnergyTotalUsesOnlyTheChartMetricVersion() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let appID = try await db.upsertApp(groupKey: "com.example.versioned", bundleIdentifier: "com.example.versioned",
                                           displayName: "Versioned", path: "/Apps/Versioned.app", ts: 0)
        try await db.dbPool.write { conn in
            try AppSampleRaw(ts: 0, appId: appID, pid: 42, parentPid: nil,
                             metricVersion: EnergyMetric.legacyVersion, energyNJ: 100, cpuNs: 0,
                             wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0).insert(conn)
            try AppSampleRaw(ts: 30_000, appId: appID, pid: 42, parentPid: nil,
                             metricVersion: EnergyMetric.currentVersion, energyNJ: 20, cpuNs: 0,
                             wakeups: 0, diskReadBytes: 0, diskWriteBytes: 0).insert(conn)
        }

        let interval = interval(0, 60_000)
        let chart = try await db.historyEnergy(in: interval, range: .live)
        let csv = try await db.historySamplesForCSV(in: interval)
        XCTAssertEqual(chart.reduce(Int64(0)) { $0 + $1.energyNJ }, 20)
        XCTAssertEqual(csv.reduce(Int64(0)) { $0 + $1.energyNJ }, 20,
                       "default CSV energy sums must use the same metric version as the chart")
        XCTAssertTrue(csv.allSatisfy { $0.metricVersion == EnergyMetric.currentVersion })
    }

    func testCSVBatchOutputMatchesLegacyArrayOutputByteForByte() async throws {
        let (db, _, end) = try await fixture(.live)
        let window = interval(0, end)
        let header = HistoryDatabase.CSVSample.columnNames.joined(separator: ",") + "\n"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestampDate: (Int64) -> Date = { Date(timeIntervalSince1970: Double($0) / 1000) }

        let legacyRows = try db.dbPool.read { conn -> [Row] in
            try Row.fetchAll(conn, sql: """
                SELECT r.ts, r.pid, r.parentPid, a.bundleIdentifier, a.displayName AS processName, a.path,
                       r.cpuNs, r.energyNJ, r.wakeups, r.diskReadBytes, r.diskWriteBytes, r.metricVersion
                FROM AppSampleRaw r JOIN App a ON a.id = r.appId
                WHERE r.ts >= ? AND r.ts < ? ORDER BY r.ts, r.appId, r.pid
                """, arguments: [Int64(window.start.timeIntervalSince1970 * 1000),
                                 Int64(window.end.timeIntervalSince1970 * 1000)])
        }
        var legacyOutput = header
        for row in legacyRows {
            guard let timestamp: Int64 = row["ts"], let pid: Int32 = row["pid"],
                  let processName: String = row["processName"], let cpuNS: Int64 = row["cpuNs"],
                  let energyNJ: Int64 = row["energyNJ"], let wakeups: Int64 = row["wakeups"],
                  let read: Int64 = row["diskReadBytes"], let write: Int64 = row["diskWriteBytes"],
                  let version: Int = row["metricVersion"] else { continue }
            let sample = HistoryDatabase.CSVSample(
                timestampMS: timestamp, iso8601: "", pid: pid, parentPid: row["parentPid"],
                bundleID: row["bundleIdentifier"], processName: processName, path: row["path"],
                cpuNS: cpuNS, energyNJ: energyNJ, wakeups: wakeups, diskReadBytes: read,
                diskWriteBytes: write, metricVersion: version)
            legacyOutput += sample.csvLine(iso8601: formatter.string(from: timestampDate(timestamp)))
        }
        var streamedOutput = header
        var batchSizes: [Int] = []
        try await db.forEachHistorySamplesForCSV(in: window, batchSize: 2) { batch in
            batchSizes.append(batch.count)
            streamedOutput += batch.map { sample in
                sample.csvLine(iso8601: formatter.string(from: timestampDate(sample.timestampMS)))
            }.joined()
        }

        XCTAssertEqual(Array(streamedOutput.utf8), Array(legacyOutput.utf8))
        let expectedBatchSizes = Array(repeating: 2, count: legacyRows.count / 2)
            + (legacyRows.count.isMultiple(of: 2) ? [] : [1])
        XCTAssertEqual(batchSizes, expectedBatchSizes)
    }

    func testCSVCursorKeepsLargeResultSetWithinConfiguredBatchBound() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let appId = try await db.upsertApp(groupKey: "large-export", bundleIdentifier: nil,
                                           displayName: "Large Export", path: "/Apps/Large.app", ts: 0)
        let rowCount = 10_003
        try await db.dbPool.write { conn in
            for index in 0..<rowCount {
                try AppSampleRaw(ts: Int64(index) * 30_000, appId: appId, pid: Int32(index % 32),
                                 parentPid: nil, metricVersion: EnergyMetric.currentVersion,
                                 energyNJ: 1, cpuNs: 2, wakeups: 1, diskReadBytes: 3,
                                 diskWriteBytes: 4).insert(conn)
            }
        }

        let batchLimit = 257
        var batchCount = 0
        var maximumBatchSize = 0
        var exportedCount = 0
        try await db.forEachHistorySamplesForCSV(in: interval(0, Int64(rowCount) * 30_000), batchSize: batchLimit) { batch in
            batchCount += 1
            maximumBatchSize = max(maximumBatchSize, batch.count)
            exportedCount += batch.count
        }

        XCTAssertEqual(exportedCount, rowCount)
        XCTAssertEqual(batchCount, (rowCount + batchLimit - 1) / batchLimit)
        XCTAssertLessThanOrEqual(maximumBatchSize, batchLimit)
        XCTAssertEqual(maximumBatchSize, batchLimit)
    }

    func testCSVBatchCallbackCancellationStopsCursor() async throws {
        let (db, _, end) = try await fixture(.live)
        let exportWindow = interval(0, end)
        let taskBox = CSVExportTaskBox()
        let task = Task {
            try await db.forEachHistorySamplesForCSV(in: exportWindow, batchSize: 2) { _ in
                taskBox.recordCallback()
                taskBox.cancel()
            }
        }
        taskBox.set(task)
        do {
            try await task.value
            XCTFail("Expected task cancellation to stop the cursor")
        } catch is CancellationError {
            XCTAssertEqual(taskBox.recordedCallbacks, 1)
        }
    }
}
