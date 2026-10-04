import SwiftUI
import VoltscopeCore

struct MenuBarLabel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
            Text(displayString)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voltscope")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(AccessibilityIdentifiers.menuBarItem)
    }

    private var accessibilityValue: String {
        let battery = appState.lastBattery
        return AccessibilityLabels.menuBarBatteryValue(
            levelPercent: battery?.levelPercent,
            isCharging: battery?.isCharging ?? false,
            isACPlugged: battery?.isACPlugged ?? false
        )
    }

    private var displayString: String {
        if let level = appState.lastBattery?.levelPercent {
            return "\(Int(level.rounded()))%"
        }
        return "—"
    }
}
