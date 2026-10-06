import Foundation

/// Chart series colors and the WCAG contrast math that validates them.
///
/// The History window renders the App CPU energy chart on a fixed neutral
/// background (`historyBackgrounds`, sampled from the shipped window in both
/// appearances). Every series color must stay at or above
/// `seriesMinimumContrast` against that background in both appearances, and
/// the battery chart's charging green must also clear
/// `standaloneTextMinimumContrast` because it marks the "Charging" caption.
///
/// App identity colors stay stable by bundle identity (see `HistoryColors` in
/// the app target): identity maps to a palette slot index, and only slots that
/// miss the contrast thresholds are overridden here with explicit light/dark
/// values. The hue-sequence fallback used for slots beyond the base palette is
/// compensated to keep only already-compliant colors unchanged.
public enum HistoryChartPalette {
    /// An explicit sRGB color for the light and dark appearance, 0xRRGGBB.
    public struct PaletteColor: Sendable, Equatable {
        public let light: UInt32
        public let dark: UInt32

        public init(light: UInt32, dark: UInt32) {
            self.light = light
            self.dark = dark
        }
    }

    /// History window chart background, sampled in both appearances during the
    /// 0.10.3 accessibility audit. Contrast is measured against these.
    public static let historyBackgrounds = PaletteColor(light: 0xF0F1F2, dark: 0x313334)

    public static let systemSeries = PaletteColor(light: 0x58585D, dark: 0xADADB3)
    public static let otherAppsSeries = PaletteColor(light: 0x7D7D7F, dark: 0x85858B)
    public static let chargingGreen = PaletteColor(light: 0x146C2C, dark: 0x32D74B)

    /// Minimum contrast for chart series, legend swatches, and trace marks.
    public static let seriesMinimumContrast: Double = 3.0
    /// Minimum contrast for colors also used as visible caption text.
    public static let standaloneTextMinimumContrast: Double = 4.5
    /// Minimum luminance separation between the two gray series so the chart
    /// does not rely on hue differences alone to tell them apart.
    public static let grayPairSeparation: Double = 1.5

    /// Explicit overrides for base-palette slots that miss
    /// `seriesMinimumContrast` on at least one appearance. The passing
    /// appearance keeps the measured system color so the bar rendering does
    /// not change where it already passed. Slots not listed here keep using
    /// the system semantic color.
    public static let appSlotOverrides: [Int: PaletteColor] = [
        1: PaletteColor(light: 0xC25C00, dark: 0xFF9F0A),
        3: PaletteColor(light: 0x2E7F92, dark: 0x6AC4DC),
        5: PaletteColor(light: 0x5856D6, dark: 0x7E7DF0),
        7: PaletteColor(light: 0x147D77, dark: 0x63E6E2),
    ]

    /// Hue-sequence fallback parameters for app slots beyond the base palette.
    public static let fallbackHueStep = 0.61803398875
    public static let fallbackRawSaturation = 0.7
    public static let fallbackRawBrightness = 0.85
    /// Luminance shared by compensated fallback colors: the band that keeps
    /// at least 3:1 against both chart backgrounds.
    static let compensatedTargetLuminance = 0.225

    /// sRGB hex for the app slot beyond the base palette. Colors that already
    /// meet `seriesMinimumContrast` on both appearances keep the exact raw
    /// hue-sequence color so existing app color assignments never shift.
    /// Others are compensated toward `compensatedTargetLuminance`, a
    /// luminance valid on both backgrounds: brightness is adjusted toward the
    /// band while the hue can still reach it, and saturation is reduced as a
    /// last resort for hues too dim to reach the band at full brightness.
    public static func fallbackHex(appIndex: Int) -> UInt32 {
        let hue = (Double(max(0, appIndex)) * fallbackHueStep).truncatingRemainder(dividingBy: 1)
        let raw = rgb(hue: hue, saturation: fallbackRawSaturation, brightness: fallbackRawBrightness)
        if contrastRatio(raw, against: historyBackgrounds.light) >= seriesMinimumContrast,
           contrastRatio(raw, against: historyBackgrounds.dark) >= seriesMinimumContrast {
            return raw
        }
        let rawLuminance = relativeLuminance(raw)
        let fullBrightnessLuminance = relativeLuminance(rgb(hue: hue, saturation: fallbackRawSaturation, brightness: 1))
        if rawLuminance > compensatedTargetLuminance {
            // Too bright against the light background: dim toward the band.
            var low = 0.0
            var high = fallbackRawBrightness
            var best = 0.0
            for _ in 0..<40 {
                let mid = (low + high) / 2
                let luminance = relativeLuminance(rgb(hue: hue, saturation: fallbackRawSaturation, brightness: mid))
                if luminance < compensatedTargetLuminance {
                    low = mid
                } else {
                    best = mid
                    high = mid
                }
            }
            return rgb(hue: hue, saturation: fallbackRawSaturation, brightness: best)
        }
        if fullBrightnessLuminance >= compensatedTargetLuminance {
            // Too dim against the dark background: brighten toward the band.
            var low = fallbackRawBrightness
            var high = 1.0
            var best = 1.0
            for _ in 0..<40 {
                let mid = (low + high) / 2
                let luminance = relativeLuminance(rgb(hue: hue, saturation: fallbackRawSaturation, brightness: mid))
                if luminance < compensatedTargetLuminance {
                    low = mid
                } else {
                    best = mid
                    high = mid
                }
            }
            return rgb(hue: hue, saturation: fallbackRawSaturation, brightness: best)
        }
        // The hue cannot reach the band by brightness alone: desaturate at
        // full brightness until the compensated luminance is met.
        var low = 0.0
        var high = fallbackRawSaturation
        var best = 0.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            let luminance = relativeLuminance(rgb(hue: hue, saturation: mid, brightness: 1))
            if luminance < compensatedTargetLuminance {
                high = mid
            } else {
                best = mid
                low = mid
            }
        }
        return rgb(hue: hue, saturation: best, brightness: 1)
    }

    /// WCAG 2.x relative luminance of an 0xRRGGBB sRGB color.
    public static func relativeLuminance(_ hex: UInt32) -> Double {
        luminance(rgb: hex)
    }

    /// WCAG 2.x contrast ratio between two 0xRRGGBB sRGB colors.
    public static func contrastRatio(_ a: UInt32, against b: UInt32) -> Double {
        let la = luminance(rgb: a)
        let lb = luminance(rgb: b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func channel(_ hex: UInt32, _ shift: UInt32) -> Double {
        Double((hex >> shift) & 0xFF) / 255
    }

    static func luminance(rgb hex: UInt32) -> Double {
        0.2126 * linear(channel(hex, 16)) + 0.7152 * linear(channel(hex, 8)) + 0.0722 * linear(channel(hex, 0))
    }

    static func linear(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Standard sRGB HSV to RGB conversion, matching `Color(hue:saturation:brightness:)`.
    static func rgb(hue: Double, saturation: Double, brightness: Double) -> UInt32 {
        let chroma = brightness * saturation
        let h6 = hue * 6
        let secondary = chroma * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - chroma
        let sector = Int(h6) % 6
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case 0: (r, g, b) = (chroma, secondary, 0)
        case 1: (r, g, b) = (secondary, chroma, 0)
        case 2: (r, g, b) = (0, chroma, secondary)
        case 3: (r, g, b) = (0, secondary, chroma)
        case 4: (r, g, b) = (secondary, 0, chroma)
        default: (r, g, b) = (chroma, 0, secondary)
        }
        func byte(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v + m) * 255)).rounded()) }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }
}
