import SwiftUI

/// Two-tone progress bar for current capacity versus estimated degradation:
/// the green segment is the *current* capacity ratio, the orange segment is the
/// *lost* capacity from degradation. Together they always span the full width.
struct HealthBar: View {
    /// Ratio of current full-charge capacity vs design capacity, in [0, 1].
    let healthRatio: Double

    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.orange.opacity(0.85))
                Capsule()
                    .fill(Color.green)
                    .frame(width: geo.size.width * clamped)
            }
        }
        .frame(height: height)
        .accessibilityLabel("Battery health \(Int(clamped * 100)) percent")
    }

    private var clamped: Double {
        max(0, min(1, healthRatio))
    }
}
