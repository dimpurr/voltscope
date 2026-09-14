import SwiftUI
import Sparkle
import VoltscopeCore

@main
struct VoltscopeApp: App {
    @NSApplicationDelegateAdaptor(VoltscopeAppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        appDelegate.configure(state)
        DockIconController.shared.install()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(appState)
        } label: {
            MenuBarLabel()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Window("Voltscope History", id: "history") {
            HistoryWindow()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 520)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 420, height: 160)
                .onAppear { appState.refreshLoginItemStatus() }
        }

        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appState.checkForUpdates()
                }
                .disabled(!appState.canCheckForUpdates)
            }
        }
    }
}

struct SystemAppSummary: Equatable {
    let count: Int
    let totalEnergyNJ: Int64
    /// Top N system processes by energy in the window — surfaced inline when
    /// the dropdown's System section is expanded so the disclosure has actual
    /// content rather than a single "open History" sentence.
    let topItems: [AppDatabase.TopAppEnergy]
    static let empty = SystemAppSummary(count: 0, totalEnergyNJ: 0, topItems: [])
}

@MainActor
final class AppState: ObservableObject {
    @Published var lastBattery: BatterySnapshot?
    @Published var topApps: [AppDatabase.TopAppEnergy] = []
    @Published var systemSummary: SystemAppSummary = .empty
    @Published var statusText: String = "Starting…"
    /// True when the bucket sampler has produced at least one row in the
    /// last 5 minutes. Self-detects across both sampling paths
    /// (IOReport.framework on macOS 13–15, IOConnect on macOS 26+).
    @Published var bucketSamplerActive: Bool = false
    /// Tracks how long we've been bootstrapped — used by the UI to defer
    /// the "bucket sampling unavailable" diagnostic until after the
    /// expected first-tick interval has passed.
    @Published var startedAt: Date = Date()

    @Published private(set) var loginItemStatus: LoginItemStatusKind
    @Published private(set) var loginItemFeedback: String?
    static let loginOnboardingHandledKey = "loginItemOnboardingHandled"

    private(set) var database: AppDatabase?
    private var coordinator: SamplingCoordinator?
    private var eventListener: EventListener?
    private var refreshTask: Task<Void, Never>?
    private let loginItemManager: LoginItemManager

    private let updaterController: SPUStandardUpdaterController

    init() {
        let loginItemManager = LoginItemManager()
        self.loginItemManager = loginItemManager
        self.loginItemStatus = loginItemManager.status
        self.loginItemFeedback = loginItemManager.feedback
        // Sparkle: register the standard updater controller. Its availability
        // is reflected in the menu actions once Sparkle has finished startup.
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        refreshUpdaterAvailability()
        refreshLoginItemStatus()
        Task { @MainActor [weak self] in
            // Sparkle finishes loading its updater asynchronously. Keep the
            // command disabled until its own readiness flag is true.
            for _ in 0..<50 where !Task.isCancelled {
                guard let self else { return }
                self.refreshUpdaterAvailability()
                if self.canCheckForUpdates { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        Task { await self.bootstrap() }
    }

    @Published private(set) var canCheckForUpdates = false

    var hasHandledLoginOnboarding: Bool {
        UserDefaults.standard.bool(forKey: Self.loginOnboardingHandledKey)
    }

    var canEnableLaunchAtLogin: Bool {
        loginItemManager.canEnable
    }

    func completeLoginOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.loginOnboardingHandledKey)
    }

    func refreshLoginItemStatus() {
        loginItemManager.refresh()
        loginItemStatus = loginItemManager.status
        loginItemFeedback = loginItemManager.feedback
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemManager.setEnabled(enabled)
        loginItemStatus = loginItemManager.status
        loginItemFeedback = loginItemManager.feedback
    }

    func openLoginItems() {
        loginItemManager.openLoginItems()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }

    private func refreshUpdaterAvailability() {
        canCheckForUpdates = updaterController.updater.canCheckForUpdates
    }

    private func bootstrap() async {
        do {
            let db = try AppDatabase.makeDefault()
            self.database = db
            let coord = SamplingCoordinator(database: db)
            self.coordinator = coord
            await coord.start()

            let listener = EventListener()
            listener.start { [weak self, weak coord] event in
                guard let coord else { return }
                Task { await coord.recordEvent(event) }
                Task { @MainActor in
                    self?.statusText = "Event: \(event.eventType)"
                }
            }
            self.eventListener = listener

            self.statusText = "Sampling active"
            self.startRefreshLoop()
        } catch {
            self.statusText = "Init failed: \(error.localizedDescription)"
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func refreshNow() async {
        guard let db = database else { return }
        do {
            self.lastBattery = try await db.latestBatterySnapshot()
            // Use appBreakdown so we can split user apps from system processes
            // for the dropdown's collapsible System section, in one read.
            let breakdown = try await db.appBreakdown(sinceMinutes: 30)
            let userTop = breakdown.filter { !$0.isSystem }.prefix(5).map {
                AppDatabase.TopAppEnergy(
                    bundleIdentifier: $0.bundleIdentifier,
                    processName: $0.processName,
                    path: $0.path,
                    totalEnergyNJ: $0.totalEnergyNJ
                )
            }
            self.topApps = Array(userTop)
            let systemEntries = breakdown.filter { $0.isSystem }
            let systemTop = systemEntries.prefix(5).map {
                AppDatabase.TopAppEnergy(
                    bundleIdentifier: $0.bundleIdentifier,
                    processName: $0.processName,
                    path: $0.path,
                    totalEnergyNJ: $0.totalEnergyNJ
                )
            }
            self.systemSummary = SystemAppSummary(
                count: systemEntries.count,
                totalEnergyNJ: systemEntries.reduce(0) { $0 + $1.totalEnergyNJ },
                topItems: Array(systemTop)
            )
            if let active = try? await db.bucketSamplerActive(withinMinutes: 5) {
                self.bucketSamplerActive = active
            }
        } catch {
            // Ignore transient read errors; UI will retry on next tick.
        }
    }
}
