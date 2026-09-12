import Foundation
import GRDB

/// A closed time bucket containing only recorded per-process CPU attribution.
/// All apps are retained; presentation may collapse the long tail without losing energy.
public struct HistoryEnergyPoint: Identifiable, Sendable, Equatable {
    public let appID: String
    public let name: String
    public let bundleIdentifier: String?
    public let path: String?
    public let isSystem: Bool
    public let date: Date
    public let energyNJ: Int64
    public var id: String { "\(appID)@\(date.timeIntervalSince1970)" }
}

public struct HistoryApp: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let path: String?
    public let isSystem: Bool
    public let energyNJ: Int64
}

public enum HistoryMath {
    public static func apps(_ points: [HistoryEnergyPoint], selection: DateInterval? = nil) -> [HistoryApp] {
        let filtered = points.filter { p in
            guard let selection else { return true }
            return p.date >= selection.start && p.date < selection.end
        }
        return Dictionary(grouping: filtered, by: \.appID).values.compactMap { rows in
            guard let first = rows.first else { return nil }
            return HistoryApp(id: first.appID, name: first.name, bundleIdentifier: first.bundleIdentifier,
                              path: first.path, isSystem: first.isSystem,
                              energyNJ: rows.reduce(0) { $0 + $1.energyNJ })
        }.sorted { $0.energyNJ == $1.energyNJ ? $0.id < $1.id : $0.energyNJ > $1.energyNJ }
    }

    /// Only integrate adjacent, observed discharge samples. Reject power-state
    /// transitions, missing values and gaps beyond three battery sample periods.
    /// Endpoint trapezoids are clipped to the requested window; no sleep inference.
    public static func drainJ(_ snapshots: [BatterySnapshot], within interval: DateInterval) -> Double {
        let ordered = snapshots.sorted { $0.timestamp < $1.timestamp }
        return zip(ordered, ordered.dropFirst()).reduce(0) { total, pair in
            let (a, b) = pair
            let start = Double(a.timestamp) / 1000
            let end = Double(b.timestamp) / 1000
            guard end > start, end - start <= 90,
                  !a.isACPlugged, !b.isACPlugged, !a.isCharging, !b.isCharging,
                  let av = a.voltageMV, let bv = b.voltageMV, av > 0, bv > 0,
                  let ai = a.amperageMA, let bi = b.amperageMA, ai <= 0, bi <= 0 else { return total }
            let lo = max(start, interval.start.timeIntervalSince1970)
            let hi = min(end, interval.end.timeIntervalSince1970)
            guard hi > lo else { return total }
            let wa = Double(av) * -Double(ai) / 1_000_000
            let wb = Double(bv) * -Double(bi) / 1_000_000
            let left = wa + (wb - wa) * (lo - start) / (end - start)
            let right = wa + (wb - wa) * (hi - start) / (end - start)
            return total + (left + right) / 2 * (hi - lo)
        }
    }
}

extension AppDatabase {
    /// Explicit bounds keep chart, selection and totals on a single snapshot of time.
    public func historyEnergy(in interval: DateInterval, bucketSeconds: Int) async throws -> [HistoryEnergyPoint] {
        guard bucketSeconds > 0 else { return [] }
        let start = Int64(interval.start.timeIntervalSince1970 * 1000)
        let end = Int64(interval.end.timeIntervalSince1970 * 1000)
        let bucket = Int64(bucketSeconds) * 1000
        return try await dbPool.read { db in
            // One indexed time-range scan. A CTE joined back by COALESCE caused
            // repeated scans for every app on large histories.
            let rows = try Row.fetchAll(db, sql: """
                SELECT COALESCE(bundleIdentifier, processName) AS appID,
                       bundleIdentifier, MIN(processName) AS name, MAX(path) AS path,
                       (timestamp / ?) * ? AS bucket, SUM(energyNJ) AS energy
                FROM EnergyHistory WHERE timestamp >= ? AND timestamp < ?
                GROUP BY appID, bucket HAVING energy > 0 ORDER BY bucket, appID
                """, arguments: [bucket, bucket, start, end])
            var names: [String: String] = [:]
            var paths: [String: String] = [:]
            for row in rows {
                let id: String = row["appID"]
                let name: String = row["name"]
                names[id] = min(names[id] ?? name, name)
                if let path: String = row["path"] { paths[id] = max(paths[id] ?? path, path) }
            }
            return rows.map { row in
                let id: String = row["appID"]
                let name = names[id] ?? id
                let bundle: String? = row["bundleIdentifier"]
                let path = paths[id]
                return HistoryEnergyPoint(appID: id, name: name, bundleIdentifier: bundle,
                    path: path, isSystem: AppClassification.isSystem(bundleIdentifier: bundle, processName: name, path: path),
                    date: Date(timeIntervalSince1970: Double(row["bucket"] as Int64) / 1000), energyNJ: row["energy"])
            }
        }
    }

    public func batteryHistory(in interval: DateInterval) async throws -> [BatterySnapshot] {
        let start = Int64(interval.start.timeIntervalSince1970 * 1000)
        let end = Int64(interval.end.timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in
            try BatterySnapshot.fetchAll(db, sql: """
                SELECT * FROM BatteryStatus WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp
                """, arguments: [start - 90_000, end])
        }
    }
}

