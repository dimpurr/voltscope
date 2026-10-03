import Foundation

/// Text and values shared by History chart accessibility labels and chart descriptors.
public enum HistoryChartAccessibility {
    public struct Point: Sendable, Equatable {
        public let date: Date
        public let value: Double
        public init(date: Date, value: Double) { self.date = date; self.value = value }
    }

    public static func summary(title: String, range: ClosedRange<Date>, points: [Point], unit: String,
                               bucketSeconds: Int? = nil, hasMissingIntervals: Bool = false, mixedMetricVersions: Bool = false,
                               scopeNote: String? = nil) -> String {
        let ordered = points.filter { range.contains($0.date) }.sorted { $0.date < $1.date }
        let rangeText = "\(range.lowerBound.formatted(date: .abbreviated, time: .shortened)) to \(range.upperBound.formatted(date: .abbreviated, time: .shortened))"
        var parts = [title, "range \(rangeText)"]
        guard !ordered.isEmpty else {
            parts.append("No data")
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

    public static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
