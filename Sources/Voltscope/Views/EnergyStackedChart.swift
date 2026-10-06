import SwiftUI
import Charts
import VoltscopeCore

@MainActor
struct EnergyStackedChart: View {
    let model: HistoryChartModel
    let bucketSeconds: Int
    let xDomain: ClosedRange<Date>
    @Binding var selectedApp: String?

    @MainActor private func color(_ id: String) -> Color {
        HistoryColors.color(id)
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

    private var accessibilityPoints: [HistoryChartAccessibility.Point] {
        model.bucketTotals.map { HistoryChartAccessibility.Point(date: $0.key, value: $0.value) }
    }

    private var accessibilitySummary: String {
        HistoryChartAccessibility.summary(title: "App CPU energy", range: xDomain, points: accessibilityPoints,
                                          unit: "joules", bucketSeconds: bucketSeconds,
                                          mixedMetricVersions: !model.legacyBuckets.isEmpty,
                                          scopeNote: "Recorded per-app CPU energy only; it is not an allocation of whole-device battery drain.")
    }

    private var chartDescriptor: HistoryAXChartDescriptor {
        let series = model.series.map { item in
            let points = model.segments.filter { $0.group == item.id }.map { segment in
                AXDataPoint(x: segment.date.timeIntervalSince1970, y: segment.top - segment.bottom,
                            label: "\(item.name), \(segment.date.formatted(date: .abbreviated, time: .shortened))")
            }
            return HistoryAXSeries(name: "\(item.name) recorded CPU energy", points: points, isContinuous: false)
        }
        return HistoryAXChartDescriptor(title: "App CPU energy", summary: accessibilitySummary,
                                        xTitle: "Time", yTitle: "Joules", xRange: xDomain.lowerBound.timeIntervalSince1970...xDomain.upperBound.timeIntervalSince1970,
                                        yRange: 0...max(model.upper, 0.01), series: series)
    }

    private var valueLabels: some View {
        VStack {
            Text(model.upper.formatted(.number.precision(.fractionLength(1))))
            Spacer(); Text((model.upper / 2).formatted(.number.precision(.fractionLength(1))))
            Spacer(); Text("0").padding(.bottom, 22)
        }
        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 38)
        .accessibilityHidden(true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Chart {
                    ForEach(Array(model.legacyBuckets), id: \.self) { date in
                        RectangleMark(
                            xStart: .value("Older method start", date),
                            xEnd: .value("Older method end", date.addingTimeInterval(Double(bucketSeconds))),
                            yStart: .value("Older method", 0), yEnd: .value("Older method", model.upper)
                        )
                        .foregroundStyle(.orange.opacity(0.18))
                        .accessibilityHidden(true)
                    }
                    ForEach(model.segments) { p in
                        RectangleMark(
                            xStart: .value("Start", p.date.addingTimeInterval(Double(bucketSeconds) * 0.035)),
                            xEnd: .value("End", p.date.addingTimeInterval(Double(bucketSeconds) * 0.965)),
                            yStart: .value("CPU energy", p.bottom), yEnd: .value("CPU energy", p.top))
                            .foregroundStyle(color(p.group))
                            .opacity((selectedApp == nil || selectedApp == p.group ? 1 : 0.18))
                            .accessibilityHidden(true)
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
                .overlay {
                    if model.segments.isEmpty { Text("No recorded CPU energy in this range").font(.callout).foregroundStyle(.secondary) }
                }
                valueLabels
            }
            .frame(height: 210)
            // Collapse the chart into one element. `children: .ignore` (rather
            // than `.contain`) is what publishes the container element on
            // macOS; the summary and descriptor keep per-point detail. The
            // interactive inspector overlay is applied after this element, so
            // it stays a separate, reachable element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AccessibilityLabels.appCPUEnergyChartLabel)
            .accessibilityValue(accessibilitySummary)
            .accessibilityChartDescriptor(chartDescriptor)
            .accessibilityIdentifier(AccessibilityIdentifiers.historyChartEnergy)
            .chartOverlay { proxy in
                EnergyHoverOverlay(model: model, bucketSeconds: bucketSeconds, domain: xDomain, proxy: proxy)
            }
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
                let isSelected = selectedApp == id
                Button {
                    selectedApp = isSelected ? nil : id
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(color(id)).frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(series.name).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                    }
                    .opacity(selectedApp == nil || isSelected ? 1 : 0.45)
                    // The caption is 13 pt tall, well under the minimum target
                    // size, so the chip grows vertically and keeps the whole
                    // padded row clickable.
                    .frame(minHeight: AccessibilityMetrics.minimumTargetSize)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(series.name)
                .accessibilityLabel(series.name)
                .accessibilityIdentifier(AccessibilityIdentifiers.historyLegendChip(seriesID: id))
                .accessibilityValue(AccessibilityLabels.legendSelectionValue(selected: isSelected, anySelected: selectedApp != nil))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityHint(isSelected ? "Double tap to clear app highlight" : "Double tap to highlight app in chart")
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var accessibilityValue: String {
        guard let hovered else { return "No time bucket selected" }
        return HistoryChartAccessibility.bucketInspectorValue(date: hovered, recordedJoules: model.bucketTotals[hovered])
    }

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
                .focusable()
                .onMoveCommand { direction in
                    let step = Double(bucketSeconds)
                    let current = hovered ?? (direction == .left ? domain.upperBound : domain.lowerBound)
                    let nextTime: Double
                    switch direction {
                    case .left:
                        nextTime = current.timeIntervalSince1970 - step
                    case .right:
                        nextTime = current.timeIntervalSince1970 + step
                    default:
                        return
                    }
                    let clamped = max(domain.lowerBound.timeIntervalSince1970,
                                      min(domain.upperBound.timeIntervalSince1970, nextTime))
                    let bucket = Date(timeIntervalSince1970: floor(clamped / step) * step)
                    hovered = bucket
                }
                .onExitCommand {
                    hovered = nil
                }
                .accessibilityLabel("App CPU energy time inspector")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("Use Left and Right arrow keys to inspect time buckets; Escape to dismiss")
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
                .background {
                    if reduceTransparency {
                        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor))
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(.regularMaterial)
                    }
                }
                .position(x: min(frame.maxX - 119, max(frame.minX + 119, x)), y: frame.minY + 54)
                .allowsHitTesting(false)
            }
        }
    }
}

