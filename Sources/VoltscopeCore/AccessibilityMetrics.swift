import Foundation

/// Minimum interactive size for Voltscope controls.
///
/// WCAG 2.2 Success Criterion 2.5.8 (Target Size, Minimum) sets a 24 pt floor
/// and the macOS HIG asks for 28 pt at standard spacing. Compact controls — the
/// panel footer, inline row actions, first-run buttons — apply this floor so
/// they keep their dense layout while staying operable.
public enum HitTarget {
    public static let minimumSide: CGFloat = 24
}

/// An sRGB color with components in `0...1`, used for contrast math.
public struct SRGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Builds a color from a `0xRRGGBB` literal such as `SRGBColor(hex: 0xECECEC)`.
    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// WCAG 2.1 relative luminance and contrast ratio, so text colors are verified
/// by calculation instead of by eye.
public enum ContrastRatio {
    /// WCAG 2.1 AA for body text.
    public static let bodyTextMinimum: Double = 4.5

    /// WCAG 2.1 AA for large text (24 px, or 18.66 px bold) and for meaningful
    /// graphics such as icons and chart series.
    public static let largeTextAndGraphicsMinimum: Double = 3.0

    public static func relativeLuminance(_ color: SRGBColor) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red)
            + 0.7152 * channel(color.green)
            + 0.0722 * channel(color.blue)
    }

    /// Contrast ratio between two opaque colors, from 1 (identical) to 21
    /// (black on white).
    public static func ratio(foreground: SRGBColor, background: SRGBColor) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }
}

/// Text colors Voltscope draws itself.
///
/// The system `.secondary` and `.tertiary` styles carry meaning but measure
/// 4.32:1 and 1.90:1 against the light panel background, below the 4.5:1 floor
/// for body text. These values clear that floor on the panel and window
/// backgrounds of both appearances; `ContrastRatio` proves it in tests.
public enum AccessibilityPalette {
    public static let secondaryTextLight = SRGBColor(hex: 0x626262)
    public static let secondaryTextDark = SRGBColor(hex: 0xA5A5A6)

    public static func secondaryText(dark: Bool) -> SRGBColor {
        dark ? secondaryTextDark : secondaryTextLight
    }
}
