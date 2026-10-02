import Foundation
import GRDB

/// Queries over the tiered history store. All output dates use UTC epoch-aligned buckets.
extension HistoryDatabase {
    public struct BucketSummary: Sendable, Equatable, Identifiable {
        public let bucketName: String
        public let totalEnergyNJ: Int64
        public let sparkline: [SparkPoint]
        public var id: String { bucketName }

        public struct SparkPoint: Sendable, Equatable {
            public let bucketStart: Date
            public let energyNJ: Int64
        }
    }

    public struct MetricVersionCoverage: Sendable, Equatable {
        public let hasOlderData: Bool
        public let bucketStarts: [Date]
    }

    /// One raw row with the public CSV column set.
    public struct CSVSample: Sendable, Equatable {
        public let timestampMS: Int64
        public let iso8601: String
        public let pid: Int32
        public let parentPid: Int32?
        public let bundleID: String?
        public let processName: String
        public let path: String?
        public let cpuNS: Int64
        public let energyNJ: Int64
        public let wakeups: Int64
        public let diskReadBytes: Int64
        public let diskWriteBytes: Int64
        public let metricVersion: Int
    }

    /// Returns per-app energy points with the same shape as the existing History chart query.
    public func historyEnergy(
        in interval: DateInterval,
        range: HistoryRange,
        metricVersion: Int = EnergyMetric.currentVersion
    ) async throws -> [HistoryEnergyPoint] {
        let source = try await energyRows(in: interval, range: range, metricVersion: metricVersion)
        return source.map { row in
            let date = Date(timeIntervalSince1970: Double(row.bucketMS) / 1000)
            return HistoryEnergyPoint(
                appID: row.groupKey,
                name: row.displayName,
                bundleIdentifier: row.bundleIdentifier,
                path: row.path,
                isSystem: AppClassification.isSystem(bundleIdentifier: row.bundleIdentifier, processName: row.displayName, path: row.path),
                date: date,
                energyNJ: row.energyNJ
            )
        }
    }

    /// Returns per-bucket totals and sparklines with the existing History breakdown shape.
    public func historyHardware(
        in interval: DateInterval,
        range: HistoryRange,
        metricVersion: Int = EnergyMetric.currentVersion
    ) async throws -> [BucketSummary] {
        let start = Self.epochMilliseconds(interval.start)
        let end = Self.epochMilliseconds(interval.end)
        let width = Int64(range.bucketSeconds) * 1000
        guard end > start, width > 0 else { return [] }
        return try await dbPool.read { db in
            let watermark = try Self.watermark(db, for: range)
            let arguments: StatementArguments = range == .live
                ? StatementArguments([width, width, start, end, Int64(metricVersion)])
                : Self.queryArguments(start: start, end: end, width: width, metricVersion: metricVersion, watermark: watermark, range: range)
            let rows = try Row.fetchAll(db, sql: Self.hardwareSQL(range: range), arguments: arguments)
            let grouped = Dictionary(grouping: rows, by: { $0["bucketName"] as String })
            return grouped.map { name, points in
                let sparkline = points.compactMap { row -> BucketSummary.SparkPoint? in
                    guard let bucketMS: Int64 = row["bucketMS"], let energy: Int64 = row["energyNJ"] else { return nil }
                    return BucketSummary.SparkPoint(bucketStart: Date(timeIntervalSince1970: Double(bucketMS) / 1000), energyNJ: energy)
                }.sorted { $0.bucketStart < $1.bucketStart }
                return BucketSummary(bucketName: name, totalEnergyNJ: sparkline.reduce(0) { $0 + $1.energyNJ }, sparkline: sparkline)
            }.sorted { $0.totalEnergyNJ == $1.totalEnergyNJ ? $0.bucketName < $1.bucketName : $0.totalEnergyNJ > $1.totalEnergyNJ }
        }
    }

