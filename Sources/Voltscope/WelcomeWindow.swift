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

    func present(appState: AppState) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        self.appState = appState
        let content = WelcomeWindow { [weak self] in
            self?.close()
        }
        .environmentObject(appState)
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("welcome")
        window.title = "Welcome to Voltscope"
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
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        appState?.completeLoginOnboarding()
        window = nil
    }
}

private struct WelcomeWindow: View {
    @EnvironmentObject private var appState: AppState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Voltscope")
                    .font(.title2.weight(.semibold))
                Text("Keep your energy history complete")
                    .font(.headline)
                Text("Voltscope records energy only while it is running. Enable Launch at login to keep your history continuous. You can change this later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appState.loginItemStatus == .requiresApproval {
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
                Button("Not Now") {
                    finish()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Not Now")

                Spacer()

                if appState.loginItemStatus == .requiresApproval {
                    Button("Open Login Items") {
                        appState.openLoginItems()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Open Login Items")
                } else {
                    Button("Enable at Login") {
                        appState.setLaunchAtLogin(true)
                        if appState.loginItemStatus == .enabled { finish() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.canEnableLaunchAtLogin)
                    .accessibilityLabel("Enable at Login")
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
