import AppKit

/// Keeps the menubar-only default while making user-visible windows behave like
/// normal macOS windows. History, Settings, and first-run Welcome each show a
/// Dock icon while open; login launches with no window remain accessory-only.
@MainActor
final class DockIconController: NSObject {
    static let shared = DockIconController()

    private var isInstalled = false

    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(historyWindowAppeared(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(historyWindowAppeared(_:)),
                           name: NSWindow.didBecomeMainNotification, object: nil)
        center.addObserver(self, selector: #selector(historyWindowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(reconcilePolicy),
                           name: NSApplication.didBecomeActiveNotification, object: nil)

        // LSUIElement starts the process in accessory mode. Make that intent
        // explicit so a future plist or SwiftUI lifecycle change cannot make
        // the app appear in the Dock before its document window opens.
        Task { @MainActor [weak self] in
            self?.setPolicy(.accessory)
        }
    }

    @objc private func historyWindowAppeared(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isUserWindow(window) else { return }
        setPolicy(.regular)
    }

    @objc private func historyWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isUserWindow(window) else { return }
        // NSWindow is still visible during willClose. Wait for the close to
        // finish before checking, otherwise the Dock icon would be retained.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.reconcilePolicy()
        }
    }

    @objc private func reconcilePolicy() {
        setPolicy(hasVisibleUserWindow ? .regular : .accessory)
    }

    /// MenuBarExtra uses an NSPanel. The app's regular SwiftUI windows and the
    /// manually hosted Welcome window are NSWindow instances, so this avoids
    /// tying Dock behavior to localized titles or scene implementation details.
    private var hasVisibleUserWindow: Bool {
        NSApp.windows.contains { isUserWindow($0) && $0.isVisible }
    }

    private func isUserWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel)
    }

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        _ = NSApp.setActivationPolicy(policy)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
