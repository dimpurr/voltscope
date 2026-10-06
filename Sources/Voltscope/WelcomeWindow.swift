import AppKit
import SwiftUI
import VoltscopeCore

@MainActor
final class VoltscopeAppDelegate: NSObject, NSApplicationDelegate {
    private weak var appState: AppState?
    private let welcomeController = WelcomeWindowController()
    private var didFinishLaunching = false

    func configure(_ appState: AppState) {
        self.appState = appState
        if didFinishLaunching {
            DispatchQueue.main.async { [weak self] in
                self?.presentWelcomeIfNeeded()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        // Sampling starts in AppState's task independently. Welcome is only
        // a first-run surface and must not wait for the first sample.
        DispatchQueue.main.async { [weak self] in
            self?.presentWelcomeIfNeeded()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState?.refreshLoginItemStatus()
        welcomeController.restoreAfterExternalSettings()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        Task { @MainActor in
            let stopped = await appState.stopSamplingForTermination()
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }

    private func presentWelcomeIfNeeded() {
        guard let appState else { return }
        appState.refreshLoginItemStatus()
        let decision = LoginItemPolicy.onboardingDecision(
            onboardingHandled: appState.hasHandledLoginOnboarding,
            status: appState.loginItemStatus
        )
        guard decision == .showWelcome else { return }
        welcomeController.present(appState: appState)
    }
}

@MainActor
private final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private weak var appState: AppState?
    private var window: NSWindow?
    private var isWaitingForLoginItems = false

    func present(appState: AppState) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        self.appState = appState
        let content = WelcomeWindow(
            onOpenLoginItems: { [weak self] in
                self?.openLoginItems()
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        .environmentObject(appState)
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("welcome")
        window.title = AccessibilityLabels.welcomeWindowTitle
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 440, height: 286))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        isWaitingForLoginItems = false
        window?.close()
    }

    func openLoginItems() {
        isWaitingForLoginItems = true
        // Keep the first-run context visible while System Settings is in front.
        // It is restored to a normal window when the user returns to Voltscope.
        window?.level = .floating
        window?.orderFrontRegardless()
        appState?.openLoginItems()
    }

    func restoreAfterExternalSettings() {
        guard isWaitingForLoginItems, let window else { return }
        appState?.refreshLoginItemStatus()
        isWaitingForLoginItems = false
        window.level = .normal
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        appState?.completeLoginOnboarding()
        isWaitingForLoginItems = false
        window = nil
    }
}

private struct WelcomeWindow: View {
    @EnvironmentObject private var appState: AppState
    let onOpenLoginItems: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(AccessibilityLabels.welcomeHeading)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Voltscope records energy only while it is running. Enable Launch at login to keep your history continuous. You can change this later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appState.loginItemStatus == .enabled {
                Label("Voltscope will start automatically when you sign in.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if appState.loginItemStatus == .requiresApproval {
                Text("Voltscope needs your approval in Login Items before it can start at login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let feedback = appState.loginItemFeedback,
                      appState.loginItemStatus != .enabled {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    finish()
                } label: {
                    Text("Not Now")
                        .frame(minHeight: HitTarget.minimumSide)
                        .contentShape(Rectangle())
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Not Now")
                .accessibilityIdentifier(AccessibilityIdentifiers.welcomeNotNow)

                Spacer()

                if appState.loginItemStatus == .enabled {
                    Button {
                        finish()
                    } label: {
                        Text("Done")
                            .frame(minHeight: HitTarget.minimumSide)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Done")
                    .accessibilityIdentifier(AccessibilityIdentifiers.welcomeDone)
                } else if appState.loginItemStatus == .requiresApproval {
                    Button {
                        onOpenLoginItems()
                    } label: {
                        Text("Open Login Items")
                            .frame(minHeight: HitTarget.minimumSide)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Open Login Items")
                    .accessibilityIdentifier(AccessibilityIdentifiers.welcomeOpenLoginItems)
                } else {
                    Button {
                        appState.setLaunchAtLogin(true)
                        if appState.loginItemStatus == .enabled { finish() }
                    } label: {
                        Text("Enable at Login")
                            .frame(minHeight: HitTarget.minimumSide)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.canEnableLaunchAtLogin)
                    .accessibilityLabel("Enable at Login")
                    .accessibilityIdentifier(AccessibilityIdentifiers.welcomeEnableAtLogin)
                }
            }
        }
        .padding(24)
        .frame(width: 440, height: 286, alignment: .topLeading)
        .onExitCommand { finish() }
    }

    private func finish() {
        appState.completeLoginOnboarding()
        onClose()
    }
}
