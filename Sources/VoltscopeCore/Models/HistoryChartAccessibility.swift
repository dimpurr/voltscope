import Foundation

/// Text and values shared by History chart accessibility labels and chart descriptors.
public enum HistoryChartAccessibility {
    public struct Point: Sendable, Equatable {
        public let date: Date
        public let value: Double
        public init(date: Date, value: Double) { self.date = date; self.value = value }
    }

    /// Battery level points for the accessibility chart descriptor and spoken
    /// summary. Contains only real observations inside `domain`; charging and
    /// sleep events are never encoded as level points.
    public static func batteryPoints(snapshots: [BatterySnapshot], domain: ClosedRange<Date>) -> [Point] {
        snapshots.compactMap { snapshot in
            guard let level = snapshot.levelPercent else { return nil }
            let date = Date(timeIntervalSince1970: Double(snapshot.timestamp) / 1000)
            guard domain.contains(date) else { return nil }
            return Point(date: date, value: min(100, max(0, level)))
        }
    }

    public struct BatteryLevelPoint: Sendable, Equatable {
        public let date: Date
        public let level: Double
        public let segment: Int
        public init(date: Date, level: Double, segment: Int) {
            self.date = date
            self.level = level
            self.segment = segment
        }
    }

    public struct BatteryLevelSeries: Sendable, Equatable {
        public let segment: Int
        public let points: [Point]
        public init(segment: Int, points: [Point]) {
            self.segment = segment
            self.points = points
        }
    }

    /// Ordered battery level trace points derived only from battery snapshots.
    /// Charging and sleep events are not inputs, so an event can never be
    /// encoded as a level reading: a snapshot taken while charging keeps its
    /// observed percentage instead of being forced to 100, and a missing
    /// observation stays a gap instead of becoming a 0 point. `segment`
    /// increments at gaps so the chart does not interpolate across missing data.
    public static func batteryLevelPoints(snapshots: [BatterySnapshot], domain: ClosedRange<Date>) -> [BatteryLevelPoint] {
        var result: [BatteryLevelPoint] = []
        var segment = 0
        var previous: BatterySnapshot?
        var lastEmitted: Int64 = 0
        let resolution = max(30.0, domain.upperBound.timeIntervalSince(domain.lowerBound) / 400)
        for (index, snapshot) in snapshots.enumerated() {
            defer { previous = snapshot }
            guard let level = snapshot.levelPercent else { segment += 1; continue }
            let gap = previous.map { snapshot.timestamp - $0.timestamp > 90_000 || $0.levelPercent == nil } ?? true
            if gap { segment += 1 }
            let nextGap = index + 1 == snapshots.count || snapshots[index + 1].timestamp - snapshot.timestamp > 90_000 || snapshots[index + 1].levelPercent == nil
            if gap || nextGap || previous?.levelPercent != level || Double(snapshot.timestamp - lastEmitted) >= resolution * 1000 {
                result.append(BatteryLevelPoint(date: Date(timeIntervalSince1970: Double(snapshot.timestamp) / 1000),
                                                level: min(100, max(0, level)), segment: segment))
                lastEmitted = snapshot.timestamp
            }
        }
        return result
    }

    /// Chart descriptor series for the battery chart, grouped by trace segment.
    /// Built from `batteryLevelPoints`, so charging and sleep events cannot
    /// appear as battery level points. Only readings inside `domain` are kept.
    public static func batteryLevelSeries(snapshots: [BatterySnapshot], domain: ClosedRange<Date>) -> [BatteryLevelSeries] {
        let points = batteryLevelPoints(snapshots: snapshots, domain: domain).filter { domain.contains($0.date) }
        let grouped = Dictionary(grouping: points, by: \.segment)
        return grouped.keys.sorted().map { segment in
            BatteryLevelSeries(segment: segment,
                               points: grouped[segment, default: []].map { Point(date: $0.date, value: $0.level) })
        }
    }

    /// Spoken value for a keyboard-inspected App CPU energy bucket. Names the
    /// metric as recorded CPU energy (docs/ENERGY_MODEL.md: it is not an
    /// allocation of whole-device battery drain) and distinguishes a bucket
    /// with no record from a bucket recorded with zero energy. A missing record
    /// is not asserted to be a data gap: the model only builds totals for
    /// buckets with observations, so an absent bucket may be idle or a missing
    /// observation. Only call it a gap when there is actual evidence (e.g. the
    /// bucket falls within a known coverage gap).
    public static func bucketInspectorValue(date: Date, recordedJoules: Double?) -> String {
        let time = date.formatted(date: .abbreviated, time: .shortened)
        guard let recordedJoules else {
            return "\(time): no recorded CPU energy for this bucket"
        }
        return "\(time): \(format(recordedJoules)) joules recorded CPU energy"
    }

