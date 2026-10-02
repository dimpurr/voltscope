import Foundation

/// The History time ranges shared by the chart, breakdown columns, and CSV export.
///
/// This is the single source of truth for range names, window lengths, bucket
/// widths, and labels. `docs/UI_SPEC.md` renders its range table from
/// `documentationTable`, and `HistoryRangeDocsTests` fails if the checked-in
/// table drifts from `HistoryRange.allCases`.
public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case live = "Live"
    case h1 = "1H"
    case h6 = "6H"
    case h24 = "24H"
    case d7 = "7D"

    public var id: String { rawValue }

    /// Window length in minutes used to build the query interval.
    public var minutes: Int {
        switch self {
        case .live: return 30
        case .h1: return 60
        case .h6: return 360
        case .h24: return 1440
        case .d7: return 10080
        }
    }

    /// Bucket width in seconds used for energy and hardware queries.
    public var bucketSeconds: Int {
        switch self {
        case .live: return 30
        case .h1: return 120
        case .h6: return 600
        case .h24: return 1800
        case .d7: return 21600
        }
    }

    /// Human-readable bucket width shown next to the app attribution total.
    public var bucketLabel: String {
        switch self {
        case .live: return "30 seconds"
        case .h1: return "2 minutes"
        case .h6: return "10 minutes"
        case .h24: return "30 minutes"
        case .d7: return "6 hours · UTC"
        }
    }

    /// Human-readable window length for the generated documentation table.
    public var windowLabel: String {
        switch self {
        case .live: return "30 minutes"
        case .h1: return "1 hour"
        case .h6: return "6 hours"
        case .h24: return "24 hours"
        case .d7: return "7 days"
        }
    }

    /// Markdown table rendered into `docs/UI_SPEC.md` between the generated markers.
    public static var documentationTable: String {
        var lines = [
            "| Range | Window | Bucket width | Label |",
            "| --- | --- | --- | --- |"
        ]
        for range in allCases {
            lines.append("| \(range.rawValue) | \(range.windowLabel) | \(range.bucketSeconds) s | \(range.bucketLabel) |")
        }
        return lines.joined(separator: "\n")
    }
}