/// Persist identity-to-color assignment instead of assigning colors by energy rank.
@MainActor enum HistoryColors {
    private static let systemPalette: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo, .brown, .mint]
    private static var mapping = UserDefaults.standard.dictionary(forKey: "historyAppColors") as? [String: Int] ?? [:]
    static var palette: [Color] {
        systemPalette.enumerated().map { offset, systemColor in
            HistoryChartPalette.appSlotOverrides[offset].map { Color(historyPair: $0) } ?? systemColor
        }
    }
    static let otherApps = Color(historyPair: HistoryChartPalette.otherAppsSeries)
    static let systemApps = Color(historyPair: HistoryChartPalette.systemSeries)
    static let chargingGreen = Color(historyPair: HistoryChartPalette.chargingGreen)
    static func register(_ ids: [String]) {
        var changed = false
        for id in ids where mapping[id] == nil {
            mapping[id] = (mapping.values.max() ?? -1) + 1
            changed = true
        }
        if changed { UserDefaults.standard.set(mapping, forKey: "historyAppColors") }
    }
    static func color(_ id: String) -> Color {
        if id == HistoryChartModel.otherID { return otherApps }
        if id == HistoryChartModel.systemID { return systemApps }
        let index = max(0, mapping[id] ?? 0)
        if index < systemPalette.count { return palette[index] }
        return Color(hex: HistoryChartPalette.fallbackHex(appIndex: index))
    }
}

extension NSAppearance {
    var isDarkAppearance: Bool {
        bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
    }
}

extension Color {
    /// Explicit light/dark sRGB pair from `HistoryChartPalette`.
    init(historyPair pair: HistoryChartPalette.PaletteColor) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.isDarkAppearance ? NSColor(hex: pair.dark) : NSColor(hex: pair.light)
        }))
    }

    /// Single sRGB color from an 0xRRGGBB value, used by the compensated
    /// hue-sequence fallback which is identical in both appearances.
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