    /// Marks requested display buckets containing any non-current metric version.
    public func metricVersionCoverage(
        in interval: DateInterval,
        range: HistoryRange,
        currentVersion: Int = EnergyMetric.currentVersion
    ) async throws -> MetricVersionCoverage {
        let start = Self.epochMilliseconds(interval.start)
        let end = Self.epochMilliseconds(interval.end)
        let width = Int64(range.bucketSeconds) * 1000
        guard end > start, width > 0 else { return MetricVersionCoverage(hasOlderData: false, bucketStarts: []) }
        let buckets = try await dbPool.read { db -> [Int64] in
            let watermark = try Self.watermark(db, for: range)
            let arguments: StatementArguments = range == .live
                ? StatementArguments([width, width, start, end, Int64(currentVersion)])
                : Self.coverageArguments(start: start, end: end, width: width, version: currentVersion, watermark: watermark, range: range)
            let rows = try Row.fetchAll(db, sql: Self.versionCoverageSQL(range: range), arguments: arguments)
            return rows.compactMap { $0["bucketMS"] }
        }
        return MetricVersionCoverage(
            hasOlderData: !buckets.isEmpty,
            bucketStarts: buckets.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        )
    }

    /// Battery trace query matching the legacy query's predecessor-sample semantics.
    public func batteryHistory(in interval: DateInterval) async throws -> [BatterySnapshot] {
        let start = Self.epochMilliseconds(interval.start)
        let end = Self.epochMilliseconds(interval.end)
        return try await dbPool.read { db in
            try BatterySnapshot.fetchAll(db, sql: """
                SELECT * FROM BatteryStatus WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp
                """, arguments: [start - 90_000, end])
        }
    }

    /// Power events in the interval plus the most recent preceding sleep/wake transition.
    public func historyEvents(in interval: DateInterval) async throws -> [PowerEvent] {
        let start = Self.epochMilliseconds(interval.start)
        let end = Self.epochMilliseconds(interval.end)
        return try await dbPool.read { db in
            try PowerEvent.fetchAll(db, sql: """
                SELECT * FROM PowerEvents WHERE timestamp >= ? AND timestamp < ?
                OR timestamp = (SELECT MAX(timestamp) FROM PowerEvents WHERE timestamp < ? AND eventType IN ('sleep', 'wake'))
                ORDER BY timestamp
                """, arguments: [start, end, start])
        }
    }

