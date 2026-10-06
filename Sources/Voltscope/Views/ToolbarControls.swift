import AppKit
import SwiftUI

/// Toolbar action button backed by AppKit.
///
/// SwiftUI exposes a toolbar `Button` twice in the accessibility tree: once as
/// the `NSToolbarItem` wrapper and once as the inner SwiftUI button, and both
/// inherit the same label and identifier (audit F-06). No SwiftUI modifier
/// collapses the pair, so the Export action is built on `NSButton`, which the
/// toolbar exposes as a single accessible element.
struct ToolbarButton: NSViewRepresentable {
    let systemImage: String
    /// Visible button caption. UI_SPEC requires the Export control to name its
    /// output format on screen, so the title is not folded into the icon.
    let title: String
    let accessibilityLabel: String
    let identifier: String
    var isEnabled: Bool = true
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageLeading
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        // The visible title carries the meaning, so the symbol is decorative
        // and gets no accessibility description of its own.
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        button.title = title
        button.isEnabled = isEnabled
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityIdentifier(identifier)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// Toolbar menu backed by AppKit.
///
/// A SwiftUI toolbar `Menu` is an `NSMenuToolbarItem` whose default accessibility
/// title is the AppKit placeholder "Edit"; on the audited build the explicit
/// `accessibilityLabel` did not override that title, so VoiceOver read "Edit"
/// instead of "Display options" (audit F-18). `NSPopUpButton` is exposed as one
/// element whose title comes from the accessibility label, so the spoken name is
/// correct.
struct ToolbarMenu: NSViewRepresentable {
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let identifier: String
    let itemTitle: String
    let itemIdentifier: String
    let itemIsOn: Bool
    let itemAction: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: itemAction) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        // A pull-down button uses the first item as its title and hides it from
        // the menu, so the icon lives on that item and the real action follows.
        let titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        titleItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        let actionItem = NSMenuItem(title: itemTitle, action: #selector(Coordinator.fire), keyEquivalent: "")
        actionItem.target = context.coordinator
        actionItem.setAccessibilityIdentifier(itemIdentifier)
        actionItem.state = itemIsOn ? .on : .off
        let menu = NSMenu()
        menu.addItem(titleItem)
        menu.addItem(actionItem)
        button.menu = menu
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(accessibilityValue)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.action = itemAction
        button.item(at: 1)?.state = itemIsOn ? .on : .off
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(accessibilityValue)
        button.setAccessibilityIdentifier(identifier)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
