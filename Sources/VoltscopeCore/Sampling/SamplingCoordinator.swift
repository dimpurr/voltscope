import Foundation

public actor SamplingCoordinator {
    public static let processInterval: TimeInterval = 5.0
    public static let batteryInterval: TimeInterval = 30.0
    public static let walCheckpointInterval: TimeInterval = 300.0
    public static let partialWindowFlushInterval: TimeInterval = 15.0

    private let database: HistoryDatabase
    private let processSampler: ProcessSampler
    private let batterySampler: BatterySampler
    private let bucketSampler: BucketSampler

    /// Most recent process sampling coverage.
    public private(set) var latestProcessCoverage: ProcessCoverage?

    /// Whether this platform exposes per-process DPE energy counters.
    public var processEnergyAvailable: Bool { processSampler.energyAvailable }

    private var processTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    private var bucketTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var partialWindowFlushTask: Task<Void, Never>?
    private var isRunning = false

    /// Held to detect AC source / charging-state transitions so we can emit
    /// `PowerEvents` rows alongside the battery snapshot stream.
    private var lastBatterySnapshot: BatterySnapshot?

    public init(
        database: HistoryDatabase,
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

        partialWindowFlushTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.partialWindowFlushInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self.flushPartialWindow()
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

    public func stop() async -> Bool {
        let tasks = [processTask, batteryTask, bucketTask, checkpointTask, partialWindowFlushTask]
        tasks.forEach { $0?.cancel() }
        for task in tasks { await task?.value }
        processTask = nil
        batteryTask = nil
        bucketTask = nil
        checkpointTask = nil
        partialWindowFlushTask = nil
        isRunning = false
        do { try await database.flushPendingWindow() }
        catch {
            logError("History window flush failed during shutdown: \(error)")
            return false
        }
        return true
    }

    public func recordEvent(_ event: PowerEvent) async {
        if event.type == .sleep { await flushPartialWindow() }
        do { try await database.writePowerEvent(event) }
        catch { logError("PowerEvent insert failed: \(error)") }
    }

    private func flushPartialWindow() async {
        do { try await database.flushPendingWindow() }
        catch { logError("History window flush failed: \(error)") }
    }

    @discardableResult
    func runProcessTick(emit: Bool, at date: Date = Date()) async -> Int {
        let checkpoint = emit ? processSampler.makeCheckpoint() : nil
        let result = processSampler.sampleAll(at: date)
        latestProcessCoverage = ProcessCoverage(
            visibleCount: result.visibleCount,
            unreadableCount: result.unreadableCount
        )
        guard emit else { return 0 }
        do {
            let apps = result.samples.map { sample in
                let identity = result.identitiesByPID[sample.pid] ?? AppIdentity.resolve(
                    bundleIdentifier: sample.bundleIdentifier,
                    processName: sample.processName,
                    path: sample.path
                )
                return SampledApp(
                    groupKey: identity.groupKey,
                    bundleIdentifier: sample.bundleIdentifier,
                    displayName: identity.displayName,
                    path: sample.path,
                    pid: sample.pid,
                    parentPid: sample.parentPid,
                    energyNJ: sample.energyNJ,
                    cpuNs: sample.cpuUserNs + sample.cpuSystemNs,
                    wakeups: sample.wakeups,
                    diskReadBytes: sample.diskReadBytes,
                    diskWriteBytes: sample.diskWriteBytes
                )
            }
            try await database.writeTick(
                timestamp: result.samples.first?.timestamp ?? Int64(date.timeIntervalSince1970 * 1000),
                apps: apps,
                buckets: [],
                coverage: SampleCoverage(visible: Int64(result.visibleCount), unreadable: Int64(result.unreadableCount)),
                metricVersion: EnergyMetric.currentVersion,
                energyUnavailable: !processEnergyAvailable
            )
        } catch {
            if let checkpoint,
               let bufferError = error as? HistoryWindowBufferError,
               case .pendingLimitReached = bufferError {
                checkpoint.restore()
            }
            logError("History tick insert failed: \(error)")
        }
        return result.samples.count
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
            try await database.runMaintenance()
        } catch {
            logError("History maintenance failed: \(error)")
        }
    }

    @discardableResult
    func runBucketTick(emit: Bool, at date: Date = Date()) async -> Int {
        let checkpoint = emit ? bucketSampler.makeCheckpoint() : nil
        let rows = bucketSampler.sample(at: date)
        guard emit, !rows.isEmpty else { return 0 }
        // The hardware sampler has its own counter baseline and writes its
        // bucket deltas to the same history store.
        do { try await database.writeBuckets(timestamp: rows[0].timestamp, buckets: rows.map { SampledBucket(name: $0.bucketName, energyNJ: $0.energyNJ) }) }
        catch {
            if let checkpoint,
               let bufferError = error as? HistoryWindowBufferError,
               case .pendingLimitReached = bufferError {
                checkpoint.restore()
            }
            logError("History bucket insert failed: \(error)")
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

public struct ProcessCoverage: Equatable, Sendable {
    public let visibleCount: Int
    public let unreadableCount: Int

    public init(visibleCount: Int, unreadableCount: Int) {
        self.visibleCount = visibleCount
        self.unreadableCount = unreadableCount
    }
}