    /// Raw process samples for CSV export. The caller supplies the desired raw-retention interval.
    public func historySamplesForCSV(in interval: DateInterval) async throws -> [CSVSample] {
        let start = Self.epochMilliseconds(interval.start)
        let end = Self.epochMilliseconds(interval.end)
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.ts, r.pid, r.parentPid, a.bundleIdentifier, a.displayName AS processName, a.path,
                       r.cpuNs, r.energyNJ, r.wakeups, r.diskReadBytes, r.diskWriteBytes, r.metricVersion
                FROM AppSampleRaw r JOIN App a ON a.id = r.appId
                WHERE r.ts >= ? AND r.ts < ? ORDER BY r.ts, r.appId, r.pid
                """, arguments: [start, end])
            return rows.compactMap { row in
                guard let timestamp: Int64 = row["ts"], let pid: Int32 = row["pid"],
                      let processName: String = row["processName"], let cpuNS: Int64 = row["cpuNs"],
                      let energyNJ: Int64 = row["energyNJ"], let wakeups: Int64 = row["wakeups"],
                      let read: Int64 = row["diskReadBytes"], let write: Int64 = row["diskWriteBytes"],
                      let version: Int = row["metricVersion"] else { return nil }
                return CSVSample(timestampMS: timestamp, iso8601: Self.iso8601(timestamp),
                                 pid: pid, parentPid: row["parentPid"], bundleID: row["bundleIdentifier"], processName: processName,
                                 path: row["path"], cpuNS: cpuNS, energyNJ: energyNJ, wakeups: wakeups,
                                 diskReadBytes: read, diskWriteBytes: write, metricVersion: version)
            }
        }
    }
}

private extension HistoryDatabase {
    struct EnergyQueryRow {
        let bucketMS: Int64
        let groupKey: String
        let bundleIdentifier: String?
        let displayName: String
        let path: String?
        let energyNJ: Int64
    }

    static func epochMilliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    static func iso8601(_ timestamp: Int64) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(timestamp) / 1000))
    }

    static func watermark(_ db: Database, for range: HistoryRange) throws -> Int64? {
        let key = range == .d7 ? "rollup.hourWatermark" : "rollup.minuteWatermark"
        guard let raw = try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key = ?", arguments: [key]) else { return nil }
        return Int64(raw)
    }

    func energyRows(in interval: DateInterval, range: HistoryRange, metricVersion: Int) async throws -> [EnergyQueryRow] {
        let start = Self.epochMilliseconds(interval.start)
        let end = Self.epochMilliseconds(interval.end)
        let width = Int64(range.bucketSeconds) * 1000
        guard end > start, width > 0 else { return [] }
        return try await dbPool.read { db in
            let arguments: StatementArguments = range == .live
                ? StatementArguments([width, width, start, end, Int64(metricVersion)])
                : Self.queryArguments(start: start, end: end, width: width, metricVersion: metricVersion,
                                      watermark: try Self.watermark(db, for: range), range: range)
            let rows = try Row.fetchAll(db, sql: Self.energySQL(range: range), arguments: arguments)
            return rows.compactMap { row in
                guard let bucket: Int64 = row["bucketMS"], let key: String = row["groupKey"],
                      let name: String = row["displayName"], let energy: Int64 = row["energyNJ"] else { return nil }
                return EnergyQueryRow(bucketMS: bucket, groupKey: key, bundleIdentifier: row["bundleIdentifier"],
                                      displayName: name, path: row["path"], energyNJ: energy)
            }
        }
    }

    static func queryArguments(start: Int64, end: Int64, width: Int64, metricVersion: Int, watermark: Int64?, range: HistoryRange) -> StatementArguments {
        let unitMS: Int64 = range == .d7 ? 3_600_000 : 60_000
        let cutoff = watermark.map { ($0 + 1) * unitMS } ?? start
        let tierStart = ((start + unitMS - 1) / unitMS) * unitMS
        let tierEnd = (end / unitMS) * unitMS
        return [width, width, tierStart, tierEnd, Int64(metricVersion),
                width, width, start, end, Int64(metricVersion), cutoff, tierStart, tierEnd]
    }

    static func coverageArguments(start: Int64, end: Int64, width: Int64, version: Int, watermark: Int64?, range: HistoryRange) -> StatementArguments {
        let unitMS: Int64 = range == .d7 ? 3_600_000 : 60_000
        let cutoff = watermark.map { ($0 + 1) * unitMS } ?? start
        let tierStart = ((start + unitMS - 1) / unitMS) * unitMS
        let tierEnd = (end / unitMS) * unitMS
        return [width, width, tierStart, tierEnd, Int64(version),
                width, width, start, end, Int64(version), cutoff, tierStart, tierEnd]
    }

    static func energySQL(range: HistoryRange) -> String {
        if range == .live {
            return """
                SELECT (r.ts / ?) * ? AS bucketMS, a.groupKey, a.bundleIdentifier, a.displayName, a.path, SUM(r.energyNJ) AS energyNJ
                FROM AppSampleRaw r JOIN App a ON a.id = r.appId
                WHERE r.ts >= ? AND r.ts < ? AND r.metricVersion = ?
                GROUP BY bucketMS, r.appId HAVING energyNJ > 0 ORDER BY bucketMS, a.groupKey
                """
        }
        let isHour = range == .d7
        let table = isHour ? "AppUsageHour" : "AppUsageMinute"
        let timeCol = isHour ? "hour" : "minute"
        let unitMS: Int64 = isHour ? 3_600_000 : 60_000
        return """
            WITH tier AS (
                SELECT ((u.\(timeCol) * \(unitMS)) / ?) * ? AS bucketMS, u.appId, u.energyNJ
                FROM \(table) u WHERE u.\(timeCol) * \(unitMS) >= ? AND u.\(timeCol) * \(unitMS) < ? AND u.metricVersion = ?
                UNION ALL
                SELECT (r.ts / ?) * ? AS bucketMS, r.appId, r.energyNJ
                FROM AppSampleRaw r WHERE r.ts >= ? AND r.ts < ? AND r.metricVersion = ?
                    AND (r.ts >= ? OR r.ts < ? OR r.ts >= ?)
            )
            SELECT t.bucketMS, a.groupKey, a.bundleIdentifier, a.displayName, a.path, SUM(t.energyNJ) AS energyNJ
            FROM tier t JOIN App a ON a.id = t.appId GROUP BY t.bucketMS, t.appId HAVING energyNJ > 0 ORDER BY t.bucketMS, a.groupKey
            """
    }

    static func hardwareSQL(range: HistoryRange) -> String {
        if range == .live {
            return """
                SELECT b.name AS bucketName, (r.ts / ?) * ? AS bucketMS, SUM(r.energyNJ) AS energyNJ
                FROM BucketSampleRaw r JOIN Bucket b ON b.id = r.bucketId
                WHERE r.ts >= ? AND r.ts < ? AND r.metricVersion = ?
                GROUP BY r.bucketId, bucketMS ORDER BY bucketMS
                """
        }
        let isHour = range == .d7
        let table = isHour ? "BucketHour" : "BucketMinute"
        let timeCol = isHour ? "hour" : "minute"
        let unitMS: Int64 = isHour ? 3_600_000 : 60_000
        return """
            WITH tier AS (
                SELECT ((u.\(timeCol) * \(unitMS)) / ?) * ? AS bucketMS, u.bucketId, u.energyNJ
                FROM \(table) u WHERE u.\(timeCol) * \(unitMS) >= ? AND u.\(timeCol) * \(unitMS) < ? AND u.metricVersion = ?
                UNION ALL
                SELECT (r.ts / ?) * ? AS bucketMS, r.bucketId, r.energyNJ
                FROM BucketSampleRaw r WHERE r.ts >= ? AND r.ts < ? AND r.metricVersion = ?
                    AND (r.ts >= ? OR r.ts < ? OR r.ts >= ?)
            )
            SELECT b.name AS bucketName, t.bucketMS, SUM(t.energyNJ) AS energyNJ
            FROM tier t JOIN Bucket b ON b.id = t.bucketId GROUP BY b.id, t.bucketMS ORDER BY t.bucketMS
            """
    }

    static func versionCoverageSQL(range: HistoryRange) -> String {
        if range == .live {
            return "SELECT DISTINCT (ts / ?) * ? AS bucketMS FROM AppSampleRaw WHERE ts >= ? AND ts < ? AND metricVersion < ? ORDER BY bucketMS"
        }
        let isHour = range == .d7
        let table = isHour ? "AppUsageHour" : "AppUsageMinute"
        let timeCol = isHour ? "hour" : "minute"
        let unitMS: Int64 = isHour ? 3_600_000 : 60_000
        return """
            SELECT DISTINCT bucketMS FROM (
                SELECT ((\(timeCol) * \(unitMS)) / ?) * ? AS bucketMS FROM \(table)
                WHERE \(timeCol) * \(unitMS) >= ? AND \(timeCol) * \(unitMS) < ? AND metricVersion < ?
                UNION
                SELECT (ts / ?) * ? AS bucketMS FROM AppSampleRaw
                WHERE ts >= ? AND ts < ? AND metricVersion < ?
                    AND (ts >= ? OR ts < ? OR ts >= ?)
            ) ORDER BY bucketMS
            """
    }
}
