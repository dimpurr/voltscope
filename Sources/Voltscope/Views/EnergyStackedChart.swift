import SwiftUI
import Charts
import VoltscopeCore

struct EnergyStackedChart: View {
    let model: HistoryChartModel
    let bucketSeconds: Int
    let xDomain: ClosedRange<Date>
    @Binding var selectedApp: String?

    private func color(_ id: String) -> Color {
        if id == HistoryChartModel.otherID { return .gray.opacity(0.4) }
        if id == HistoryChartModel.systemID { return .gray }
        return HistoryColors.color(id)
    }
    private var tickDates: [Date] {
        // Keep the data resolution independent from label density. Seven days
        // has four bars per day, but labeling all 28 bars makes the dates
        // collide even in a wide History window. Daily major ticks preserve
        // the context while the six-hour bars retain the intraday shape.
        let step: Double = bucketSeconds >= 21600 ? 86400 : bucketSeconds >= 1800 ? 21600 : bucketSeconds >= 600 ? 3600 : bucketSeconds >= 120 ? 900 : 300
        let margin = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) * 0.04
        let first = ceil((xDomain.lowerBound.timeIntervalSince1970 + margin) / step) * step
        return stride(from: first, through: xDomain.upperBound.timeIntervalSince1970 - margin, by: step)
            .map { Date(timeIntervalSince1970: $0) }
    }
    private var tickFormat: Date.FormatStyle {
        if bucketSeconds >= 21600 { return .dateTime.month(.abbreviated).day() }
        if bucketSeconds >= 1800 { return .dateTime.month(.abbreviated).day().hour() }
        if bucketSeconds >= 600 { return .dateTime.hour().minute() }
        return .dateTime.hour().minute()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Chart {
                    ForEach(model.segments) { p in
                        RectangleMark(
                            xStart: .value("Start", p.date.addingTimeInterval(Double(bucketSeconds) * 0.035)),
                            xEnd: .value("End", p.date.addingTimeInterval(Double(bucketSeconds) * 0.965)),
                            yStart: .value("CPU energy", p.bottom), yEnd: .value("CPU energy", p.top))
                            .foregroundStyle(color(p.group))
                            .opacity((selectedApp == nil || selectedApp == p.group ? 1 : 0.18))
                            .accessibilityLabel("\(model.series.first(where: { $0.id == p.group })?.name ?? p.group), \(p.date.formatted()), \(String(format: "%.2f", p.top - p.bottom)) joules CPU energy")
                    }
                    ForEach([0.0, model.upper / 2, model.upper], id: \.self) { y in
                        RuleMark(y: .value("Grid", y)).foregroundStyle(.secondary.opacity(0.12))
                    }

                }
                .chartXScale(domain: xDomain).chartYScale(domain: 0...model.upper)
                .chartYAxis(.hidden).chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: tickDates) { _ in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel(format: tickFormat)
                    }
                }
                .chartPlotStyle { $0.clipped() }
                .chartOverlay { proxy in
                    EnergyHoverOverlay(model: model, bucketSeconds: bucketSeconds, domain: xDomain, proxy: proxy)
                }
                .overlay {
                    if model.segments.isEmpty { Text("No recorded CPU energy in this range").font(.callout).foregroundStyle(.secondary) }
                }
                VStack {
                    Text(model.upper.formatted(.number.precision(.fractionLength(1))))
                    Spacer(); Text((model.upper / 2).formatted(.number.precision(.fractionLength(1))))
                    Spacer(); Text("0").padding(.bottom, 22)
                }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 38)
            }.frame(height: 210)
            ViewThatFits(in: .horizontal) {
                legend
                ScrollView(.horizontal, showsIndicators: false) { legend }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(model.series) { series in
                let id = series.id
                Button {
                    selectedApp = selectedApp == id ? nil : id
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(color(id)).frame(width: 7, height: 7)
                        Text(series.name).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                    }
                    .opacity(selectedApp == nil || selectedApp == id ? 1 : 0.45)
                }.buttonStyle(.plain).help(series.name)
            }
        }.font(.caption).fixedSize(horizontal: true, vertical: false)
    }
}

/// Hover state is isolated so pointer motion never rebuilds the chart or app list.
private struct EnergyHoverOverlay: View {
    let model: HistoryChartModel
    let bucketSeconds: Int
    let domain: ClosedRange<Date>
    let proxy: ChartProxy
    @State private var hovered: Date?

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry[proxy.plotAreaFrame]
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) else { hovered = nil; return }
                        let bucket = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / Double(bucketSeconds)) * Double(bucketSeconds))
                        if hovered != bucket { hovered = bucket }
                    case .ended: hovered = nil
                    }
                }
            if let hovered {
                let x = (proxy.position(forX: hovered.addingTimeInterval(Double(bucketSeconds) / 2)) ?? 0) + frame.minX
                Path { path in
                    path.move(to: CGPoint(x: x, y: frame.minY))
                    path.addLine(to: CGPoint(x: x, y: frame.maxY))
                }.stroke(Color.primary.opacity(0.25), lineWidth: 1).allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hovered.formatted(.dateTime.month().day().hour().minute())).fontWeight(.semibold)
                    if hovered < domain.lowerBound || hovered.addingTimeInterval(Double(bucketSeconds)) > domain.upperBound {
                        Text("Partial bucket").foregroundStyle(.secondary)
                    }
                    ForEach(model.bucketItems[hovered] ?? [], id: \.self) { Text($0).lineLimit(1) }
                    Text(String(format: "CPU total: %.2f J", model.bucketTotals[hovered] ?? 0))
                    if model.bucketTotals[hovered] == nil { Text("Idle or missing observations").foregroundStyle(.secondary) }
                }
                .font(.caption2).padding(8)
                .frame(width: min(230, frame.width - 8), alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .position(x: min(frame.maxX - 119, max(frame.minX + 119, x)), y: frame.minY + 54)
                .allowsHitTesting(false)
            }
        }
    }
}

/// Persist identity-to-color assignment instead of assigning colors by energy rank.
@MainActor enum HistoryColors {
    static let palette: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo, .brown, .mint]
    private static var mapping = UserDefaults.standard.dictionary(forKey: "historyAppColors") as? [String: Int] ?? [:]
    static func register(_ ids: [String]) {
        var changed = false
        for id in ids where mapping[id] == nil {
            mapping[id] = (mapping.values.max() ?? -1) + 1
            changed = true
        }
        if changed { UserDefaults.standard.set(mapping, forKey: "historyAppColors") }
    }
    static func color(_ id: String) -> Color {
        let index = max(0, mapping[id] ?? 0)
        if index < palette.count { return palette[index] }
        return Color(hue: (Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.85)
    }
}
