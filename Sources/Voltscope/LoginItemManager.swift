import AppKit
import Foundation
import ServiceManagement
import VoltscopeCore

@MainActor
final class LoginItemManager {
    private(set) var status: LoginItemStatusKind = .notRegistered
    private(set) var feedback: String?
    private var operationFeedback: String?

    init() {
        refresh()
    }

    var isEnabled: Bool { status == .enabled }
    var canEnable: Bool { isEligible }

    func refresh() {
        status = Self.map(SMAppService.mainApp.status)
        if status == .enabled {
            operationFeedback = nil
            feedback = nil
        } else if let operationFeedback {
            feedback = operationFeedback
        } else if !isEligible {
            feedback = "Move Voltscope to Applications before enabling Launch at login."
        } else if status != .error {
            feedback = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    func register() {
        guard isEligible else {
            operationFeedback = nil
            feedback = "Move Voltscope to Applications before enabling Launch at login."
            refresh()
            return
        }
        do {
            try SMAppService.mainApp.register()
            operationFeedback = nil
            feedback = nil
        } catch {
            operationFeedback = "Launch at login could not be enabled. \(error.localizedDescription)"
            feedback = operationFeedback
        }
        refresh()
    }

    func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            operationFeedback = nil
            feedback = nil
        } catch {
            operationFeedback = "Launch at login could not be disabled. \(error.localizedDescription)"
            feedback = operationFeedback
        }
        refresh()
    }

    func openLoginItems() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private var isEligible: Bool {
        LoginItemPolicy.eligibility(
            bundlePath: Bundle.main.bundleURL.path,
            homePath: NSHomeDirectory()
        ) == .allowed
    }

    private static func map(_ status: SMAppService.Status) -> LoginItemStatusKind {
        switch status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .error
        }
    }
}
