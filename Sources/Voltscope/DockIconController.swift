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
        center.addObserver(self, selector: #selector(userWindowVisibilityChanged(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(userWindowVisibilityChanged(_:)),
                           name: NSWindow.didResignKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(userWindowVisibilityChanged(_:)),
                           name: NSWindow.didResignMainNotification, object: nil)
        center.addObserver(self, selector: #selector(userWindowVisibilityChanged(_:)),
                           name: NSWindow.didMiniaturizeNotification, object: nil)
        center.addObserver(self, selector: #selector(userWindowVisibilityChanged(_:)),
                           name: NSWindow.didDeminiaturizeNotification, object: nil)
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
        guard let window = notification.object as? NSWindow, isTrackedUserWindow(window) else { return }
        setPolicy(.regular)
    }

    @objc private func userWindowVisibilityChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isTrackedUserWindow(window) else { return }
        // SwiftUI may finish closing a scene on the next run-loop turn. Check
        // again after the transition rather than relying on willClose alone.
        DispatchQueue.main.async { [weak self] in self?.reconcilePolicy() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.reconcilePolicy() }
    }

    @objc private func reconcilePolicy() {
        setPolicy(hasVisibleUserWindow ? .regular : .accessory)
    }

    /// MenuBarExtra uses an NSPanel, while the three user-facing scenes have
    /// stable scene identifiers/titles. Explicitly tracking those windows
    /// avoids treating a transient framework or menu-bar window as user work.
    private var hasVisibleUserWindow: Bool {
        NSApp.windows.contains { isTrackedUserWindow($0) && $0.isVisible && !$0.isMiniaturized }
    }

    private func isTrackedUserWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel) else { return false }
        let knownIdentifiers = ["history", "settings", "welcome"]
        if let identifier = window.identifier?.rawValue, knownIdentifiers.contains(identifier) {
            return true
        }
        return ["Voltscope History", "Voltscope Settings", "Welcome to Voltscope"].contains(window.title)
    }

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        _ = NSApp.setActivationPolicy(policy)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
