import Foundation

/// Keeps the menu bar and panel on the current power state, not on the last row
/// written to history.
///
/// Three kinds of work happen here, and they are deliberately the only three:
///
/// 1. A power-source notification arrives, so a reading is taken immediately.
///    Bursts collapse: the first notification samples, later ones inside the quiet
///    window are noted, and one trailing reading is taken when the window closes.
///    Inserting a charger makes the system notify several times in a row, and each
///    reading costs an IORegistry read; there is no reason to pay for all of them.
/// 2. When a reading's AC state differs from the previous one, charging state,
///    power and time remaining all lag the plug itself, so the monitor re-samples
///    at fixed short delays and labels the state as still settling.
/// 3. While the panel is open it refreshes on a slow cycle and closes that cycle
///    the moment the panel closes.
///
/// History is untouched: readings are not written to the database here, and the
/// only database write is the plug/unplug marker, delegated to `PlugEventRecorder`
/// so the 30 s history loop cannot write the same transition a second time.
///
/// Everything is synchronous on the main actor. A sample is one Power Sources
/// description plus one `AppleSmartBattery` property read, which is well under a
/// millisecond, and taking it in place is what keeps the settle timeline
/// deterministic enough to assert on.
@MainActor
public final class LiveBatteryMonitor {
    /// Wait lengths for the live layer, in seconds.
    public struct Timing: Equatable, Sendable {
        /// Notifications arriving inside this window collapse into one trailing
        /// reading instead of one reading each.
        public var quietWindow: TimeInterval
        /// Re-sample offsets after a plug or unplug. The last one closes the
        /// settle window, which is also the deadline for the transitional caption.
        public var settleDelays: [TimeInterval]
        /// Refresh cycle while the panel is open. Cancelled while it is closed.
        public var panelRefreshInterval: TimeInterval

        public init(
            quietWindow: TimeInterval = 0.25,
            settleDelays: [TimeInterval] = [2, 5, 10],
            panelRefreshInterval: TimeInterval = 2
        ) {
            self.quietWindow = quietWindow
            self.settleDelays = settleDelays
            self.panelRefreshInterval = panelRefreshInterval
        }

        public static let standard = Timing()
    }

    /// Latest live reading, `nil` until the first sample succeeds.
    public private(set) var reading: LiveBatteryReading?
    public private(set) var isRunning = false
    public private(set) var isPanelOpen = false

    /// Waits currently armed: the settle re-samples that still have to run, plus a
    /// quiet window and the panel refresh cycle if either is open. Zero means
    /// nothing can wake this process until either a notification arrives or the
    /// panel opens; tests use it to prove that a closed panel leaves no periodic
    /// wakeup behind, and cross-check it against their own clock.
    public var armedWaitCount: Int {
        var count = settleWorks.filter { !$0.work.isCancelled }.count
        if let quietWindowWork, !quietWindowWork.isCancelled { count += 1 }
        if let panelRefreshWork, !panelRefreshWork.isCancelled { count += 1 }
        return count
    }

    private let sampler: any LiveBatterySampling
    private let notifier: any PowerSourceChangeNotifying
    private let timeline: any BatteryTimeSource
    private let plugEvents: PlugEventRecorder?
    private let onReading: @MainActor @Sendable (LiveBatteryReading) -> Void
    private let timing: Timing

    private var lastObservedACPlugged: Bool?
    private var settleDeadline: Date?
    /// The settle re-samples that are armed and have not run yet: a re-sample takes
    /// its own entry out of this list the moment it fires. Reads that are not settle
    /// work — a panel refresh or a burst's trailing read — never spend one of them.
    private var settleWorks: [SettleWork] = []
    private var settleToken = 0

    private struct SettleWork {
        let token: Int
        let work: ScheduledBatteryWork
    }

    private var quietWindowWork: ScheduledBatteryWork?
    private var notificationAbsorbed = false
    private var panelRefreshWork: ScheduledBatteryWork?
    private var markerTasks: [Task<Void, Never>] = []

    public init(
        sampler: any LiveBatterySampling,
        notifier: any PowerSourceChangeNotifying,
        timeline: any BatteryTimeSource,
        plugEvents: PlugEventRecorder? = nil,
        timing: Timing = .standard,
        onReading: @escaping @MainActor @Sendable (LiveBatteryReading) -> Void = { _ in }
    ) {
        self.sampler = sampler
        self.notifier = notifier
        self.timeline = timeline
        self.plugEvents = plugEvents
        self.timing = timing
        self.onReading = onReading
    }

