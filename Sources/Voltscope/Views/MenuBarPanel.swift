import SwiftUI
import AppKit
import VoltscopeCore

struct MenuBarPanel: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var systemExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: MenuBarPanelLayout.blockSpacing) {
            panelContent
            footer
        }
        .padding(MenuBarPanelLayout.outerPadding)
        .frame(width: MenuBarPanelLayout.width, alignment: .top)
        .frame(minHeight: MenuBarPanelLayout.maximumCollapsedHeight, alignment: .top)
        .background {
            PanelWindowName(
                title: AccessibilityLabels.panelWindowTitle,
                onOpen: { appState.panelOpened() },
                onClose: { appState.panelClosed() }
            )
        }
        .onExitCommand {
            NSApp.keyWindow?.orderOut(nil)
            NSApp.deactivate()
        }
        .onChange(of: appState.displayedChargeState) { state in
            guard let state else { return }
            announceChargeState(state)
        }
    }

    /// Reads the power-state caption and glyph to assistive technology when they
    /// change, the same way the History window announces an error. Without this a
    /// VoiceOver user hears nothing when a charger is connected.
    private func announceChargeState(_ state: BatteryChargeState) {
        let message = state.announcementText
        if #available(macOS 14.0, *) {
            AccessibilityNotification.Announcement(message).post()
        } else {
            let element: Any = (NSApp.keyWindow ?? NSApp) as Any
            NSAccessibility.post(
                element: element,
                notification: .announcementRequested,
                userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        if systemExpanded {
            ScrollView(.vertical) {
                panelContentStack
            }
            .frame(maxHeight: 540)
            .scrollIndicators(.visible)
        } else {
            panelContentStack
        }
    }

    private var panelContentStack: some View {
        VStack(alignment: .leading, spacing: MenuBarPanelLayout.blockSpacing) {
            chargeHeader
            Divider()
            healthSection
            Divider()
            topAppsSection
            Divider()
        }
    }

    // MARK: - Charge header

    private var chargeHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: chargeSymbol)
                    .foregroundStyle(chargeColor)
                    .accessibilityHidden(true)
                Text(chargeStateText)
                    .font(.headline)
                Spacer()
                Text(percentText)
                    .font(.headline.monospacedDigit())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(batteryAccessibilityLabel)
            .accessibilityValue(chargeStateText)
            .accessibilityIdentifier(AccessibilityIdentifiers.menuChargeState)
            ProgressView(value: (appState.displayedBattery?.levelPercent ?? 0) / 100.0)
                .progressViewStyle(.linear)
                .tint(chargeColor)
                .accessibilityHidden(true)
            HStack {
                Text(timeRemainingText)
                    .font(.caption)
                    .foregroundStyle(Color.accessibleSecondary)
                    .accessibilityLabel("Time remaining: \(timeRemainingText)")
                Spacer()
                Text(appState.statusText)
                    .font(.caption)
                    .foregroundStyle(Color.accessibleSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Status: \(appState.statusText)")
            }
        }
    }

    private var chargeSymbol: String {
        appState.displayedChargeState?.symbolName ?? "bolt.slash"
    }

    private var chargeColor: Color {
        guard let state = appState.displayedChargeState else { return .secondary }
        if state.isConnectedToPower { return .green }
        guard let level = appState.displayedBattery?.levelPercent else { return .secondary }
        if level < 20 { return .red }
        if level < 40 { return .orange }
        return .green
    }

    /// The four states plus the transitional caption inside the settle window.
    /// Wording is owned by docs/UI_SPEC.md. "Battery Is Charged" now needs the
    /// system's charged key: any plugged-in-but-not-charging state, such as a
    /// charger holding at 80 percent, says so instead.
    private var chargeStateText: String {
        appState.displayedChargeState?.displayName ?? "Battery"
    }

    private var percentText: String {
        guard let level = appState.displayedBattery?.levelPercent else { return "—" }
        return "\(Int(level.rounded()))%"
    }

    private var timeRemainingText: String {
        guard let battery = appState.displayedBattery, let minutes = battery.timeRemainingMin, minutes > 0 else {
            return "—"
        }
        let h = minutes / 60
        let m = minutes % 60
        let suffix = appState.displayedChargeState == .charging ? "until full" : "until empty"
        if h > 0 {
            return String(format: "%dh %02dm %@", h, m, suffix)
        }
        return String(format: "%dm %@", m, suffix)
    }

    // MARK: - Health section

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Health").font(.caption).foregroundStyle(Color.accessibleSecondary)
                Spacer()
                Text(healthPercentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.accessibleSecondary)
                    .accessibilityLabel("Battery health \(healthPercentAccessibilityValue)")
            }
            HealthBar(healthRatio: healthRatio ?? 0)
                .accessibilityHidden(true)
            HStack(spacing: 16) {
                LabeledMetric(label: "Cycles", value: cycleText)
                LabeledMetric(label: "Condition", value: conditionText)
                Spacer()
                Text(temperatureText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Battery temperature \(temperatureAccessibilityValue)")
            }
        }
    }

    private var healthRatio: Double? {
        guard let battery = appState.displayedBattery,
              let capacity = battery.capacityMAh,
              let design = battery.designMAh,
              design > 0 else { return nil }
        return Double(capacity) / Double(design)
    }

    private var batteryAccessibilityLabel: String {
        let level = appState.displayedBattery?.levelPercent.map { "\(Int($0.rounded())) percent" } ?? "charge unavailable"
        return "Battery \(level)"
    }

    private var healthPercentAccessibilityValue: String {
        guard let ratio = healthRatio else { return "unavailable" }
        return "\(Int((ratio * 100).rounded())) percent"
    }

    private var temperatureAccessibilityValue: String {
        guard let celsius = appState.displayedBattery?.temperatureC else { return "unavailable" }
        let fahrenheit = celsius * 9 / 5 + 32
        return String(format: "%.1f degrees Celsius, %.1f degrees Fahrenheit", celsius, fahrenheit)
    }

    private var healthPercentText: String {
        guard let ratio = healthRatio else { return "—" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    private var cycleText: String {
        guard let cycles = appState.displayedBattery?.cycleCount else { return "—" }
        return "\(cycles)"
    }

    private var conditionText: String {
        BatteryCondition.classify(
            cycleCount: appState.displayedBattery?.cycleCount,
            capacityMAh: appState.displayedBattery?.capacityMAh,
            designMAh: appState.displayedBattery?.designMAh
        ).rawValue
    }

    private var temperatureText: String {
        guard let celsius = appState.displayedBattery?.temperatureC else { return "—" }
        let fahrenheit = celsius * 9 / 5 + 32
        return String(format: "%.1f °C / %.1f °F", celsius, fahrenheit)
    }

    // MARK: - Top apps section

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: MenuBarPanelLayout.appRowSpacing) {
            Text(appState.processEnergyAvailable ? "Top energy use (last 30 min)" : "Top CPU time (last 30 min)")
                .font(.caption)
                .foregroundStyle(Color.accessibleSecondary)
                .accessibilityLabel(appState.processEnergyAvailable ? "Top CPU energy use (last 30 min)" : "Top CPU time (last 30 min)")
            if !appState.processEnergyAvailable {
                Text("Intel Mac computers do not provide per-process energy data.")
                    .font(.caption2).foregroundStyle(Color.accessibleSecondary)
            }
            if appState.topApps.isEmpty && appState.systemSummary.count == 0 {
                Text("Collecting samples…")
                    .font(.callout)
                    .foregroundStyle(Color.accessibleSecondary)
            } else {
                let topMax = appState.topApps.map { appState.processEnergyAvailable ? $0.totalEnergyNJ : $0.totalCPUNS }.max() ?? 0
                ForEach(appState.topApps) { row in
                    appRow(row, topMax: topMax)
                }
                if appState.systemSummary.count > 0 {
                    systemRow
                }
            }
        }
    }

    private func appRow(_ row: HistoryDatabase.TopAppEnergy, topMax: Int64) -> some View {
        HStack(spacing: 8) {
            AppIconView(path: row.path, bundleId: row.bundleIdentifier, size: 16)
                .accessibilityHidden(true)
            Text(row.processName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !appState.processEnergyAvailable {
                Text(String(format: "%.1fs", Double(row.totalCPUNS) / 1e9))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.accessibleSecondary)
                    .accessibilityHidden(true)
            }
            IntensityDots(filled: IntensityDots.dotCount(value: MenuBarMetricPresentation.value(
                energyNJ: row.totalEnergyNJ, cpuNS: row.totalCPUNS,
                energyAvailable: appState.processEnergyAvailable), max: topMax))
                .accessibilityHidden(true)
            Button {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
                    .frame(width: HitTarget.minimumSide, height: HitTarget.minimumSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open in History window")
            .accessibilityLabel(AccessibilityLabels.openHistoryFromApp(name: row.processName))
            .accessibilityIdentifier(AccessibilityIdentifiers.menuOpenAppInHistory(appIdentity: row.id))
        }
        .help(rowTooltip(row))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.processName)
        .accessibilityValue(AccessibilityLabels.menuBarAppRowValue(
            energyNJ: row.totalEnergyNJ,
            cpuNS: row.totalCPUNS,
            energyAvailable: appState.processEnergyAvailable
        ))
        .accessibilityAction(named: AccessibilityLabels.openHistoryFromApp(name: row.processName)) {
            openWindow(id: "history")
            NSApp.activate(ignoringOtherApps: true)
        }
        .frame(minHeight: MenuBarPanelLayout.appRowHeight)
    }

    private func rowTooltip(_ row: HistoryDatabase.TopAppEnergy) -> String {
        let bundle = row.bundleIdentifier ?? "(no bundle)"
        if !appState.processEnergyAvailable { return "\(row.processName)\n\(bundle)\nRanked by CPU time. Intel Mac computers do not provide per-process energy data." }
        let joules = Double(row.totalEnergyNJ) / 1_000_000_000.0
        return String(format: "%@\n%@\nLast 30 min: %.2f J", row.processName, bundle, joules)
    }

    /// Collapsible footer row: keeps system processes in the dropdown
    /// (geek users want them) but out of the user-app stack by default.
    /// Expanded shows the top 5 system processes inline, mirroring the user
    /// app section above. Symmetric layout keeps the dropdown predictable.
    private var systemRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    systemExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        systemExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: systemExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(.secondary)
                    Text("System")
                        .foregroundStyle(Color.accessibleSecondary)
                    Text(systemSummaryText)
                        .font(.caption)
                        .foregroundStyle(Color.accessibleSecondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("System processes")
            .accessibilityIdentifier(AccessibilityIdentifiers.menuSystemProcesses)
            .accessibilityValue(systemExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows system processes and their recent CPU energy use")

            if systemExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    let systemMax = appState.systemSummary.topItems.map {
                        MenuBarMetricPresentation.value(energyNJ: $0.totalEnergyNJ, cpuNS: $0.totalCPUNS,
                                                        energyAvailable: appState.processEnergyAvailable)
                    }.max() ?? 0
                    ForEach(appState.systemSummary.topItems) { row in
                        appRow(row, topMax: systemMax)
                            .opacity(0.7)
                    }
                    if appState.systemSummary.count > appState.systemSummary.topItems.count {
                        Text("+ \(appState.systemSummary.count - appState.systemSummary.topItems.count) more in History")
                            .font(.caption)
                            .foregroundStyle(Color.accessibleSecondary)
                            .padding(.leading, 24)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var systemSummaryText: String {
        let s = appState.systemSummary
        return MenuBarMetricPresentation.systemSummary(count: s.count, energyNJ: s.totalEnergyNJ,
                                                       cpuNS: s.totalCPUNS, energyAvailable: appState.processEnergyAvailable)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 8) {
                    Label("Open History", systemImage: "chart.bar.xaxis")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("h", modifiers: .command)
            .accessibilityLabel("Open History")
            .accessibilityIdentifier(AccessibilityIdentifiers.menuOpenHistory)

            HStack(spacing: 10) {
                Button {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .foregroundStyle(Color.accessibleSecondary)
                        .frame(minHeight: HitTarget.minimumSide)
                        .contentShape(Rectangle())
                }
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier(AccessibilityIdentifiers.menuSettings)
                Button {
                    appState.checkForUpdates()
                } label: {
                    HStack(spacing: 4) {
                        Label("Check for Updates", systemImage: "arrow.down.circle")
                            .foregroundStyle(Color.accessibleSecondary)
                        Text("v\(appState.appVersion)")
                            .foregroundStyle(Color.accessibleSecondary)
                    }
                    .frame(minHeight: HitTarget.minimumSide)
                    .contentShape(Rectangle())
                }
                .disabled(!appState.canCheckForUpdates)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Check for Updates, version \(appState.appVersion)")
                .accessibilityIdentifier(AccessibilityIdentifiers.menuCheckForUpdates)
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .foregroundStyle(Color.accessibleSecondary)
                        .frame(minHeight: HitTarget.minimumSide)
                        .contentShape(Rectangle())
                }
                .keyboardShortcut("q", modifiers: .command)
                .accessibilityLabel("Quit")
                .accessibilityIdentifier(AccessibilityIdentifiers.menuQuit)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Names the panel's window for assistive technology and reports when the panel
/// is on screen. A `MenuBarExtra` popover window has no title of its own, so
/// assistive technology announces the panel without a name at all; the title is
/// applied when the hosting view joins the window.
///
/// `MenuBarExtra` offers no open or close callback. The panel's own hosting window
/// is the signal: it becomes key while the dropdown is up — the panel's Escape and
/// command-key handling already depends on that — and resigns key when the dropdown
/// goes away, including when a button in it opens another window.
private struct PanelWindowName: NSViewRepresentable {
    let title: String
    let onOpen: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowNamingView()
        view.windowName = title
        view.onOpen = onOpen
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowNamingView else { return }
        view.windowName = title
        view.onOpen = onOpen
        view.onClose = onClose
    }
}

private final class WindowNamingView: NSView {
    var windowName: String? {
        didSet { applyWindowName() }
    }
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    private var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowName()
        observePanelWindow()
    }

    /// Detaches as soon as AppKit says the view is leaving its window. Waiting for
    /// the next `viewDidMoveToWindow` would leave the three observer blocks
    /// registered for the process lifetime on a view SwiftUI simply discards,
    /// because a discarded view never re-attaches.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        removePanelWindowObservers()
        observedWindow = nil
        // The observers are gone from this point on, so a resign-key that has
        // not reached its block yet never will; report the close from here
        // instead, through the same ordered hop every other delivery uses.
        deliverClose()
    }

    // No deinit cleanup: leaving a window detaches the observers, and every
    // observer block holds `self` weakly, so a view that is released while still
    // attached has nothing left to call.

    private func applyWindowName() {
        guard let windowName else { return }
        window?.setAccessibilityTitle(windowName)
    }

    private func removePanelWindowObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func observePanelWindow() {
        guard window !== observedWindow else { return }
        removePanelWindowObservers()
        observedWindow = window
        guard let window else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
                [weak self] _ in self?.deliverOpen()
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
                [weak self] _ in self?.deliverClose()
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in self?.deliverClose()
            }
        ]
        // The window can become key before this view joins it.
        if window.isKeyWindow { deliverOpen() }
    }

    /// Hands `onOpen` / `onClose` to SwiftUI one main-queue turn later instead
    /// of running them in place. Calling them from `viewDidMoveToWindow`,
    /// `viewWillMove(toWindow:)` or a window notification can publish
    /// `liveBattery` from inside a view update. Every delivery goes through
    /// this one hop, and `DispatchQueue.main` runs its blocks in the order they
    /// were enqueued, so an open and a close keep the order AppKit reported
    /// them in: a close that arrives after an open is delivered after it and
    /// wins, which is what stops the 2 s refresh cycle on a quick open→close.
    nonisolated private func deliverOpen() {
        DispatchQueue.main.async { @MainActor [weak self] in self?.onOpen?() }
    }

    nonisolated private func deliverClose() {
        DispatchQueue.main.async { @MainActor [weak self] in self?.onClose?() }
    }
}

private struct LabeledMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.accessibleSecondary)
            Text(value)
                .font(.callout)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}
