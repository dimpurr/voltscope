import XCTest
import AppKit
import SwiftUI
@testable import VoltscopeCore

final class HistoryChartPaletteTests: XCTestCase {
    private func contrast(_ hex: UInt32, against background: UInt32) -> Double {
        HistoryChartPalette.contrastRatio(hex, against: background)
    }

    func testContrastMathMatchesWCAGReferenceValues() {
        XCTAssertEqual(HistoryChartPalette.contrastRatio(0x000000, against: 0xFFFFFF), 21.0, accuracy: 0.01)
        XCTAssertEqual(HistoryChartPalette.contrastRatio(0xFFFFFF, against: 0x000000), 21.0, accuracy: 0.01)
        // Audit-sampled references from the 0.10.3 accessibility report.
        XCTAssertEqual(contrast(0x61C55D, against: 0xF0F1F2), 1.92, accuracy: 0.01)
        XCTAssertEqual(contrast(0x34C759, against: 0xF0F1F2), 1.96, accuracy: 0.01)
    }

    func testChartBackgroundsMatchAuditedWindowSamples() {
        XCTAssertEqual(HistoryChartPalette.historyBackgrounds.light, 0xF0F1F2)
        XCTAssertEqual(HistoryChartPalette.historyBackgrounds.dark, 0x313334)
    }

    func testSeriesColorsMeetContrastThresholdsOnBothAppearances() {
        let thresholds = HistoryChartPalette.seriesMinimumContrast
        let backgrounds = HistoryChartPalette.historyBackgrounds
        for name in ["systemSeries", "otherAppsSeries"] {
            let pair: HistoryChartPalette.PaletteColor = name == "systemSeries"
                ? HistoryChartPalette.systemSeries
                : HistoryChartPalette.otherAppsSeries
            XCTAssertGreaterThanOrEqual(
                contrast(pair.light, against: backgrounds.light), thresholds,
                "\(name) light \(String(format: "%06X", pair.light)) must reach 3:1 on the light background")
            XCTAssertGreaterThanOrEqual(
                contrast(pair.dark, against: backgrounds.dark), thresholds,
                "\(name) dark \(String(format: "%06X", pair.dark)) must reach 3:1 on the dark background")
        }
        for (slot, pair) in HistoryChartPalette.appSlotOverrides.sorted(by: { $0.key < $1.key }) {
            XCTAssertGreaterThanOrEqual(
                contrast(pair.light, against: backgrounds.light), thresholds,
                "app slot \(slot) light \(String(format: "%06X", pair.light)) must reach 3:1")
            XCTAssertGreaterThanOrEqual(
                contrast(pair.dark, against: backgrounds.dark), thresholds,
                "app slot \(slot) dark \(String(format: "%06X", pair.dark)) must reach 3:1")
        }
    }

    func testSeriesColorsMeetRenderedContrastThresholdsOnBothAppearances() {
        // The on-device audit samples an untagged wide-gamut screenshot, so the
        // palette must clear the rendered threshold, not only the sRGB floor.
        let threshold = HistoryChartPalette.renderedSeriesMinimumContrast
        let backgrounds = HistoryChartPalette.historyBackgrounds
        var pairs: [(String, UInt32, UInt32)] = [
            ("systemSeries", HistoryChartPalette.systemSeries.light, HistoryChartPalette.systemSeries.dark),
            ("otherAppsSeries", HistoryChartPalette.otherAppsSeries.light, HistoryChartPalette.otherAppsSeries.dark),
        ]
        for (slot, pair) in HistoryChartPalette.appSlotOverrides.sorted(by: { $0.key < $1.key }) {
            pairs.append(("app slot \(slot)", pair.light, pair.dark))
        }
        for (name, light, dark) in pairs {
            XCTAssertGreaterThanOrEqual(
                HistoryChartPalette.renderedContrastRatio(light, against: backgrounds.light), threshold,
                "\(name) light \(String(format: "%06X", light)) must reach \(threshold):1 when rendered")
            XCTAssertGreaterThanOrEqual(
                HistoryChartPalette.renderedContrastRatio(dark, against: backgrounds.dark), threshold,
                "\(name) dark \(String(format: "%06X", dark)) must reach \(threshold):1 when rendered")
        }
    }

