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
                .accessibilityIdentifier(AccessibilityIdentifiers.settingsLaunchAtLogin)
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
                    .accessibilityLabel("Open Login Items")
                    .accessibilityIdentifier(AccessibilityIdentifiers.settingsOpenLoginItems)
                }
            } else if let message = appState.loginItemFeedback {
                feedback(message, symbol: "info.circle")
            } else if appState.loginItemStatus == .notFound {
                feedback("Login item is unavailable for this app build.", symbol: "exclamationmark.triangle")
            }

            Divider()
            Picker("Raw detail retention", selection: Binding(
                get: { appState.rawRetentionDays }, set: { appState.setRawRetentionDays($0) }
            )) {
                ForEach([2, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
            }
            .pickerStyle(.menu)
            .disabled(appState.database == nil)
            .accessibilityLabel("Raw detail retention period")
            .accessibilityIdentifier(AccessibilityIdentifiers.settingsRawRetention)

            VStack(alignment: .leading, spacing: 4) {
                Text("Old database: \(appState.legacyImportStatus?.state.rawValue ?? "checking")")
                    .font(.caption)
                if let error = appState.legacyImportStatus?.error {
                    Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let progress = appState.legacyImportProgress {
                    ProgressView(value: Double(progress.importedHours), total: Double(max(progress.totalHours, 1)))
                    Text("\(progress.importedHours) of \(progress.totalHours) hours imported")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let deleteAfter = appState.legacyImportStatus?.deleteAfter {
                    Text("Automatic deletion after \(deleteAfter.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Delete old database now") { appState.deleteLegacyDatabaseNow() }
                        .controlSize(.small)
                        .disabled(appState.legacyImportStatus?.state != .done)
                        .accessibilityLabel("Delete old database now")
                        .accessibilityIdentifier(AccessibilityIdentifiers.settingsDeleteLegacyDatabase)
                }
            }
        }
        .padding(20)
        .onAppear { appState.refreshLoginItemStatus(); Task { await appState.refreshLegacyImportStatus() } }
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
