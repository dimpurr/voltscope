import XCTest
@testable import VoltscopeCore

final class AccessibilityContrastTests: XCTestCase {
    // Backgrounds sampled from W39 screenshots of 0.10.3
    // (evidence/panel-0.10.3-{dark,light}.png, settings-0.10.3-{dark,light}.png)
    // plus the increase-contrast panel background reported in the same audit.
    private let panelBackgroundDark = SRGBColor(hex: 0x2A2A2B)
    private let panelBackgroundLight = SRGBColor(hex: 0xECECEC)
    private let windowBackgroundDark = SRGBColor(hex: 0x313334)
    private let windowBackgroundLight = SRGBColor(hex: 0xF0F1F2)
    private let panelBackgroundDarkIncreasedContrast = SRGBColor(hex: 0x0A0A0A)

    func testHitTargetMinimumMeetsWCAGTargetSizeFloor() {
        XCTAssertEqual(HitTarget.minimumSide, 24)
        XCTAssertGreaterThanOrEqual(HitTarget.minimumSide, 24)
    }

    func testContrastRatioMatchesWCAGReferenceValues() {
        XCTAssertEqual(
            ContrastRatio.ratio(foreground: SRGBColor(hex: 0x000000), background: SRGBColor(hex: 0xFFFFFF)),
            21,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ContrastRatio.ratio(foreground: SRGBColor(hex: 0xFFFFFF), background: SRGBColor(hex: 0xFFFFFF)),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ContrastRatio.relativeLuminance(SRGBColor(hex: 0xFFFFFF)),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ContrastRatio.relativeLuminance(SRGBColor(hex: 0x000000)),
            0,
            accuracy: 0.001
        )
    }

    func testContrastRatioReproducesMeasuredSystemHierarchyColors() {
        // The same color pairs W39 measured on screen: `.tertiary` and
        // `.secondary` labels on the panel, and the panel heading.
        let cases: [(foreground: SRGBColor, background: SRGBColor, measured: Double)] = [
            (SRGBColor(hex: 0x6A6A6B), panelBackgroundDark, 2.65),
            (SRGBColor(hex: 0xADADAD), panelBackgroundLight, 1.90),
            (SRGBColor(hex: 0xA5A5A6), panelBackgroundDark, 5.83),
            (SRGBColor(hex: 0x6E6E6E), panelBackgroundLight, 4.32),
            (SRGBColor(hex: 0xE8E8E8), panelBackgroundDark, 11.70),
            (SRGBColor(hex: 0x474747), panelBackgroundLight, 7.86),
            (SRGBColor(hex: 0x797A7A), windowBackgroundLight, 3.81)
        ]

        for testCase in cases {
            XCTAssertEqual(
                ContrastRatio.ratio(foreground: testCase.foreground, background: testCase.background),
                testCase.measured,
                accuracy: 0.02,
                "\(testCase.foreground) on \(testCase.background) should reproduce the audited ratio"
            )
        }
    }

    func testSecondaryTextClearsBodyTextMinimumOnEverySurface() {
        let surfaces: [(name: String, dark: Bool, background: SRGBColor)] = [
            ("panel light", false, panelBackgroundLight),
            ("window light", false, windowBackgroundLight),
            ("panel dark", true, panelBackgroundDark),
            ("window dark", true, windowBackgroundDark),
            ("panel dark increase contrast", true, panelBackgroundDarkIncreasedContrast)
        ]

        for surface in surfaces {
            let ratio = ContrastRatio.ratio(
                foreground: AccessibilityPalette.secondaryText(dark: surface.dark),
                background: surface.background
            )
            XCTAssertGreaterThanOrEqual(
                ratio,
                ContrastRatio.bodyTextMinimum,
                "secondary text on \(surface.name) is \(ratio):1"
            )
        }
    }

    func testSecondaryTextKeepsTheHierarchyBelowPrimaryText() {
        let lightPrimary = SRGBColor(hex: 0x474747)
        let darkPrimary = SRGBColor(hex: 0xE8E8E8)

        XCTAssertLessThan(
            ContrastRatio.ratio(foreground: AccessibilityPalette.secondaryTextLight, background: panelBackgroundLight),
            ContrastRatio.ratio(foreground: lightPrimary, background: panelBackgroundLight)
        )
        XCTAssertLessThan(
            ContrastRatio.ratio(foreground: AccessibilityPalette.secondaryTextDark, background: panelBackgroundDark),
            ContrastRatio.ratio(foreground: darkPrimary, background: panelBackgroundDark)
        )
    }

    func testSecondaryTextIsMoreVisibleThanTheTertiaryStyleItReplaces() {
        // `.tertiary` measured 2.65:1 dark and 1.90:1 light in the panel.
        XCTAssertGreaterThan(
            ContrastRatio.ratio(foreground: AccessibilityPalette.secondaryTextDark, background: panelBackgroundDark),
            2.65
        )
        XCTAssertGreaterThan(
            ContrastRatio.ratio(foreground: AccessibilityPalette.secondaryTextLight, background: panelBackgroundLight),
            4.32
        )
    }

    func testSecondaryTextSelectionIsStable() {
        XCTAssertEqual(AccessibilityPalette.secondaryTextLight, SRGBColor(hex: 0x626262))
        XCTAssertEqual(AccessibilityPalette.secondaryTextDark, SRGBColor(hex: 0xA5A5A6))
        XCTAssertFalse(AccessibilityPalette.secondaryText(dark: true) == AccessibilityPalette.secondaryText(dark: false))
    }
}
