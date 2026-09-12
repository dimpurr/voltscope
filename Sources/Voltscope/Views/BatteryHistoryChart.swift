import SwiftUI
import Charts
import VoltscopeCore

struct BatteryHistoryChart: View {
    let snapshots: [BatterySnapshot]
    let events: [PowerEvent]
    let domain: ClosedRange<Date>
    let selection: DateInterval?

    private struct LevelPoint: Identifiable {
        let date: Date
        let level: Double
        let segment: Int
        var id: Date { date }
    }

    private var levels: [LevelPoint] {
        var result: [LevelPoint] = []
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
                result.append(LevelPoint(date: Date(timeIntervalSince1970: Double(snapshot.timestamp) / 1000), level: min(100, max(0, level)), segment: segment))
                lastEmitted = snapshot.timestamp
            }
        }
        return result
    }

    private var charging: [DateInterval] {
        var result: [DateInterval] = []
        for (a, b) in zip(snapshots, snapshots.dropFirst()) where a.isCharging && b.isCharging && b.timestamp - a.timestamp <= 90_000 {
            let interval = DateInterval(start: Date(timeIntervalSince1970: Double(a.timestamp) / 1000), end: Date(timeIntervalSince1970: Double(b.timestamp) / 1000))
            if let last = result.last, last.end == interval.start {
                result[result.count - 1] = DateInterval(start: last.start, end: interval.end)
            } else { result.append(interval) }
        }
        return result
    }

    private var sleep: [DateInterval] {
        var start: Date?
        var result: [DateInterval] = []
        for event in events {
            let date = Date(timeIntervalSince1970: Double(event.timestamp) / 1000)
            if event.eventType == "sleep" { start = date }
            if event.eventType == "wake", let begin = start {
                result.append(DateInterval(start: begin, end: date)); start = nil
            }
        }
        if let start, start < domain.upperBound { result.append(DateInterval(start: start, end: domain.upperBound)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Battery level").font(.headline)
                Spacer()
                Label("Charging", systemImage: "bolt.fill").foregroundStyle(.green)
                Label("Sleep", systemImage: "moon.fill").foregroundStyle(.secondary)
            }.font(.caption)
            HStack(alignment: .top, spacing: 6) {
                Chart {
                    ForEach(levels) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Battery", point.level), series: .value("Segment", point.segment))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(.green)
                            .lineStyle(StrokeStyle(lineWidth: 1.8))
                        PointMark(x: .value("Time", point.date), y: .value("Battery", point.level))
                            .symbolSize(3).foregroundStyle(.green)
                    }
                    ForEach(charging.indices, id: \.self) { i in
                        RectangleMark(xStart: .value("Start", charging[i].start), xEnd: .value("End", charging[i].end), yStart: .value("Bottom", -8), yEnd: .value("Top", -3))
                            .foregroundStyle(.green)
                    }
                    ForEach(sleep.indices, id: \.self) { i in
                        RectangleMark(xStart: .value("Start", sleep[i].start), xEnd: .value("End", sleep[i].end), yStart: .value("Bottom", -15), yEnd: .value("Top", -10))
                            .foregroundStyle(.secondary.opacity(0.35))
                    }
                    if let selection {
                        RectangleMark(xStart: .value("Start", selection.start), xEnd: .value("End", selection.end), yStart: .value("Bottom", 0), yEnd: .value("Top", 100))
                            .foregroundStyle(Color.accentColor.opacity(0.12))
                    }
                    RuleMark(y: .value("Full", 100)).foregroundStyle(.secondary.opacity(0.12))
                    RuleMark(y: .value("Empty", 0)).foregroundStyle(.secondary.opacity(0.12))
                }
                .chartXScale(domain: domain).chartYScale(domain: -17...100)
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartPlotStyle { $0.clipped() }
                .overlay {
                    if levels.isEmpty { Text("No battery observations in this range").font(.caption).foregroundStyle(.secondary) }
                }
                VStack { Text("100%"); Spacer(); Text("0%").padding(.bottom, 12) }
                    .font(.caption2).foregroundStyle(.secondary).frame(width: 38)
            }.frame(height: 80)

        }.help("Battery level uses a fixed 0–100% scale. Gaps indicate missing observations; charging and sleep are shown below the trace.")
    }
}
