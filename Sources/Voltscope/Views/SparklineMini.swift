import SwiftUI

struct SparkPoint: Hashable, Sendable {
    let date: Date
    let value: Double
}

/// Tiny per-row bars do not need a full Swift Charts layout/AX engine per app.
struct SparklineMini: View {
    let points: [SparkPoint]
    var color: Color = .accentColor
    var width: CGFloat = 80
    var height: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            guard let first = points.first, let last = points.last,
                  let maxValue = points.map(\.value).max(), maxValue > 0 else { return }
            let span = max(1, last.date.timeIntervalSince(first.date))
            let barWidth = max(1, min(6, size.width / CGFloat(max(1, points.count))))
            for point in points where point.value > 0 {
                let x = point.date.timeIntervalSince(first.date) / span * max(0, size.width - barWidth)
                let h = point.value / maxValue * size.height
                let rect = CGRect(x: x, y: size.height - h, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
        .frame(width: width, height: height)
        .accessibilityLabel("CPU or hardware energy trend; scaled within this row")
    }
}
