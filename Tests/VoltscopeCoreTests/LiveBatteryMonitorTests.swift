import Foundation
import XCTest
@testable import VoltscopeCore

// MARK: - Fakes

/// Virtual clock. Waits are recorded rather than waited on, and `advance` fires
/// whatever is due in order, letting a wait re-arm itself. That is what makes the
/// settle timeline and the panel refresh cycle checkable without spending seconds.
@MainActor
final class ScriptedBatteryTimeSource: BatteryTimeSource {
    var now: Date
    /// Delays the live layer asked for, in the order it asked for them.
    private(set) var armedDelays: [TimeInterval] = []
    private var waits: [Wait] = []

    private struct Wait {
        let due: Date
        let work: ScheduledBatteryWork
        let action: @MainActor @Sendable () -> Void
    }

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        now = start
    }

    var pendingWaitCount: Int { waits.filter { !$0.work.isCancelled }.count }

    /// How long from now each pending wait is due, soonest first.
    var pendingDelays: [TimeInterval] {
        waits.filter { !$0.work.isCancelled }
            .sorted { $0.due < $1.due }
            .map { $0.due.timeIntervalSince(now) }
    }

    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) -> ScheduledBatteryWork {
        armedDelays.append(delay)
        let scheduled = ScheduledBatteryWork()
        waits.append(Wait(due: now.addingTimeInterval(delay), work: scheduled, action: work))
        return scheduled
    }

    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        var fired = 0
        while let next = earliestPending(), next.due <= target {
            // A re-arming wait that never moved time forward would spin here; the
            // cap turns that into a visible failure instead of a hang.
            if fired > 500 { break }
            fired += 1
            waits.removeAll { $0.work === next.work }
            now = next.due
            next.action()
        }
        now = target
    }

    private func earliestPending() -> Wait? {
        waits.filter { !$0.work.isCancelled }.min { $0.due < $1.due }
    }
}

/// A power source a test drives. Sampling is synchronous, so the lock exists only
/// to keep the class `Sendable` for the protocol the production sampler meets.
final class ScriptedPowerSource: LiveBatterySampling, @unchecked Sendable {
    struct Power {
        var levelPercent: Double = 70
        var isACPlugged = false
        var isCharging = false
        var isCharged = false

        static let onBattery = Power()
        static let plugged = Power(isACPlugged: true)
        static func charging(level: Double = 70) -> Power {
            Power(levelPercent: level, isACPlugged: true, isCharging: true)
        }

        static func charged(level: Double = 100) -> Power {
            Power(levelPercent: level, isACPlugged: true, isCharged: true)
        }

        /// A charger that holds the battery without charging it, which is the case
        /// the old caption called "Battery Is Charged".
        static func held(level: Double = 80) -> Power {
            Power(levelPercent: level, isACPlugged: true)
        }
    }

    private let lock = NSLock()
    private var storedPower = Power()
    private var storedSampleTimes: [Date] = []

    var power: Power {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedPower
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedPower = newValue
        }
    }

    /// When each sample was taken, on the injected clock.
    var sampleTimes: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return storedSampleTimes
    }

    var sampleCount: Int { sampleTimes.count }

    func liveSample(at date: Date) -> LiveBatteryReading? {
        let current = power
        lock.lock()
        storedSampleTimes.append(date)
        lock.unlock()
        return LiveBatteryReading(
            snapshot: BatterySnapshot(
                timestamp: Int64(date.timeIntervalSince1970 * 1000),
                levelPercent: current.levelPercent,
                capacityMAh: 5_000, designMAh: 6_000, cycleCount: 120,
                voltageMV: 12_800, amperageMA: current.isCharging ? 900 : -900,
                temperatureC: 29.5, timeRemainingMin: 180,
                isCharging: current.isCharging, isACPlugged: current.isACPlugged
            ),
            isCharged: current.isCharged
        )
    }
}

/// Power-source notifications a test delivers by hand.
@MainActor
final class FakePowerSourceNotifier: PowerSourceChangeNotifying {
    var onChange: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    /// Stands in for the system posting a power-source notification.
    func emit() { onChange?() }
}

/// Collects the events a recorder writes.
actor PowerEventLedger {
    private var stored: [PowerEvent] = []

    func append(_ event: PowerEvent) { stored.append(event) }

    var written: [PowerEvent] { stored }
}

