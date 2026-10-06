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
///
/// On a wide-gamut display macOS stores each sRGB color as its Display P3
/// encoding, and an untagged screenshot (the accessibility audit's capture)
/// reads those bytes back as sRGB. That shifts saturated colors and lowers the
/// measured contrast by up to ~0.15, so the palette holds the *rendered*
/// contrast (`renderedContrastRatio`) at `renderedSeriesMinimumContrast`
/// instead of only clearing the 3:1 sRGB floor.
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
    /// Minimum contrast the series colors must keep after the display pipeline
    /// is applied (see `renderedContrastRatio`). It is deliberately above the
    /// 3:1 floor so the on-device measurement keeps a margin.
    public static let renderedSeriesMinimumContrast: Double = 3.2
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

    /// sRGB hex for the app slot beyond the base palette. Colors that already
    /// clear `renderedSeriesMinimumContrast` on both appearances keep the exact
    /// raw hue-sequence color so existing app color assignments never shift.
    /// Others are placed at the midpoint brightness whose rendered contrast
    /// clears the threshold on both backgrounds; saturation is reduced as a
    /// last resort for hues that cannot reach the shared band at full
    /// saturation.
    public static func fallbackHex(appIndex: Int) -> UInt32 {
        let hue = (Double(max(0, appIndex)) * fallbackHueStep).truncatingRemainder(dividingBy: 1)
        let raw = rgb(hue: hue, saturation: fallbackRawSaturation, brightness: fallbackRawBrightness)
        if meetsRenderedMinimum(raw) { return raw }
        var saturation = fallbackRawSaturation
        while saturation > 0 {
            if let brightness = renderedBandBrightness(hue: hue, saturation: saturation) {
                return rgb(hue: hue, saturation: saturation, brightness: brightness)
            }
            saturation -= 0.05
        }
        let grayBrightness = renderedBandBrightness(hue: hue, saturation: 0) ?? 0.5
        return rgb(hue: hue, saturation: 0, brightness: grayBrightness)
    }

    static func meetsRenderedMinimum(_ hex: UInt32) -> Bool {
        renderedContrastRatio(hex, against: historyBackgrounds.light) >= renderedSeriesMinimumContrast
            && renderedContrastRatio(hex, against: historyBackgrounds.dark) >= renderedSeriesMinimumContrast
    }

    /// Midpoint brightness whose rendered contrast clears
    /// `renderedSeriesMinimumContrast` on both backgrounds, or nil when this
    /// hue and saturation cannot reach the shared band.
    static func renderedBandBrightness(hue: Double, saturation: Double) -> Double? {
        let darkEdge = renderedBrightness(hue: hue, saturation: saturation,
                                          against: historyBackgrounds.dark, risesWithBrightness: true)
        let lightEdge = renderedBrightness(hue: hue, saturation: saturation,
                                           against: historyBackgrounds.light, risesWithBrightness: false)
        guard darkEdge <= lightEdge else { return nil }
        return (darkEdge + lightEdge) / 2
    }

    /// Brightness at which `rgb(hue:saturation:brightness:)` first meets the
    /// threshold against `background`. Contrast rises with brightness on the
    /// dark background and falls on the light one.
    static func renderedBrightness(hue: Double, saturation: Double,
                                   against background: UInt32, risesWithBrightness: Bool) -> Double {
        var low = 0.0
        var high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            let contrast = renderedContrastRatio(rgb(hue: hue, saturation: saturation, brightness: mid),
                                                 against: background)
            if (contrast < renderedSeriesMinimumContrast) == risesWithBrightness {
                low = mid
            } else {
                high = mid
            }
        }
        return risesWithBrightness ? high : low
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

    /// The Display P3 encoding of an sRGB color, i.e. the bytes a wide-gamut
    /// screenshot stores for it. macOS renders the sRGB series colors in the
    /// display's P3 primaries; a screenshot with no embedded color profile is
    /// then read back as sRGB, so this is what a naive sampler measures.
    public static func displayP3Encoded(_ hex: UInt32) -> UInt32 {
        let linearRGB = [linear(channel(hex, 16)), linear(channel(hex, 8)), linear(channel(hex, 0))]
        let p3 = srgbToDisplayP3.map { row in
            row[0] * linearRGB[0] + row[1] * linearRGB[1] + row[2] * linearRGB[2]
        }
        func byte(_ value: Double) -> UInt32 { UInt32(max(0, min(255, (encode(value) * 255).rounded()))) }
        return (byte(p3[0]) << 16) | (byte(p3[1]) << 8) | byte(p3[2])
    }

    /// Contrast ratio as measured from an untagged wide-gamut screenshot: both
    /// colors are converted to their Display P3 encoding first.
    public static func renderedContrastRatio(_ a: UInt32, against b: UInt32) -> Double {
        contrastRatio(displayP3Encoded(a), against: displayP3Encoded(b))
    }

    /// sRGB to Display P3 (both D65) in linear light.
    static let srgbToDisplayP3: [[Double]] = [
        [0.822461969, 0.177538031, 0.0],
        [0.033194199, 0.966805801, 0.0],
        [0.017082631, 0.072397441, 0.910519928],
    ]

    static func channel(_ hex: UInt32, _ shift: UInt32) -> Double {
        Double((hex >> shift) & 0xFF) / 255
    }

    static func luminance(rgb hex: UInt32) -> Double {
        0.2126 * linear(channel(hex, 16)) + 0.7152 * linear(channel(hex, 8)) + 0.0722 * linear(channel(hex, 0))
    }

    static func linear(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encode(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
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