    func testDisplayP3EncodingMatchesMeasuredSeriesColors() {
        // Real-device samples from the 0.10.3/W44 audit: the rendered bytes the
        // untagged screenshot reported for each sRGB palette color. Reproducing
        // them keeps the rendered-contrast checks aligned with the device.
        let samples: [(UInt32, UInt32, String)] = [
            (0xD941C1, 0xC84DBC, "Python"),
            (0x38952D, 0x53933D, "Claude Code"),
            (0xD9417E, 0xC84D7D, "Paste"),
            (0xC348F1, 0xB550E9, "CodexBar"),
            (0xADADB3, 0xACACB1, "System"),
            (0x85858B, 0x858589, "Other apps"),
        ]
        for (sRGB, measured, name) in samples {
            let encoded = HistoryChartPalette.displayP3Encoded(sRGB)
            for shift in [16, 8, 0] {
                let actual = Int((encoded >> UInt32(shift)) & 0xFF)
                let expected = Int((measured >> UInt32(shift)) & 0xFF)
                XCTAssertLessThanOrEqual(
                    abs(actual - expected), 2,
                    "\(name) channel \(shift): encoded \(String(format: "%06X", encoded)) vs measured \(String(format: "%06X", measured))")
            }
        }
    }

    func testChargingGreenMeetsTextContrastOnBothAppearances() {
        // The charging green also colors the visible "Charging" caption, so it
        // is held to the text threshold, not the graphics threshold.
        let green = HistoryChartPalette.chargingGreen
        let backgrounds = HistoryChartPalette.historyBackgrounds
        let threshold = HistoryChartPalette.standaloneTextMinimumContrast
        XCTAssertGreaterThanOrEqual(contrast(green.light, against: backgrounds.light), threshold,
                                    "Charging caption must reach 4.5:1 in the light appearance")
        XCTAssertGreaterThanOrEqual(contrast(green.dark, against: backgrounds.dark), threshold,
                                    "Charging caption must reach 4.5:1 in the dark appearance")
    }

    func testSystemAndOtherAppsGraysStayDistinguishableOnBothAppearances() {
        let separation = HistoryChartPalette.grayPairSeparation
        let system = HistoryChartPalette.systemSeries
        let other = HistoryChartPalette.otherAppsSeries
        XCTAssertGreaterThanOrEqual(
            HistoryChartPalette.contrastRatio(system.light, against: other.light), separation,
            "System and Other apps must stay separated in the light appearance")
        XCTAssertGreaterThanOrEqual(
            HistoryChartPalette.contrastRatio(system.dark, against: other.dark), separation,
            "System and Other apps must stay separated in the dark appearance")
    }

    func testAppSlotOverridesStayWithinTheBasePalette() {
        for slot in HistoryChartPalette.appSlotOverrides.keys {
            XCTAssertTrue((0..<8).contains(slot), "Override slot \(slot) must be a base palette slot")
        }
    }

    func testFallbackColorsMeetContrastThresholdsForBothAppearances() {
        let backgrounds = HistoryChartPalette.historyBackgrounds
        let threshold = HistoryChartPalette.seriesMinimumContrast
        for index in 8..<64 {
            let hex = HistoryChartPalette.fallbackHex(appIndex: index)
            XCTAssertGreaterThanOrEqual(
                contrast(hex, against: backgrounds.light), threshold,
                "fallback index \(index) \(String(format: "%06X", hex)) must reach 3:1 on the light background")
            XCTAssertGreaterThanOrEqual(
                contrast(hex, against: backgrounds.dark), threshold,
                "fallback index \(index) \(String(format: "%06X", hex)) must reach 3:1 on the dark background")
        }
    }

