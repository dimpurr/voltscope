import Accessibility
import SwiftUI
import VoltscopeCore

struct HistoryAXSeries {
    let name: String
    let points: [AXDataPoint]
    let isContinuous: Bool
}

struct HistoryAXChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let summary: String
    let xTitle: String
    let yTitle: String
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>
    let series: [HistoryAXSeries]

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXNumericDataAxisDescriptor(title: xTitle, range: xRange, gridlinePositions: []) { value in
            Date(timeIntervalSince1970: value).formatted(date: .abbreviated, time: .shortened)
        }
        let yAxis = AXNumericDataAxisDescriptor(title: yTitle, range: yRange, gridlinePositions: []) { value in
            "\(HistoryChartAccessibility.format(value)) \(yTitle)"
        }
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis,
                                 series: series.map { AXDataSeriesDescriptor(name: $0.name, isContinuous: $0.isContinuous, dataPoints: $0.points) })
    }
}