/// One test's worth of fakes plus the readings they published.
@MainActor
struct LiveLayerFixture {
    let clock: ScriptedBatteryTimeSource
    let source: ScriptedPowerSource
    let notifier: FakePowerSourceNotifier
    let log: ReadingLog

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        clock = ScriptedBatteryTimeSource(start: start)
        source = ScriptedPowerSource()
        notifier = FakePowerSourceNotifier()
        log = ReadingLog()
    }

    func monitor(
        plugEvents: PlugEventRecorder? = nil,
        timing: LiveBatteryMonitor.Timing = .standard
    ) -> LiveBatteryMonitor {
        LiveBatteryMonitor(
            sampler: source,
            notifier: notifier,
            timeline: clock,
            plugEvents: plugEvents,
            timing: timing,
            onReading: { [log] reading in log.append(reading) }
        )
    }

    var readings: [LiveBatteryReading] { log.readings }
    var lastState: BatteryChargeState? { log.readings.last?.chargeState }
    var samples: Int { source.sampleCount }

    /// Seconds between each sample and `start`, rounded to hundredths.
    func offsets(from start: Date) -> [TimeInterval] {
        source.sampleTimes.map { (Double(($0.timeIntervalSince(start) * 100).rounded()) / 100) }
    }

    func power(_ new: ScriptedPowerSource.Power) { source.power = new }
    func advance(_ seconds: TimeInterval) { clock.advance(by: seconds) }
}

@MainActor
final class ReadingLog {
    private(set) var readings: [LiveBatteryReading] = []

    func append(_ reading: LiveBatteryReading) { readings.append(reading) }
}

// MARK: - Tests

@MainActor
final class LiveBatteryMonitorTests: XCTestCase {
    private typealias Power = ScriptedPowerSource.Power

    // MARK: Launch

    func testStartTakesOneReadingAndArmsNothing() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        let start = f.clock.now

        monitor.start()