    func testFallbackColorsMeetRenderedContrastThresholdsForBothAppearances() {
        let backgrounds = HistoryChartPalette.historyBackgrounds
        let threshold = HistoryChartPalette.renderedSeriesMinimumContrast
        for index in 8..<64 {
            let hex = HistoryChartPalette.fallbackHex(appIndex: index)
            XCTAssertGreaterThanOrEqual(
                HistoryChartPalette.renderedContrastRatio(hex, against: backgrounds.light), threshold,
                "fallback index \(index) \(String(format: "%06X", hex)) must reach \(threshold):1 when rendered on light")
            XCTAssertGreaterThanOrEqual(
                HistoryChartPalette.renderedContrastRatio(hex, against: backgrounds.dark), threshold,
                "fallback index \(index) \(String(format: "%06X", hex)) must reach \(threshold):1 when rendered on dark")
        }
    }

    func testFallbackPreservesRawColorWhenAlreadyCompliant() {
        // Indices 13, 22, 24, and 58 measure compliant with the raw
        // hue-sequence parameters under the rendered threshold; their assigned
        // colors must not shift.
        for index in [13, 22, 24, 58] {
            let hue = (Double(index) * HistoryChartPalette.fallbackHueStep).truncatingRemainder(dividingBy: 1)
            let raw = HistoryChartPalette.rgb(hue: hue,
                                              saturation: HistoryChartPalette.fallbackRawSaturation,
                                              brightness: HistoryChartPalette.fallbackRawBrightness)
            XCTAssertEqual(HistoryChartPalette.fallbackHex(appIndex: index), raw,
                           "compliant fallback colors must stay bit-identical for index \(index)")
        }
    }

    func testFallbackRawConversionMatchesSwiftUIColor() {
        // The raw fall-back path renders through Color(hue:saturation:brightness:),
        // which is plain sRGB HSV; the Core conversion must agree byte for byte.
        let index = 22
        let hue = (Double(index) * HistoryChartPalette.fallbackHueStep).truncatingRemainder(dividingBy: 1)
        for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
            let previous = NSAppearance.current
            NSAppearance.current = appearance
            defer { NSAppearance.current = previous }
            let resolved = NSColor(Color(hue: hue, saturation: HistoryChartPalette.fallbackRawSaturation,
                                          brightness: HistoryChartPalette.fallbackRawBrightness))
                .usingColorSpace(.sRGB)!
            let core = HistoryChartPalette.fallbackHex(appIndex: index)
            XCTAssertEqual((resolved.redComponent * 255).rounded(.down), Double((core >> 16) & 0xFF), accuracy: 1)
            XCTAssertEqual((resolved.greenComponent * 255).rounded(.down), Double((core >> 8) & 0xFF), accuracy: 1)
            XCTAssertEqual((resolved.blueComponent * 255).rounded(.down), Double(core & 0xFF), accuracy: 1)
        }
    }

    func testUnoverriddenSystemPaletteSlotsMeetContrastOnBothAppearances() {
        // Slots without an override keep SwiftUI system colors; assert the
        // live values resolve above the series threshold in both appearances.
        let backgrounds = HistoryChartPalette.historyBackgrounds
        let threshold = HistoryChartPalette.seriesMinimumContrast
        let systemColors: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo, .brown, .mint]
        for (slot, color) in systemColors.enumerated() where HistoryChartPalette.appSlotOverrides[slot] == nil {
            for (appearance, background, kind) in [(NSAppearance(named: .aqua)!, backgrounds.light, "light"),
                                                   (NSAppearance(named: .darkAqua)!, backgrounds.dark, "dark")] {
                let previous = NSAppearance.current
                NSAppearance.current = appearance
                defer { NSAppearance.current = previous }
                let resolved = NSColor(color).usingColorSpace(.sRGB)!
                let hex: UInt32 = (UInt32((resolved.redComponent * 255).rounded()) << 16)
                    | (UInt32((resolved.greenComponent * 255).rounded()) << 8)
                    | UInt32((resolved.blueComponent * 255).rounded())
                XCTAssertGreaterThanOrEqual(contrast(hex, against: background), threshold,
                                            "system slot \(slot) \(kind) \(String(format: "%06X", hex)) must reach 3:1")
            }
        }
    }

    func testChartContainerLabelsMatchSpokenTitles() {
        XCTAssertEqual(AccessibilityLabels.batteryLevelChartLabel, "Battery level chart")
        XCTAssertEqual(AccessibilityLabels.appCPUEnergyChartLabel, "App CPU energy chart")
    }
}
