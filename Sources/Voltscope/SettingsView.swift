import SwiftUI
import AppKit
import VoltscopeCore

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirmation = false
    @State private var showingReplaceLinkConfirmation = false

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { appState.loginItemStatus == .enabled },
            set: { appState.setLaunchAtLogin($0) }
        )
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Launch at login", isOn: launchAtLogin)
                    .toggleStyle(.switch)
                    .disabled(!appState.canEnableLaunchAtLogin && appState.loginItemStatus != .enabled)
                    .accessibilityLabel("Launch at login")
                    .accessibilityIdentifier(AccessibilityIdentifiers.settingsLaunchAtLogin)
                    .accessibilityHint("Starts Voltscope in the menu bar when you sign in.")

                Text("Start Voltscope in the menu bar when you sign in.")
                    .font(.callout)
                    .foregroundStyle(Color.accessibleSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if appState.loginItemStatus == .requiresApproval {
                    HStack(spacing: 8) {
                        Text("Allow Voltscope in Login Items to continue.")
                            .font(.caption)
                            .foregroundStyle(Color.accessibleSecondary)
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
                    if let deletionError = appState.legacyDeletionError {
                        Text("Deletion failed: \(deletionError)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Old database deletion failed: \(deletionError)")
                    }
                    if let progress = appState.legacyImportProgress {
                        ProgressView(value: Double(progress.importedHours), total: Double(max(progress.totalHours, 1)))
                            .accessibilityLabel("Database import progress")
                            .accessibilityValue("\(progress.importedHours) of \(progress.totalHours) hours imported")
                        Text("\(progress.importedHours) of \(progress.totalHours) hours imported")
                            .font(.caption2).foregroundStyle(Color.accessibleSecondary)
                    }
                    if let deleteAfter = appState.legacyImportStatus?.deleteAfter {
                        Text("Automatic deletion after \(deleteAfter.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(Color.accessibleSecondary)
                    }
                    HStack {
                        Spacer()
                        Button {
                            showingDeleteConfirmation = true
                        } label: {
                            Text("Delete old database now")
                                .frame(minHeight: HitTarget.minimumSide)
                                .contentShape(Rectangle())
                        }
                        .controlSize(.small)
                        .disabled(appState.legacyImportStatus?.state != .done)
                        .accessibilityLabel("Delete old database now")
                        .accessibilityIdentifier(AccessibilityIdentifiers.settingsDeleteLegacyDatabase)
                        .confirmationDialog(
                            "Delete old database?",
                            isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Delete Old Database", role: .destructive) {
                                appState.deleteLegacyDatabaseNow()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will permanently remove the migrated database files from disk. This action cannot be undone.")
                        }
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command line tool")
                        .font(.callout)
                        .fontWeight(.medium)
                    Text(commandLineToolStatusLine)
                        .font(.caption)
                        .foregroundStyle(Color.accessibleSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if case .pointsToHelper = appState.commandLineToolStatus.state,
                       !appState.commandLineToolStatus.onPath {
                        Text("If your terminal does not find \(CommandLineToolLink.toolName), add this line to your shell profile:")
                            .font(.caption)
                            .foregroundStyle(Color.accessibleSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(appState.commandLineTool.pathExportLine)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let message = appState.commandLineToolFeedback {
                        feedback(
                            message.message,
                            symbol: message.isProblem ? "exclamationmark.triangle" : "checkmark.circle"
                        )
                    }

                    HStack(spacing: 8) {
                        Spacer()
                        Button {
                            if case .pointsElsewhere = appState.commandLineToolStatus.state {
                                showingReplaceLinkConfirmation = true
                            } else {
                                appState.installCommandLineTool()
                            }
                        } label: {
                            Text("Install Command Line Tool")
                                .frame(minHeight: HitTarget.minimumSide)
                                .contentShape(Rectangle())
                        }
                        .disabled(!appState.canInstallCommandLineTool)
                        .accessibilityLabel("Install Command Line Tool")
                        .accessibilityIdentifier(AccessibilityIdentifiers.settingsInstallCommandLineTool)
                        .accessibilityHint(
                            "Creates a link at \(appState.commandLineTool.linkDisplayPath) that runs the tool inside this copy of Voltscope."
                        )
                        .confirmationDialog(
                            "Replace the existing link?",
                            isPresented: $showingReplaceLinkConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Replace Link", role: .destructive) {
                                appState.installCommandLineTool(overwriteExisting: true)
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(
                                "There is already a link at \(appState.commandLineTool.linkDisplayPath) pointing somewhere else. "
                                    + "Voltscope will replace that link and leave the command it points at alone."
                            )
                        }

                        Button {
                            appState.uninstallCommandLineTool()
                        } label: {
                            Text("Uninstall")
                                .frame(minHeight: HitTarget.minimumSide)
                                .contentShape(Rectangle())
                        }
                        .disabled(!appState.canUninstallCommandLineTool)
                        .accessibilityLabel("Uninstall command line tool")
                        .accessibilityIdentifier(AccessibilityIdentifiers.settingsUninstallCommandLineTool)
                        .accessibilityHint(
                            "Removes the link at \(appState.commandLineTool.linkDisplayPath). Voltscope keeps the tool inside its own bundle."
                        )
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            appState.refreshLoginItemStatus()
            appState.refreshCommandLineToolStatus()
            Task { await appState.refreshLegacyImportStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshLoginItemStatus()
            appState.refreshCommandLineToolStatus()
        }
        .onExitCommand { dismiss() }
        .accessibilityElement(children: .contain)
    }

    /// One sentence about the link, in the voice of the state the tool is in.
    private var commandLineToolStatusLine: String {
        let tool = appState.commandLineTool
        let status = appState.commandLineToolStatus
        switch status.state {
        case .absent:
            return status.linkDirectoryExists
                ? "Not installed. Installing puts a link at \(tool.linkDisplayPath)."
                : "Not installed. Installing creates \(tool.linkDirectoryDisplayPath) and puts the link there."
        case .pointsToHelper:
            return "Installed. \(tool.linkDisplayPath) runs the tool inside this copy of Voltscope."
        case .pointsElsewhere(let destination):
            return "\(tool.linkDisplayPath) is a link to "
                + "\(CommandLineToolLink.displayPath(of: URL(fileURLWithPath: destination)))."
        case .occupiedByOtherItem:
            return "\(tool.linkDisplayPath) already exists and is not a link. Move it out of the way to install."
        case .helperUnavailable:
            return "This copy of Voltscope has no command line tool inside it."
        }
    }

    private func feedback(_ message: String, symbol: String) -> some View {
        Label(message, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(Color.accessibleSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(message)
    }
}
