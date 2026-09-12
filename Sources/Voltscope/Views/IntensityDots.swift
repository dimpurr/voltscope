import SwiftUI

/// A compact 1–3 dot intensity indicator
/// indicating relative energy intensity. We compute the bucket against
/// the visible top-N's max so the heaviest app gets 3 dots and the lightest
/// shown gets 1.
struct IntensityDots: View {
    /// 1-based count of filled dots out of `total`.
    let filled: Int
    var total: Int = 3

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < filled ? Color.red : Color.secondary.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel("Intensity \(filled) of \(total)")
    }

    /// Pure helper: bucket a value against a max into 1–3 dots.
    static func dotCount(value: Int64, max: Int64) -> Int {
        guard max > 0 else { return 1 }
        let ratio = Double(value) / Double(max)
        switch ratio {
        case 0.66...:    return 3
        case 0.33...:    return 2
        default:         return 1
        }
    }
}
