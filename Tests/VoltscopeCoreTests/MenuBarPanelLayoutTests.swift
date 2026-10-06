import XCTest
@testable import VoltscopeCore

/// Guards the menu bar panel's vertical budget.
///
/// `R-01` was a regression where the panel kept a fixed 428 pt height while the
/// app rows grew, so the footer — including the `vX.Y.Z` version label — fell
/// outside the window. These tests lock the measured block heights and the
/// total so the budget cannot silently shrink below the content again. The
/// SwiftUI wiring that applies ``MenuBarPanelLayout/maximumCollapsedHeight`` is
/// not covered here; it is verified on a real Mac.
final class MenuBarPanelLayoutTests: XCTestCase {
    func testCollapsedPanelHeightIsTheSumOfItsMeasuredBlocks() {
        // Hand-computed from the real panel at 340 pt:
        //   padding 2x14 + charge 59 + health 60 + caption 13 + system 16
        //   + Intel notice 19 + 3 dividers + footer 64
        //   + 6 block gaps x12 + one caption-to-row gap x6
        //   + 5 app rows x(24 + 6)
        let measuredBlocks: CGFloat = 59 + 60 + 13 + 16 + 19 + 3 + 64
        let gaps: CGFloat = 72 + 6
        let rows: CGFloat = 5 * 30
        let expected = 28 + measuredBlocks + gaps + rows
        XCTAssertEqual(expected, 490, accuracy: 0.001)
        XCTAssertEqual(
            MenuBarPanelLayout.maximumCollapsedHeight,
            expected,
            accuracy: 0.001,
            "the panel must fit five app rows, the System row, and the footer with the version label"
        )
    }

    func testCollapsedPanelIsTallerThanThePreFixFixedHeight() {
        // Regression guard: 428 pt clipped the footer once the app rows grew.
        XCTAssertGreaterThan(
            MenuBarPanelLayout.maximumCollapsedHeight,
            428,
            "the panel must be taller than the pre-fix 428 pt that clipped the footer"
        )
    }

    func testPanelHeightGrowsByOneRowStepPerAppRow() {
        XCTAssertEqual(MenuBarPanelLayout.appRowStep, MenuBarPanelLayout.appRowHeight + MenuBarPanelLayout.appRowSpacing, accuracy: 0.001)
        XCTAssertEqual(MenuBarPanelLayout.appRowHeight, HitTarget.minimumSide)
        for rows in 0..<MenuBarPanelLayout.maximumAppRows {
            let step = MenuBarPanelLayout.requiredHeight(appRowCount: rows + 1)
                - MenuBarPanelLayout.requiredHeight(appRowCount: rows)
            XCTAssertEqual(step, MenuBarPanelLayout.appRowStep, accuracy: 0.001)
        }
    }

    func testRequiredHeightIsClampedToTheRowCap() {
        XCTAssertEqual(
            MenuBarPanelLayout.requiredHeight(appRowCount: 99),
            MenuBarPanelLayout.maximumCollapsedHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MenuBarPanelLayout.requiredHeight(appRowCount: -3),
            MenuBarPanelLayout.chromeHeight,
            accuracy: 0.001
        )
    }
}