/// Immutable rendering data. Build after a query or a grouping change, never on hover.
public struct HistoryChartModel: Equatable, Sendable {
    public struct Segment: Identifiable, Equatable, Sendable {
        public let date: Date
        public let group: String
        public let bottom: Double
        public let top: Double
        public var id: String { "\(group)@\(date.timeIntervalSince1970)" }
    }
    public struct Series: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
    }
    public static let otherID = "voltscope:group:other"
    public static let systemID = "voltscope:group:system"
    public let segments: [Segment]
    public let series: [Series]
    public let upper: Double
    public let bucketTotals: [Date: Double]
    public let bucketItems: [Date: [String]]

    public init(points: [HistoryEnergyPoint], groupSystem: Bool, selectedApp: String? = nil) {
        let apps = HistoryMath.apps(points)
        let metadata = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        var ids = Array(apps.filter { !groupSystem || !$0.isSystem }.prefix(4).map(\.id))
        if let selectedApp, metadata[selectedApp] != nil, !ids.contains(selectedApp) { ids.append(selectedApp) }
        let explicit = Set(ids)
        if groupSystem && apps.contains(where: { $0.isSystem && !explicit.contains($0.id) }) { ids.append(Self.systemID) }
        if apps.contains(where: { !explicit.contains($0.id) && !(groupSystem && $0.isSystem) }) { ids.append(Self.otherID) }
        series = ids.map { Series(id: $0, name: $0 == Self.otherID ? "Other apps" : $0 == Self.systemID ? "System" : metadata[$0]?.name ?? $0) }
        var stacks: [Segment] = []
        var bucketTotals: [Date: Double] = [:]
        var bucketItems: [Date: [String]] = [:]
        for (date, rows) in Dictionary(grouping: points, by: \.date) {
            var totals: [String: Double] = [:]
            for point in rows {
                let group = explicit.contains(point.appID) ? point.appID : groupSystem && point.isSystem ? Self.systemID : Self.otherID
                totals[group, default: 0] += Double(point.energyNJ) / 1e9
            }
            var baseline = 0.0
            for id in ids {
                guard let energy = totals[id], energy > 0 else { continue }
                stacks.append(Segment(date: date, group: id, bottom: baseline, top: baseline + energy))
                baseline += energy
            }
            bucketTotals[date] = baseline
            bucketItems[date] = rows.sorted { $0.energyNJ > $1.energyNJ }.prefix(3).map {
                "\($0.name) · \(String(format: "%.2f J", Double($0.energyNJ) / 1e9))"
            }
        }
        segments = stacks.sorted { $0.date == $1.date ? $0.bottom < $1.bottom : $0.date < $1.date }
        let peak = bucketTotals.values.max() ?? 0
        // Rounded scale with meaningful tick values instead of arbitrary 122.4 J.
        if peak > 0 {
            let magnitude = pow(10, floor(log10(peak)))
            upper = ceil(peak / magnitude) * magnitude
        } else { upper = 1 }
        self.bucketTotals = bucketTotals
        self.bucketItems = bucketItems
    }
}

extension HistoryApp {
    public var breakdownEntry: AppDatabase.AppBreakdownEntry {
        AppDatabase.AppBreakdownEntry(bundleIdentifier: bundleIdentifier, processName: name,
                                     path: path, totalEnergyNJ: energyNJ, isSystem: isSystem)
    }
}

extension AppDatabase {
    public func historyHardware(in interval: DateInterval, bucketSeconds: Int) async throws -> [BucketSummary] {
        guard bucketSeconds > 0 else { return [] }
        let start = Int64(interval.start.timeIntervalSince1970 * 1000)
        let end = Int64(interval.end.timeIntervalSince1970 * 1000)
        let width = Int64(bucketSeconds) * 1000
        return try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT bucketName, (timestamp / ?) * ? AS timeBucket, SUM(energyNJ) AS energy
                FROM SystemBuckets WHERE timestamp >= ? AND timestamp < ?
                GROUP BY bucketName, timeBucket ORDER BY timeBucket
                """, arguments: [width, width, start, end])
            var points: [String: [BucketSummary.SparkPoint]] = [:]
            for row in rows {
                let name: String = row["bucketName"]
                points[name, default: []].append(BucketSummary.SparkPoint(
                    bucketStart: Date(timeIntervalSince1970: Double(row["timeBucket"] as Int64) / 1000), energyNJ: row["energy"]))
            }
            return points.map { name, values in
                BucketSummary(bucketName: name, totalEnergyNJ: values.reduce(0) { $0 + $1.energyNJ }, sparkline: values)
            }.sorted { $0.totalEnergyNJ == $1.totalEnergyNJ ? $0.bucketName < $1.bucketName : $0.totalEnergyNJ > $1.totalEnergyNJ }
        }
    }

    public func historyEvents(in interval: DateInterval) async throws -> [PowerEvent] {
        let start = Int64(interval.start.timeIntervalSince1970 * 1000)
        let end = Int64(interval.end.timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in
            try PowerEvent.fetchAll(db, sql: """
                SELECT * FROM PowerEvents WHERE timestamp >= ? AND timestamp < ?
                OR timestamp = (SELECT MAX(timestamp) FROM PowerEvents WHERE timestamp < ? AND eventType IN ('sleep', 'wake'))
                ORDER BY timestamp
                """, arguments: [start, end, start])
        }
    }
}

extension AppDatabase {
    public func historySamples(in interval: DateInterval) async throws -> [EnergySample] {
        let start = Int64(interval.start.timeIntervalSince1970 * 1000)
        let end = Int64(interval.end.timeIntervalSince1970 * 1000)
        return try await dbPool.read { db in
            try EnergySample.filter(Column("timestamp") >= start && Column("timestamp") < end)
                .order(Column("timestamp"), Column("sampleId")).fetchAll(db)
        }
    }
}
