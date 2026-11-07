import Foundation
import XCTest
@testable import VoltscopeCore

/// A battery whose AC state a test controls, for driving the 30 s history loop.
///
/// Sampling is synchronous, so the lock exists only to keep the class `Sendable`
/// for the coordinator's executor.
final class ScriptedHistorySampler: BatterySampling, @unchecked Sendable {
    private let lock = NSLock()

    var isACPlugged: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }

    private var stored = false

    func sample(at date: Date) -> BatterySnapshot? {
        BatterySnapshot(
            timestamp: Int64(date.timeIntervalSince1970 * 1000),
            levelPercent: 55,
            capacityMAh: 5_000, designMAh: 6_000, cycleCount: 100,
            voltageMV: 12_700, amperageMA: -800, temperatureC: 28,
            timeRemainingMin: 200,
            isCharging: false, isACPlugged: isACPlugged
        )
    }
}

/// The rule the live layer and the history loop share: one AC transition, one
/// `PowerEvents` row, whoever notices it first.
final class PlugEventRecorderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var baseMillis: Int64 { Int64(base.timeIntervalSince1970 * 1000) }

    private func makeRecorder(_ events: RecorderInbox) -> PlugEventRecorder {
        PlugEventRecorder(write: { event in await events.append(event) })
    }

    func testTheRunsFirstReadingFillsTheLedgerWithoutAWrite() async {
        let inbox = RecorderInbox()
        let recorder = makeRecorder(inbox)

        await recorder.adopt(isACPlugged: true)
        let written = await recorder.record(isACPlugged: true, timestamp: baseMillis + 30_000)
        XCTAssertNil(written)
        let recorded = await recorder.recordedState
        XCTAssertEqual(recorded, true)
        let events = await inbox.written
        XCTAssertTrue(events.isEmpty, "starting the app while plugged in is not a plug event")
    }

    func testAReportedTransitionIsWrittenEvenBeforeTheLedgerHasAState() async {
        let inbox = RecorderInbox()
        let recorder = makeRecorder(inbox)

        // The 30 s loop only calls this when its own two snapshots differ, so a
        // change it reports is a change even if nothing filled the ledger yet.
        let written = await recorder.record(isACPlugged: true, timestamp: baseMillis)
        XCTAssertEqual(written?.type, .plug)
        let events = await inbox.written
        XCTAssertEqual(events.compactMap(\.type), [.plug])
    }

    func testTransitionWritesExactlyOneMarkerAndIdenticalStatesWriteNone() async {
        let inbox = RecorderInbox()
        let recorder = makeRecorder(inbox)

        await recorder.adopt(isACPlugged: false)
        for second in 1...5 {
            let repeated = await recorder.record(
                isACPlugged: false, timestamp: baseMillis + Int64(second * 30_000)
            )
            XCTAssertNil(repeated)
        }

        let plugged = await recorder.record(isACPlugged: true, timestamp: baseMillis + 180_000)
        XCTAssertEqual(plugged?.type, .plug)
        XCTAssertEqual(plugged?.timestamp, baseMillis + 180_000)
        let unplugged = await recorder.record(isACPlugged: false, timestamp: baseMillis + 200_000)
        XCTAssertEqual(unplugged?.type, .unplug)

        let events = await inbox.written
        XCTAssertEqual(events.compactMap(\.type), [.plug, .unplug])
    }

    func testAQuickCycleStillLeavesBothMarkers() async {
        let inbox = RecorderInbox()
        let recorder = makeRecorder(inbox)
        await recorder.adopt(isACPlugged: true)

        await recorder.record(isACPlugged: false, timestamp: baseMillis + 1_000)
        await recorder.record(isACPlugged: true, timestamp: baseMillis + 2_000)

        let events = await inbox.written
        XCTAssertEqual(events.compactMap(\.type), [.unplug, .plug],
                       "a time window would swallow a marker; comparing state does not")
    }

    func testTheTwoPathsNeverWriteTheSameTransitionTwiceInEitherOrder() async {
        // Live layer first, which is what happens with the app running.
        let liveFirst = RecorderInbox()
        let liveFirstRecorder = makeRecorder(liveFirst)
        await liveFirstRecorder.adopt(isACPlugged: false)
        await liveFirstRecorder.record(isACPlugged: true, timestamp: baseMillis + 1_000)
        // The 30 s loop compares against its own previous snapshot, so it still
        // sees a change 30 s later and asks the same recorder.
        await liveFirstRecorder.record(isACPlugged: true, timestamp: baseMillis + 31_000)
        let liveFirstEvents = await liveFirst.written
        XCTAssertEqual(liveFirstEvents.compactMap(\.type), [.plug])

        // History loop first, which is what happens when a notification is missed.
        let historyFirst = RecorderInbox()
        let historyFirstRecorder = makeRecorder(historyFirst)
        await historyFirstRecorder.adopt(isACPlugged: false)
        await historyFirstRecorder.record(isACPlugged: true, timestamp: baseMillis + 30_000)
        await historyFirstRecorder.record(isACPlugged: true, timestamp: baseMillis + 30_500)
        let historyFirstEvents = await historyFirst.written
        XCTAssertEqual(historyFirstEvents.compactMap(\.type), [.plug])
    }

    // MARK: - Against the real database

    func testSamplingLoopSkipsAMarkerTheLiveLayerAlreadyWrote() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let recorder = PlugEventRecorder(database: db)
        await recorder.adopt(isACPlugged: false)

        let sampler = ScriptedHistorySampler()
        let coordinator = SamplingCoordinator(database: db, batterySampler: sampler, plugEvents: recorder)
        await coordinator.runBatteryTick(at: base)
        await coordinator.runBatteryTick(at: base.addingTimeInterval(30))

        // The live layer handles the notification, then the next history row
        // compares against the row before it and still sees a change.
        let marker = await recorder.record(isACPlugged: true, timestamp: baseMillis + 45_000)
        XCTAssertEqual(marker?.type, .plug)
        sampler.isACPlugged = true
        await coordinator.runBatteryTick(at: base.addingTimeInterval(60))

        let events = try await rows(db, "SELECT eventType FROM PowerEvents ORDER BY timestamp")
        XCTAssertEqual(events, ["plug"], "one transition, one row")
        let batteryRows = try await count(db, "SELECT COUNT(*) FROM BatteryStatus")
        XCTAssertEqual(batteryRows, 3, "the 30 s history row per tick is unchanged")
    }

    func testSamplingLoopStillWritesAMarkerWithoutTheLiveLayer() async throws {
        let db = try HistoryDatabase.makeInMemory()
        let sampler = ScriptedHistorySampler()
        let coordinator = SamplingCoordinator(database: db, batterySampler: sampler)
        await coordinator.runBatteryTick(at: base)
        await coordinator.runBatteryTick(at: base.addingTimeInterval(30))
        sampler.isACPlugged = true
        await coordinator.runBatteryTick(at: base.addingTimeInterval(60))

        let events = try await rows(db, "SELECT eventType FROM PowerEvents ORDER BY timestamp")
        XCTAssertEqual(events, ["plug"], "the fallback path still records a transition")
        let batteryRows = try await count(db, "SELECT COUNT(*) FROM BatteryStatus")
        XCTAssertEqual(batteryRows, 3)
    }

    private func rows(_ db: HistoryDatabase, _ sql: String) async throws -> [String] {
        try await db.dbPool.read { conn in try String.fetchAll(conn, sql: sql) }
    }

    private func count(_ db: HistoryDatabase, _ sql: String) async throws -> Int {
        try await db.dbPool.read { conn in try Int.fetchOne(conn, sql: sql) ?? 0 }
    }
}

/// Captures what a recorder wrote, in order.
actor RecorderInbox {
    private var stored: [PowerEvent] = []

    func append(_ event: PowerEvent) { stored.append(event) }

    var written: [PowerEvent] { stored }
}
