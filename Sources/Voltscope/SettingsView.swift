import SwiftUI
import AppKit
import VoltscopeCore

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { appState.loginItemStatus == .enabled },
            set: { appState.setLaunchAtLogin($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Launch at login", isOn: launchAtLogin)
                .toggleStyle(.switch)
                .disabled(!appState.canEnableLaunchAtLogin && appState.loginItemStatus != .enabled)
                .accessibilityLabel("Launch at login")
                .accessibilityHint("Starts Voltscope in the menu bar when you sign in.")

            Text("Start Voltscope in the menu bar when you sign in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.loginItemStatus == .requiresApproval {
                HStack(spacing: 8) {
                    Text("Allow Voltscope in Login Items to continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Open Login Items") {
                        appState.openLoginItems()
                    }
                    .controlSize(.small)
                }
            } else if let message = appState.loginItemFeedback {
                feedback(message, symbol: "info.circle")
            } else if appState.loginItemStatus == .notFound {
                feedback("Login item is unavailable for this app build.", symbol: "exclamationmark.triangle")
            }
        }
        .padding(20)
        .onAppear { appState.refreshLoginItemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshLoginItemStatus()
        }
        .accessibilityElement(children: .contain)
    }

    private func feedback(_ message: String, symbol: String) -> some View {
        Label(message, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(message)
    }
}

@MainActor
enum SettingsWindowPresenter {
    /// SwiftUI's Settings scene installs the standard App menu action. Using
    /// that action keeps this entry point available on macOS 13 without
    /// depending on newer `openSettings` environment APIs.
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}
