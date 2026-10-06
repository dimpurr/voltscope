import AppKit
import SwiftUI
import VoltscopeCore

extension Color {
    /// Secondary text that keeps its meaning in both appearances.
    ///
    /// Used for panel captions and Settings explanations and warnings, where the
    /// system `.secondary` style measures 4.32:1 on the light panel background
    /// and `.tertiary` measures 1.90:1. The values come from
    /// `AccessibilityPalette` and clear `ContrastRatio.bodyTextMinimum`
    /// against the panel and window backgrounds in both appearances.
    static let accessibleSecondary = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return AppearanceColor.nsColor(AccessibilityPalette.secondaryText(dark: isDark))
    })
}

private enum AppearanceColor {
    static func nsColor(_ color: SRGBColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}