        XCTAssertEqual(f.samples, 1, "launch takes the first reading so the panel stops showing a stored row")
        XCTAssertEqual(f.lastState, .onBattery)
        XCTAssertEqual(monitor.armedWaitCount, 0, "with the panel closed and no change, nothing may wake the process")
        XCTAssertEqual(f.clock.pendingWaitCount, 0)
        XCTAssertEqual(f.clock.armedDelays, [])
        XCTAssertEqual(f.offsets(from: start), [0])
        XCTAssertTrue(monitor.isRunning)
    }

    func testStopUnsubscribesAndCancelsEveryWait() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.start()
        monitor.panelOpened()
        XCTAssertEqual(monitor.armedWaitCount, 1)

        monitor.stop()

        XCTAssertEqual(f.notifier.startCount, 1)
        XCTAssertEqual(f.notifier.stopCount, 1)
        XCTAssertEqual(monitor.armedWaitCount, 0)
        XCTAssertEqual(f.clock.pendingWaitCount, 0)
        let samples = f.samples
        f.notifier.emit()
        f.advance(30)
        XCTAssertEqual(f.samples, samples, "a stopped monitor stays stopped")
    }

    // MARK: Notification coalescing

    func testNotificationBurstCollapsesIntoALeadingAndATrailingReading() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.start()
        XCTAssertEqual(f.samples, 1)

        f.power(.plugged)
        for _ in 0..<5 { f.notifier.emit() }
        XCTAssertEqual(f.samples, 2, "five notifications in one burst cost one reading, not five")
        XCTAssertEqual(f.lastState, .startingToCharge)

        f.power(.charging())
        f.advance(0.25)
        XCTAssertEqual(f.samples, 3, "the burst's last notification still gets one trailing reading")
        XCTAssertEqual(f.lastState, .charging)
    }

    func testBurstWithNoFollowUpNotificationDoesNotReSample() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.start()
        f.notifier.emit()
        XCTAssertEqual(f.samples, 2)

        f.advance(0.25)
        XCTAssertEqual(f.samples, 2, "the quiet window only re-samples when something arrived inside it")
    }

    func testNotificationAfterTheQuietWindowSamplesAgain() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.start()
        f.notifier.emit()
        f.advance(0.25)
        let samples = f.samples
        f.advance(5)
        f.notifier.emit()
        XCTAssertEqual(f.samples, samples + 1)
    }

    // MARK: Settle re-samples

    func testPlugChangeReSamplesAtTwoFiveAndTenSecondsAndEndsTheTransitionalCaption() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.start()
        let start = f.clock.now

        f.power(.plugged)
        f.notifier.emit()
        XCTAssertEqual(f.clock.armedDelays, [2, 5, 10, 0.25], "the plug arms the settle re-samples plus the quiet window")
        XCTAssertEqual(f.lastState, .startingToCharge)

        f.advance(2)
        XCTAssertEqual(f.lastState, .startingToCharge)
        f.advance(3)
        XCTAssertEqual(f.lastState, .startingToCharge)
        f.advance(5)
        XCTAssertEqual(
            f.lastState, .pluggedNotCharging,
            "the last re-sample closes the settle window, so the caption is final by then"
        )

        let expected: [TimeInterval] = [0, 0, 2, 5, 10]
        XCTAssertEqual(f.offsets(from: start), expected)
        f.advance(60)
        XCTAssertEqual(f.samples, 5, "the settle window is finite: nothing keeps sampling")
        XCTAssertEqual(monitor.armedWaitCount, 0)
    }

    func testUnplugAlsoReSamplesAndLandsOnBattery() {
        let f = LiveLayerFixture()
        f.power(.charging())
        let monitor = f.monitor()
        monitor.start()
        let start = f.clock.now

        f.power(.onBattery)
        f.notifier.emit()
        XCTAssertEqual(f.lastState, .onBattery)
        XCTAssertEqual(f.clock.pendingDelays.sorted(), [0.25, 2, 5, 10])

        f.advance(10)
        let expected: [TimeInterval] = [0, 0, 2, 5, 10]
        XCTAssertEqual(f.offsets(from: start), expected)
        XCTAssertEqual(f.lastState, .onBattery)
    }

    func testChargingThatStartsDuringTheSettleWindowEndsTheTransitionalCaptionEarly() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.start()
        f.power(.plugged)
        f.notifier.emit()
        XCTAssertEqual(f.lastState, .startingToCharge)

        f.advance(2)
        f.power(.charging())
        f.notifier.emit()
        XCTAssertEqual(f.lastState, .charging)

        f.advance(8)
        XCTAssertEqual(f.lastState, .charging, "a settle re-sample must not undo a real charging state")
        // launch, plug, +2, the charging notification, +5, +10
        XCTAssertEqual(f.samples, 6)
    }

    func testChargedOnlyAppearsWhenTheSystemSaysSo() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.start()
        f.advance(30)

        f.power(.charged())
        f.notifier.emit()
        XCTAssertEqual(f.lastState, .charged)
        XCTAssertEqual(f.lastState?.symbolName, "battery.100")

        // The same plug with the charged key clear, well after the settle window,
        // must not be worded as charged.
        f.advance(30)
        f.power(.held())
        f.notifier.emit()
        XCTAssertEqual(f.lastState, .pluggedNotCharging)
    }

    func testSettleWindowRestartsOnlyOnAnActualPowerSourceChange() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.start()
        f.power(.plugged)
        f.notifier.emit()
        XCTAssertEqual(f.clock.armedDelays, [2, 5, 10, 0.25])

        // Charging starting is a notification without a power-source change: it
        // must not arm a second settle window, or a flapping charger never settles.
        f.advance(1)
        f.power(.charging())
        f.notifier.emit()
        XCTAssertEqual(f.clock.armedDelays, [2, 5, 10, 0.25, 0.25])
        XCTAssertEqual(f.lastState, .charging)
    }

    func testReadsInsideTheSettleWindowSpendNoneOfTheSettleReSamples() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.start()
        let start = f.clock.now

        f.power(.plugged)
        f.notifier.emit()
        f.notifier.emit()
        f.advance(0.25)
        XCTAssertEqual(f.samples, 3, "the burst's trailing read is taken inside the settle window")
        XCTAssertEqual(monitor.armedWaitCount, f.clock.pendingWaitCount)
        XCTAssertEqual(monitor.armedWaitCount, 3, "all three settle re-samples are still armed")

        monitor.panelOpened()
        XCTAssertEqual(f.samples, 4, "opening the panel reads once, also inside the window")
        XCTAssertEqual(monitor.armedWaitCount, f.clock.pendingWaitCount)
        XCTAssertEqual(monitor.armedWaitCount, 4, "three settle re-samples plus the refresh cycle")

        f.advance(1.75)
        XCTAssertEqual(f.samples, 5, "the +2 re-sample runs even though two other reads came first")
        XCTAssertEqual(monitor.armedWaitCount, f.clock.pendingWaitCount)
        XCTAssertEqual(monitor.armedWaitCount, 3)

        f.advance(0.25)
        XCTAssertEqual(f.samples, 6, "the panel tick and the +2 re-sample are two separate reads")
        XCTAssertEqual(monitor.armedWaitCount, f.clock.pendingWaitCount)
        XCTAssertEqual(monitor.armedWaitCount, 3)

        f.advance(2.75)
        XCTAssertEqual(f.samples, 8, "and the +5 re-sample is there too")
        XCTAssertEqual(monitor.armedWaitCount, f.clock.pendingWaitCount)
        XCTAssertEqual(monitor.armedWaitCount, 2)

        f.advance(5)
        let expected: [TimeInterval] = [0, 0, 0.25, 0.25, 2, 2.25, 4.25, 5, 6.25, 8.25, 10]
        XCTAssertEqual(f.offsets(from: start), expected,
                       "the settle window keeps its own +2/+5/+10 reads whatever else reads")
        XCTAssertEqual(f.lastState, .pluggedNotCharging, "the +10 read still closes the window")
        XCTAssertEqual(monitor.armedWaitCount, f.clock.pendingWaitCount)
        XCTAssertEqual(monitor.armedWaitCount, 1, "only the panel's own cycle is left")

        monitor.panelClosed()
        XCTAssertEqual(monitor.armedWaitCount, 0)
        XCTAssertEqual(f.clock.pendingWaitCount, 0)
        let samples = f.samples
        f.advance(30)
        XCTAssertEqual(f.samples, samples)
    }

    // MARK: Panel refresh

    func testPanelOpenReadsImmediatelyThenEveryTwoSecondsAndCloseStopsIt() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.start()
        let start = f.clock.now
        XCTAssertEqual(monitor.armedWaitCount, 0)

        monitor.panelOpened()
        XCTAssertEqual(f.samples, 2, "opening the panel reads once immediately")
        XCTAssertEqual(monitor.armedWaitCount, 1)
        XCTAssertTrue(monitor.isPanelOpen)

        f.advance(2)
        f.advance(2)
        let expected: [TimeInterval] = [0, 0, 2, 4]
        XCTAssertEqual(f.offsets(from: start), expected)

        monitor.panelClosed()
        XCTAssertFalse(monitor.isPanelOpen)
        XCTAssertEqual(monitor.armedWaitCount, 0, "a closed panel may not leave a refresh cycle running")
        XCTAssertEqual(f.clock.pendingWaitCount, 0)

        f.advance(30)
        XCTAssertEqual(f.samples, 4, "no reading is taken while the panel is closed")
    }

    func testPanelOpenReplacesTheStoredRowWithTheLiveState() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.start()
        f.power(.charging(level: 42))
        monitor.panelOpened()
        XCTAssertEqual(f.readings.last?.levelPercent, 42)
        XCTAssertEqual(f.lastState, .charging)
    }

    func testPanelOpenedBeforeTheMonitorStartsStillReadsOnceOnStart() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.panelOpened()
        XCTAssertEqual(f.samples, 0, "there is nothing to read from until the monitor runs")

        monitor.start()
        XCTAssertEqual(f.samples, 1, "start reads once, not twice, with the panel already open")
        XCTAssertEqual(monitor.armedWaitCount, 1)
        f.advance(2)
        XCTAssertEqual(f.samples, 2)
    }

    func testPanelClosedBeforeStartDoesNotArmARefreshCycle() {
        let f = LiveLayerFixture()
        let monitor = f.monitor()
        monitor.panelClosed()
        monitor.start()
        XCTAssertEqual(monitor.armedWaitCount, 0)
        f.advance(20)
        XCTAssertEqual(f.samples, 1)
    }

    // MARK: Plug markers

    func testPlugMarkerIsWrittenAtNotificationTimeAndNotAgainDuringSettling() async {
        let ledger = PowerEventLedger()
        let recorder = PlugEventRecorder(write: { event in await ledger.append(event) })
        let f = LiveLayerFixture()
        let monitor = f.monitor(plugEvents: recorder)
        monitor.start()
        let launchEvents = await ledger.written
        XCTAssertTrue(launchEvents.isEmpty, "starting the app is not a plug event")

        f.power(.plugged)
        f.notifier.emit()
        await monitor.waitForPlugMarkers()
        var written = await ledger.written
        XCTAssertEqual(written.count, 1, "the marker is written while the notification is handled")
        XCTAssertEqual(written.first?.type, .plug)

        f.advance(10)
        await monitor.waitForPlugMarkers()
        written = await ledger.written
        XCTAssertEqual(written.count, 1, "the settle re-samples must not repeat the marker")
        let recorded = await recorder.recordedState
        XCTAssertEqual(recorded, true)
    }

    func testUnplugAndReplugEachWriteAMarker() async {
        let ledger = PowerEventLedger()
        let recorder = PlugEventRecorder(write: { event in await ledger.append(event) })
        let f = LiveLayerFixture()
        let monitor = f.monitor(plugEvents: recorder)
        f.power(.plugged)
        monitor.start()

        f.power(.onBattery)
        f.notifier.emit()
        f.advance(20)
        f.power(.plugged)
        f.notifier.emit()
        f.advance(20)
        await monitor.waitForPlugMarkers()

        let written = await ledger.written
        XCTAssertEqual(written.compactMap(\.type), [.unplug, .plug])
    }
}
