import Foundation
import GRDB

/// Queries over the tiered history store. All output dates use UTC epoch-aligned buckets.
extension HistoryDatabase {
    public struct TopAppEnergy: Sendable, Equatable, Identifiable {
        public let bundleIdentifier: String?
        public let processName: String
        public let path: String?
        public let totalEnergyNJ: Int64
        public let totalCPUNS: Int64
        public var id: String { AppIdentity.resolve(bundleIdentifier: bundleIdentifier, processName: processName, path: path).groupKey }
        public init(bundleIdentifier: String?, processName: String, path: String?, totalEnergyNJ: Int64, totalCPUNS: Int64 = 0) {
            self.bundleIdentifier = bundleIdentifier; self.processName = processName; self.path = path
            self.totalEnergyNJ = totalEnergyNJ; self.totalCPUNS = totalCPUNS
        }
    }

    public struct AppBreakdownEntry: Sendable, Equatable, Identifiable {
        public let bundleIdentifier: String?
        public let processName: String
        public let path: String?
        public let totalEnergyNJ: Int64
        public let totalCPUNS: Int64
        public let isSystem: Bool
        public var id: String { AppIdentity.resolve(bundleIdentifier: bundleIdentifier, processName: processName, path: path).groupKey }
        public init(bundleIdentifier: String?, processName: String, path: String?, totalEnergyNJ: Int64,
                    totalCPUNS: Int64, isSystem: Bool) {
            self.bundleIdentifier = bundleIdentifier; self.processName = processName; self.path = path
            self.totalEnergyNJ = totalEnergyNJ; self.totalCPUNS = totalCPUNS; self.isSystem = isSystem
        }
    }

    public struct ImportStatus: Sendable, Equatable {
        public let state: LegacyImportState
        public let importedHours: Int64
        public let totalHours: Int64
        public let error: String?
        public let deleteAfter: Date?
    }

    public func latestBatterySnapshot() async throws -> BatterySnapshot? {
        try await dbPool.read { db in try BatterySnapshot.order(Column("timestamp").desc).limit(1).fetchOne(db) }
    }

    public func latestCoverage() async throws -> Coverage? {
        try await dbPool.read { db in try Coverage.order(Column("ts").desc).limit(1).fetchOne(db) }
    }

    public func earliestSampleTimestamp() async throws -> Date? {
        try await dbPool.read { db in
            guard let ts = try Int64.fetchOne(db, sql: "SELECT MIN(ts) FROM AppSampleRaw") else { return nil }
            return Date(timeIntervalSince1970: Double(ts) / 1000)
        }
    }

    public func bucketSamplerActive(withinMinutes minutes: Int = 5) async throws -> Bool {
        let since = Int64(Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in try Int.fetchOne(db, sql: "SELECT 1 FROM BucketSampleRaw WHERE ts >= ? LIMIT 1", arguments: [since]) != nil }
    }

