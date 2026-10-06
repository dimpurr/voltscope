import Foundation

/// Vertical layout budget for the menu bar dropdown.
///
/// The panel is a `MenuBarExtra` window whose size is fixed at first display, so
/// the content that must always be visible — the app rows, the System row, and
/// the footer with the `Settings` / `Check for Updates vX.Y.Z` / `Quit` row —
/// has to fit inside a height that is known before the first sample arrives.
/// These constants are measured from the real panel at ``width`` and sum to
/// ``maximumCollapsedHeight``; the view applies that as its minimum height so
/// the footer can never be clipped again when the rows grow.
///
/// The pre-fix panel hard-coded a 428 pt minimum. Enlarging the app rows to a
/// 24 pt target pushed the content past 428 pt and the footer fell outside the
/// window; `MenuBarPanelLayoutTests` guards the budget from regressing.
public enum MenuBarPanelLayout {
    /// Fixed content width of the dropdown.
    public static let width: CGFloat = 340

    /// Padding around the panel content.
    public static let outerPadding: CGFloat = 14

    /// Vertical spacing between the major panel blocks (header, health, apps,
    /// footer).
    public static let blockSpacing: CGFloat = 12

    /// Vertical spacing between rows in the top-apps list.
    public static let appRowSpacing: CGFloat = 6

    /// Minimum height of one app row, shared with the 24 pt target floor.
    public static let appRowHeight: CGFloat = HitTarget.minimumSide

    /// The panel lists at most five user apps plus one System row.
    public static let maximumAppRows = 5

    /// Number of `blockSpacing` gaps: five inside the content stack plus the gap
    /// before the footer.
    public static let panelBlockGaps: CGFloat = 6

    // MARK: Fixed chrome, measured from the real panel at `width`

    /// Charge state, percentage, progress bar, and the time/status captions.
    public static let chargeHeaderHeight: CGFloat = 59
    /// Health label, bar, and the cycles/condition/temperature metrics.
    public static let healthSectionHeight: CGFloat = 60
    /// The "Top energy use / Top CPU time" caption above the app rows.
    public static let topAppsCaptionHeight: CGFloat = 13
    /// The collapsible `System` summary row.
    public static let systemRowHeight: CGFloat = 16
    /// The one-line caption shown when per-process energy is unavailable
    /// (Intel Macs), reserved so the budget also covers that configuration.
    public static let degradedNoticeHeight: CGFloat = 19
    /// The three section dividers.
    public static let dividerCount = 3
    public static let dividerHeight: CGFloat = 1
    /// The full-width `Open History` button plus the `Settings` /
    /// `Check for Updates vX.Y.Z` / `Quit` row.
    public static let footerHeight: CGFloat = 64

    /// Height of everything that is not an app row.
    public static var chromeHeight: CGFloat {
        outerPadding * 2
            + chargeHeaderHeight
            + healthSectionHeight
            + topAppsCaptionHeight
            + systemRowHeight
            + degradedNoticeHeight
            + CGFloat(dividerCount) * dividerHeight
            + footerHeight
            + blockSpacing * panelBlockGaps
            + appRowSpacing
    }

    /// Height of one app row plus the spacing below it.
    public static var appRowStep: CGFloat { appRowHeight + appRowSpacing }

    /// Panel height required to show `appRowCount` app rows plus the fixed
    /// chrome, clamped to the rows the panel can display.
    public static func requiredHeight(appRowCount: Int) -> CGFloat {
        let rows = min(max(appRowCount, 0), maximumAppRows)
        return chromeHeight + CGFloat(rows) * appRowStep
    }

    /// Height of the panel with the largest collapsed content it can show.
    public static var maximumCollapsedHeight: CGFloat {
        requiredHeight(appRowCount: maximumAppRows)
    }
}