    /// Clips intervals to `range`, dropping intervals with no overlap and
    /// clamping partial overlaps to the range bounds. Used so spoken summaries
    /// only count charging and sleep time inside the selected domain.
    public static func clipIntervals(_ intervals: [DateInterval], to range: ClosedRange<Date>) -> [DateInterval] {
        intervals.compactMap { interval in
            let start = max(interval.start, range.lowerBound)
            let end = min(interval.end, range.upperBound)
            guard start < end else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    public static func summary(title: String, range: ClosedRange<Date>, points: [Point], unit: String,
                               bucketSeconds: Int? = nil, hasMissingIntervals: Bool = false, mixedMetricVersions: Bool = false,
                               chargingIntervals: [DateInterval] = [], sleepIntervals: [DateInterval] = [],
                               scopeNote: String? = nil) -> String {
        let ordered = points.filter { range.contains($0.date) }.sorted { $0.date < $1.date }
        let charging = clipIntervals(chargingIntervals, to: range)
        let sleep = clipIntervals(sleepIntervals, to: range)
        let rangeText = "\(range.lowerBound.formatted(date: .abbreviated, time: .shortened)) to \(range.upperBound.formatted(date: .abbreviated, time: .shortened))"
        var parts = [title, "range \(rangeText)"]
        guard !ordered.isEmpty else {
            parts.append("No data")
            if !charging.isEmpty {
                let totalChargingSeconds = charging.reduce(0.0) { $0 + $1.duration }
                parts.append("Charging: \(charging.count) interval\(charging.count == 1 ? "" : "s"), total \(formatDuration(totalChargingSeconds))")
            }
            if !sleep.isEmpty {
                let totalSleepSeconds = sleep.reduce(0.0) { $0 + $1.duration }
                parts.append("Sleep: \(sleep.count) period\(sleep.count == 1 ? "" : "s"), total \(formatDuration(totalSleepSeconds))")
            }
            if let scopeNote { parts.append(scopeNote) }
            if mixedMetricVersions { parts.append("Older metric-version data is marked separately and is not combined with current data.") }
            return parts.joined(separator: ". ")
        }
        let minimum = ordered.min { $0.value < $1.value }!
        let maximum = ordered.max { $0.value < $1.value }!
        let current = ordered.last!
        parts.append("minimum \(format(minimum.value)) \(unit) at \(minimum.date.formatted(date: .abbreviated, time: .shortened))")
        parts.append("maximum \(format(maximum.value)) \(unit) at \(maximum.date.formatted(date: .abbreviated, time: .shortened))")
        parts.append("current \(format(current.value)) \(unit) at \(current.date.formatted(date: .abbreviated, time: .shortened))")
        if !charging.isEmpty {
            let totalChargingSeconds = charging.reduce(0.0) { $0 + $1.duration }
            parts.append("Charging: \(charging.count) interval\(charging.count == 1 ? "" : "s"), total \(formatDuration(totalChargingSeconds))")
        }
        if !sleep.isEmpty {
            let totalSleepSeconds = sleep.reduce(0.0) { $0 + $1.duration }
            parts.append("Sleep: \(sleep.count) period\(sleep.count == 1 ? "" : "s"), total \(formatDuration(totalSleepSeconds))")
        }
        let hasTimeGap = bucketSeconds.map { interval in
            ordered.count > 1 && zip(ordered, ordered.dropFirst()).contains {
                $1.date.timeIntervalSince($0.date) > Double(interval) * 1.5
            }
        } ?? false
        if hasMissingIntervals || hasTimeGap {
            parts.append("Gaps are no data; values are not interpolated.")
        }
        if let scopeNote { parts.append(scopeNote) }
        if mixedMetricVersions { parts.append("Older metric-version data is marked separately and is not combined with current data.") }
        return parts.joined(separator: ". ")
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 {
            return m > 0 ? "\(h) hr \(m) min" : "\(h) hr"
        } else if m > 0 {
            return "\(m) min"
        } else {
            return "\(s) s"
        }
    }

    public static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