    public func appBreakdown(sinceMinutes minutes: Int, energyAvailable: Bool = true) async throws -> [AppBreakdownEntry] {
        let start = Int64(Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.bundleIdentifier, a.displayName AS processName, a.path,
                       SUM(r.energyNJ) AS energy, SUM(r.cpuNs) AS cpu
                FROM AppSampleRaw r JOIN App a ON a.id = r.appId
                WHERE r.ts >= ? AND r.metricVersion = ?
                GROUP BY r.appId ORDER BY \(energyAvailable ? "energy" : "cpu") DESC
                """, arguments: [start, EnergyMetric.currentVersion])
            let entries = rows.compactMap { row -> AppBreakdownEntry? in
                guard let name: String = row["processName"], let energy: Int64 = row["energy"], let cpu: Int64 = row["cpu"] else { return nil }
                let bundle: String? = row["bundleIdentifier"]
                let path: String? = row["path"]
                let identity = AppIdentity.resolve(bundleIdentifier: bundle, processName: name, path: path)
                return AppBreakdownEntry(bundleIdentifier: bundle, processName: identity.displayName, path: path,
                    totalEnergyNJ: energy, totalCPUNS: cpu,
                    isSystem: AppClassification.isSystem(bundleIdentifier: bundle, processName: identity.displayName, path: path))
            }
            return Self.mergeBreakdownEntries(entries).sorted {
                let lhs = energyAvailable ? $0.totalEnergyNJ : $0.totalCPUNS
                let rhs = energyAvailable ? $1.totalEnergyNJ : $1.totalCPUNS
                return lhs == rhs ? $0.id < $1.id : lhs > rhs
            }
        }
    }

    /// Returns app totals from the same routed tier query used by History charts.
    public func historyAppBreakdown(in interval: DateInterval, range: HistoryRange,
                                    energyAvailable: Bool = true) async throws -> [AppBreakdownEntry] {
        let rows = try await energyRows(in: interval, range: range, metricVersion: EnergyMetric.currentVersion,
                                        includeZeroEnergy: true)
        let points = rows.map { row in
            HistoryEnergyPoint(appID: row.groupKey, name: row.displayName, bundleIdentifier: row.bundleIdentifier,
                               path: row.path,
                               isSystem: AppClassification.isSystem(bundleIdentifier: row.bundleIdentifier,
                                                                    processName: row.displayName, path: row.path),
                               date: Date(timeIntervalSince1970: Double(row.bucketMS) / 1000),
                               energyNJ: row.energyNJ, cpuNS: row.cpuNS)
        }
        return HistoryMath.apps(points).map {
            AppBreakdownEntry(bundleIdentifier: $0.bundleIdentifier, processName: $0.name, path: $0.path,
                              totalEnergyNJ: $0.energyNJ, totalCPUNS: $0.cpuNS, isSystem: $0.isSystem)
        }.sorted { lhs, rhs in
            let left = energyAvailable ? lhs.totalEnergyNJ : lhs.totalCPUNS
            let right = energyAvailable ? rhs.totalEnergyNJ : rhs.totalCPUNS
            return left == right ? lhs.id < rhs.id : left > right
        }
    }

    public func topApps(sinceMinutes minutes: Int, limit: Int = 5, energyAvailable: Bool = true) async throws -> [TopAppEnergy] {
        let entries = try await appBreakdown(sinceMinutes: minutes, energyAvailable: energyAvailable)
        return entries.prefix(limit).map {
            TopAppEnergy(bundleIdentifier: $0.bundleIdentifier, processName: $0.processName, path: $0.path,
                         totalEnergyNJ: $0.totalEnergyNJ, totalCPUNS: $0.totalCPUNS)
        }
    }

    public func importStatus() async throws -> ImportStatus {
        try await dbPool.read { db in
            let values = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT key, value FROM Meta WHERE key LIKE 'legacy.%'").compactMap { row -> (String, String)? in
                guard let key: String = row["key"], let value: String = row["value"] else { return nil }; return (key, value)
            })
            let state = LegacyImportState(rawValue: values["legacy.state"] ?? "none") ?? .none
            let doneAfter = values["legacy.deleteAfter"].flatMap(Int64.init).map { Date(timeIntervalSince1970: Double($0) / 1000) }
            let imported = Int64(values["legacy.cursorHour"] ?? "0") ?? 0
            let total = Int64(values["legacy.totalHours"] ?? "0") ?? 0
            return ImportStatus(state: state, importedHours: imported, totalHours: total,
                                error: values["legacy.error"], deleteAfter: doneAfter)
        }
    }

    public func rawRetentionDays() async throws -> Int {
        try await dbPool.read { db in try Int.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM Meta WHERE key='settings.rawRetentionDays'") ?? 7 }
    }

    public func setRawRetentionDays(_ days: Int) async throws {
        guard [2, 7, 14, 30].contains(days) else { return }
        try await dbPool.write { db in try db.execute(sql: "INSERT INTO Meta(key,value) VALUES('settings.rawRetentionDays',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [String(days)]) }
    }

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
        public static let columnNames = ["timestamp_ms", "iso8601", "pid", "parent_pid", "bundle_id", "process_name", "path", "cpu_ns", "energy_nj", "wakeups", "disk_read_bytes", "disk_write_bytes", "metric_version"]
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

        /// Serializes one row using the timestamp representation selected by the exporter.
        public func csvLine(iso8601: String) -> String {
            [
                String(timestampMS), iso8601, String(pid), parentPid.map(String.init) ?? "",
                Self.csvEscape(bundleID ?? ""), Self.csvEscape(processName), Self.csvEscape(path ?? ""),
                String(cpuNS), String(energyNJ), String(wakeups), String(diskReadBytes),
                String(diskWriteBytes), String(metricVersion)
            ].joined(separator: ",") + "\n"
        }

        private static func csvEscape(_ field: String) -> String {
            if field.contains(",") || field.contains("\"") || field.contains("\n") {
                let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            return field
        }
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
                energyNJ: row.energyNJ,
                cpuNS: row.cpuNS
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
            let watermark = try Self.watermark(db, for: range, metricVersion: metricVersion)
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
            let watermark = try Self.watermark(db, for: range, metricVersion: EnergyMetric.legacyVersion)
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
            let isoFormatter = ISO8601DateFormatter()
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
                return CSVSample(timestampMS: timestamp, iso8601: isoFormatter.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1000)),
                                 pid: pid, parentPid: row["parentPid"], bundleID: row["bundleIdentifier"], processName: processName,
                                 path: row["path"], cpuNS: cpuNS, energyNJ: energyNJ, wakeups: wakeups,
                                 diskReadBytes: read, diskWriteBytes: write, metricVersion: version)
            }
        }
    }

    /// Clips a requested export to the raw retention window, the source tier for CSV.
    public func rawCSVInterval(in interval: DateInterval, now: Date = Date()) async throws -> DateInterval {
        let days = try await rawRetentionDays()
        let earliest = now.addingTimeInterval(-Double(days) * 86_400)
        return DateInterval(start: max(interval.start, earliest), end: interval.end)
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
        let cpuNS: Int64
    }

    static func epochMilliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    /// The tail cutoff for the finest tier in use. Legacy rows are sealed by
    /// the importer's own marks, while the current version follows the rollup
    /// schedule so a bucket the sampler is still filling stays on the raw tail.
    static func watermark(_ db: Database, for range: HistoryRange, metricVersion: Int) throws -> Int64? {
        let key: String
        if metricVersion == EnergyMetric.legacyVersion {
            key = range == .d7 ? "legacy.hourMark" : "legacy.minuteMark"
        } else {
            key = range == .d7 ? "rollup.hourWatermark" : "rollup.minuteWatermark"
        }
        guard let raw = try String.fetchOne(db, sql: "SELECT value FROM Meta WHERE key = ?", arguments: [key]) else { return nil }
        return Int64(raw)
    }

    func energyRows(in interval: DateInterval, range: HistoryRange, metricVersion: Int,
                    includeZeroEnergy: Bool = false) async throws -> [EnergyQueryRow] {
        let start = Self.epochMilliseconds(interval.start)
        let end = Self.epochMilliseconds(interval.end)
        let width = Int64(range.bucketSeconds) * 1000
        guard end > start, width > 0 else { return [] }
        return try await dbPool.read { db in
            let arguments: StatementArguments = range == .live
                ? StatementArguments([width, width, start, end, Int64(metricVersion)])
                : Self.queryArguments(start: start, end: end, width: width, metricVersion: metricVersion,
                                      watermark: try Self.watermark(db, for: range, metricVersion: metricVersion), range: range)
            let rows = try Row.fetchAll(db, sql: Self.energySQL(range: range, includeZeroEnergy: includeZeroEnergy), arguments: arguments)
            let values = rows.compactMap { row -> EnergyQueryRow? in
                guard let bucket: Int64 = row["bucketMS"],
                      let name: String = row["displayName"], let energy: Int64 = row["energyNJ"], let cpu: Int64 = row["cpuNs"] else { return nil }
                let bundle: String? = row["bundleIdentifier"]
                let path: String? = row["path"]
                let identity = AppIdentity.resolve(bundleIdentifier: bundle, processName: name, path: path)
                return EnergyQueryRow(bucketMS: bucket, groupKey: identity.groupKey,
                                      bundleIdentifier: bundle, displayName: identity.displayName, path: path,
                                      energyNJ: energy, cpuNS: cpu)
            }
            return Self.mergeEnergyRows(values)
        }
    }

    struct CanonicalEnergyKey: Hashable {
        let bucketMS: Int64
        let groupKey: String
    }

    static func mergeEnergyRows(_ rows: [EnergyQueryRow]) -> [EnergyQueryRow] {
        let grouped = Dictionary(grouping: rows, by: { CanonicalEnergyKey(bucketMS: $0.bucketMS, groupKey: $0.groupKey) })
        return grouped.map { key, values in
            let first = values[0]
            return EnergyQueryRow(bucketMS: key.bucketMS, groupKey: key.groupKey,
                                  bundleIdentifier: first.bundleIdentifier, displayName: first.displayName,
                                  path: first.path,
                                  energyNJ: values.reduce(0) { $0 + $1.energyNJ },
                                  cpuNS: values.reduce(0) { $0 + $1.cpuNS })
        }.sorted { $0.bucketMS == $1.bucketMS ? $0.groupKey < $1.groupKey : $0.bucketMS < $1.bucketMS }
    }

    static func mergeBreakdownEntries(_ entries: [AppBreakdownEntry]) -> [AppBreakdownEntry] {
        let grouped = Dictionary(grouping: entries, by: \.id)
        return grouped.map { _, values in
            let first = values[0]
            return AppBreakdownEntry(bundleIdentifier: first.bundleIdentifier, processName: first.processName,
                                     path: first.path,
                                     totalEnergyNJ: values.reduce(0) { $0 + $1.totalEnergyNJ },
                                     totalCPUNS: values.reduce(0) { $0 + $1.totalCPUNS },
                                     isSystem: first.isSystem)
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

    static func energySQL(range: HistoryRange, includeZeroEnergy: Bool = false) -> String {
        if range == .live {
            return """
                SELECT (r.ts / ?) * ? AS bucketMS, a.groupKey, a.bundleIdentifier, a.displayName, a.path, SUM(r.energyNJ) AS energyNJ, SUM(r.cpuNs) AS cpuNs
                FROM AppSampleRaw r JOIN App a ON a.id = r.appId
                WHERE r.ts >= ? AND r.ts < ? AND r.metricVersion = ?
                GROUP BY bucketMS, r.appId \(includeZeroEnergy ? "" : "HAVING energyNJ > 0") ORDER BY bucketMS, a.groupKey
                """
        }
        let isHour = range == .d7
        let table = isHour ? "AppUsageHour" : "AppUsageMinute"
        let timeCol = isHour ? "hour" : "minute"
        let unitMS: Int64 = isHour ? 3_600_000 : 60_000
        return """
            WITH tier AS (
                SELECT ((u.\(timeCol) * \(unitMS)) / ?) * ? AS bucketMS, u.appId, u.energyNJ, u.cpuNs
                FROM \(table) u WHERE u.\(timeCol) * \(unitMS) >= ? AND u.\(timeCol) * \(unitMS) < ? AND u.metricVersion = ?
                UNION ALL
                SELECT (r.ts / ?) * ? AS bucketMS, r.appId, r.energyNJ, r.cpuNs
                FROM AppSampleRaw r WHERE r.ts >= ? AND r.ts < ? AND r.metricVersion = ?
                    AND (r.ts >= ? OR r.ts < ? OR r.ts >= ?)
            )
            SELECT t.bucketMS, a.groupKey, a.bundleIdentifier, a.displayName, a.path, SUM(t.energyNJ) AS energyNJ, SUM(t.cpuNs) AS cpuNs
            FROM tier t JOIN App a ON a.id = t.appId GROUP BY t.bucketMS, t.appId \(includeZeroEnergy ? "" : "HAVING energyNJ > 0") ORDER BY t.bucketMS, a.groupKey
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
