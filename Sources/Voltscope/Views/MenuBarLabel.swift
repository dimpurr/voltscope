import SwiftUI
import VoltscopeCore

struct MenuBarLabel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
            Text(displayString)
        }
    }

    private var displayString: String {
        if let level = appState.lastBattery?.levelPercent {
            return "\(Int(level.rounded()))%"
        }
        return "—"
    }
}
