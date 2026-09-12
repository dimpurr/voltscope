import AppKit

/// Keeps the menubar-only default while making the History window behave like
/// a normal document window: visible History means a Dock icon, closing it
/// returns the app to accessory mode without terminating sampling.
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

        // LSUIElement starts the process in accessory mode. Make that intent
        // explicit so a future plist or SwiftUI lifecycle change cannot make
        // the app appear in the Dock before its document window opens.
        Task { @MainActor [weak self] in
            self?.setPolicy(.accessory)
        }
    }

    func historyDidAppear() {
        setPolicy(.regular)
    }

    @objc private func historyWindowAppeared(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isHistoryWindow(window) else { return }
        historyDidAppear()
    }

    @objc private func historyWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isHistoryWindow(window) else { return }
        // NSWindow is still visible during willClose. Wait for the close to
        // finish before checking, otherwise the Dock icon would be retained.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, !self.hasVisibleHistoryWindow else { return }
            self.setPolicy(.accessory)
        }
    }

    private var hasVisibleHistoryWindow: Bool {
        NSApp.windows.contains { isHistoryWindow($0) && $0.isVisible }
    }

    private func isHistoryWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "history" || window.title == "Voltscope History"
    }

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        _ = NSApp.setActivationPolicy(policy)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
