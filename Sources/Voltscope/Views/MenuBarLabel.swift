import SwiftUI
import VoltscopeCore

struct MenuBarLabel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .accessibilityHidden(true)
            Text(displayString)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voltscope")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(AccessibilityIdentifiers.menuBarItem)
    }

    /// The glyph now carries the power state: a bolt while charging, a plug while
    /// connected but not charging, and a battery while charged or on battery. It
    /// used to be a permanent bolt, which said nothing when the state changed.
    private var symbolName: String {
        appState.displayedChargeState?.symbolName ?? "bolt.slash"
    }

    private var accessibilityValue: String {
        AccessibilityLabels.menuBarBatteryValue(
            levelPercent: appState.displayedBattery?.levelPercent,
            chargeState: appState.displayedChargeState
        )
    }

    private var displayString: String {
        if let level = appState.displayedBattery?.levelPercent {
            return "\(Int(level.rounded()))%"
        }
        return "—"
    }
}