    /// Subscribes to power-source changes and takes the first reading.
    ///
    /// The first reading is what ends the launch-time fallback to the newest
    /// history row, so it is worth taking even with a closed panel; after it the
    /// monitor waits for notifications and does nothing else.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        notifier.onChange = { [weak self] in self?.powerSourceDidChange() }
        notifier.start()
        if isPanelOpen {
            refreshPanelCycle()
        } else {
            sampleNow()
        }
    }

    /// Unsubscribes and cancels every armed wait.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        notifier.onChange = nil
        notifier.stop()
        cancelQuietWindow()
        cancelSettleWindow()
        cancelPanelRefresh()
        settleDeadline = nil
    }

    /// The panel opened: read once now, then refresh while it stays open.
    public func panelOpened() {
        guard !isPanelOpen else { return }
        isPanelOpen = true
        guard isRunning else { return }
        refreshPanelCycle()
    }

    /// The panel closed: cancel the refresh cycle. Nothing is left armed.
    public func panelClosed() {
        guard isPanelOpen else { return }
        isPanelOpen = false
        cancelPanelRefresh()
    }

    // MARK: - Notification handling

    /// Called for every system power-source notification.
    ///
    /// Also the seam tests use to deliver a burst, which is how the coalescing
    /// window is checked without a real charger.
    func powerSourceDidChange() {
        guard isRunning else { return }
        if let quietWindowWork, !quietWindowWork.isCancelled {
            notificationAbsorbed = true
            return
        }
        sampleNow()
        guard timing.quietWindow > 0 else { return }
        notificationAbsorbed = false
        quietWindowWork = timeline.schedule(after: timing.quietWindow) { [weak self] in
            guard let self else { return }
            self.quietWindowWork = nil
            guard self.notificationAbsorbed, self.isRunning else {
                self.notificationAbsorbed = false
                return
            }
            self.notificationAbsorbed = false
            self.sampleNow()
        }
    }

    private func cancelQuietWindow() {
        quietWindowWork?.cancel()
        quietWindowWork = nil
        notificationAbsorbed = false
    }

    // MARK: - Settle window

    private func openSettleWindow() {
        cancelSettleWindow()
        guard let lastDelay = timing.settleDelays.max() else {
            settleDeadline = nil
            return
        }
        settleDeadline = timeline.now.addingTimeInterval(lastDelay)
        for delay in timing.settleDelays {
            settleToken += 1
            let token = settleToken
            let work = timeline.schedule(after: delay) { [weak self] in
                // A re-sample stops being an armed wait the instant it runs, and a
                // read that came from anywhere else cannot shorten this list: the
                // window is the plug change's, not the panel's or the burst's.
                guard let self, self.isRunning else { return }
                self.settleWorks.removeAll { $0.token == token }
                self.sampleNow()
            }
            settleWorks.append(SettleWork(token: token, work: work))
        }
    }

    private func cancelSettleWindow() {
        settleWorks.forEach { $0.work.cancel() }
        settleWorks.removeAll()
    }

    private var isSettlingAfterPlugChange: Bool {
        guard let settleDeadline else { return false }
        return timeline.now < settleDeadline
    }

    // MARK: - Sampling

    private func refreshPanelCycle() {
        guard isRunning, isPanelOpen else { return }
        sampleNow()
        armPanelRefresh()
    }

    private func armPanelRefresh() {
        cancelPanelRefresh()
        guard isRunning, isPanelOpen, timing.panelRefreshInterval > 0 else { return }
        panelRefreshWork = timeline.schedule(after: timing.panelRefreshInterval) { [weak self] in
            guard let self, self.isRunning, self.isPanelOpen else { return }
            self.panelRefreshWork = nil
            self.sampleNow()
            self.armPanelRefresh()
        }
    }

    private func cancelPanelRefresh() {
        panelRefreshWork?.cancel()
        panelRefreshWork = nil
    }

    /// Takes one reading, decides its state while the settle window is still
    /// known, publishes it, and hands the AC state to the plug-event ledger.
    private func sampleNow() {
        guard let sampled = sampler.liveSample(at: timeline.now) else { return }
        let previousACPlugged = lastObservedACPlugged
        lastObservedACPlugged = sampled.snapshot.isACPlugged
        if let previousACPlugged, previousACPlugged != sampled.snapshot.isACPlugged {
            openSettleWindow()
        }
        let reading = LiveBatteryReading(
            snapshot: sampled.snapshot,
            isCharged: sampled.isCharged,
            settlingAfterPlugChange: isSettlingAfterPlugChange
        )
        self.reading = reading
        onReading(reading)
        if let plugEvents {
            let snapshot = sampled.snapshot
            // The run's first reading only fills the ledger; writing a marker for
            // the state the app started in would mark a transition that no one saw.
            let firstReadingOfRun = previousACPlugged == nil
            let task = Task {
                if firstReadingOfRun {
                    await plugEvents.adopt(isACPlugged: snapshot.isACPlugged)
                } else {
                    await plugEvents.record(isACPlugged: snapshot.isACPlugged, timestamp: snapshot.timestamp)
                }
            }
            // Bounded bookkeeping rather than a completion check: `Task.isCompleted`
            // needs macOS 14, and a marker write is done long before this many
            // readings have piled up.
            markerTasks.append(task)
            if markerTasks.count > 64 { markerTasks.removeFirst(markerTasks.count - 64) }
        }
    }

    /// Waits for plug markers this monitor handed to the recorder. The writes run
    /// off the main actor on purpose; this is the seam tests use instead of a sleep.
    func waitForPlugMarkers() async {
        let pending = markerTasks
        markerTasks.removeAll()
        for task in pending { await task.value }
    }
}
