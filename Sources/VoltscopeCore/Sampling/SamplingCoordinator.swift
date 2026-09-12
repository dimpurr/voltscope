import Foundation

public actor SamplingCoordinator {
    public static let processInterval: TimeInterval = 5.0
    public static let batteryInterval: TimeInterval = 30.0
    public static let walCheckpointInterval: TimeInterval = 300.0

    private let database: AppDatabase
    private let processSampler: ProcessSampler
    private let batterySampler: BatterySampler
    private let bucketSampler: BucketSampler

    private var processTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    private var bucketTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var isRunning = false

    /// Held to detect AC source / charging-state transitions so we can emit
    /// `PowerEvents` rows alongside the battery snapshot stream.
    private var lastBatterySnapshot: BatterySnapshot?

    public init(
        database: AppDatabase,
        processSampler: ProcessSampler = ProcessSampler(),
        batterySampler: BatterySampler = BatterySampler(),
        bucketSampler: BucketSampler = BucketSampler()
    ) {
        self.database = database
        self.processSampler = processSampler
        self.batterySampler = batterySampler
        self.bucketSampler = bucketSampler
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        processTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // Prime the sampler so the first row carries a real delta rather than zero.
            _ = await self.runProcessTick(emit: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.processInterval * 1_000_000_000))
                await self.runProcessTick(emit: true)
            }
        }

        batteryTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runBatteryTick()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.batteryInterval * 1_000_000_000))
                await self.runBatteryTick()
            }
        }

        checkpointTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.walCheckpointInterval * 1_000_000_000))
                await self.runWALCheckpointTick()
            }
        }

        bucketTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // Prime the bucket sampler so the first emitted row carries a real
            // delta rather than the initial baseline (which is always empty).
            _ = await self.runBucketTick(emit: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.processInterval * 1_000_000_000))
                await self.runBucketTick(emit: true)
            }
        }
    }

    public func stop() {
        processTask?.cancel()
        batteryTask?.cancel()
        bucketTask?.cancel()
        checkpointTask?.cancel()
        processTask = nil
        batteryTask = nil
        bucketTask = nil
        checkpointTask = nil
        isRunning = false
    }

    public func recordEvent(_ event: PowerEvent) async {
        do { try await database.writePowerEvent(event) }
        catch { logError("PowerEvent insert failed: \(error)") }
    }

    @discardableResult
    private func runProcessTick(emit: Bool) async -> Int {
        let samples = processSampler.sampleAll()
        guard emit, !samples.isEmpty else { return 0 }
        do {
            try await database.writeBatchSamples(samples)
        } catch {
            logError("EnergySample batch insert failed: \(error)")
        }
        return samples.count
    }

    private func runBatteryTick() async {
        guard let snapshot = batterySampler.sample() else { return }
        do {
            try await database.writeBatterySnapshot(snapshot)
        } catch {
            logError("BatterySnapshot insert failed: \(error)")
        }
        await emitTransitionEvents(for: snapshot)
        lastBatterySnapshot = snapshot
    }

    private func runWALCheckpointTick() async {
        do {
            try await database.runWALCheckpoint()
        } catch {
            logError("WAL checkpoint failed: \(error)")
        }
    }

    @discardableResult
    private func runBucketTick(emit: Bool) async -> Int {
        let rows = bucketSampler.sample()
        guard emit, !rows.isEmpty else { return 0 }
        do {
            try await database.writeBatchBuckets(rows)
        } catch {
            logError("SystemBucket batch insert failed: \(error)")
        }
        return rows.count
    }

    private func emitTransitionEvents(for current: BatterySnapshot) async {
        guard let previous = lastBatterySnapshot else { return }
        if previous.isACPlugged != current.isACPlugged {
            let event = PowerEvent(
                timestamp: current.timestamp,
                eventType: current.isACPlugged ? .plug : .unplug
            )
            do { try await database.writePowerEvent(event) }
            catch { logError("AC PowerEvent insert failed: \(error)") }
        }
    }

    private nonisolated func logError(_ message: String) {
        FileHandle.standardError.write(Data("[Voltscope] \(message)\n".utf8))
    }
}
