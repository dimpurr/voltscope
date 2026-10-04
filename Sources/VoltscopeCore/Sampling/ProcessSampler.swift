import Foundation
import Darwin
import VoltscopeC
#if canImport(AppKit)
import AppKit
#endif

/// Result of one ProcessSampler tick: the delta rows plus coverage counts.
public struct ProcessSampleResult: Sendable {
    /// One EnergySample delta row per process that had measurable activity.
    public let samples: [EnergySample]
    /// Number of processes successfully read via proc_pid_rusage this tick.
    public let visibleCount: Int
    /// Number of processes skipped because proc_pid_rusage returned EPERM.
    public let unreadableCount: Int
    /// Resolved identities for this tick, keyed by PID. Metadata is cached by
    /// PID and process start time before this lightweight lookup is produced.
    public let identitiesByPID: [Int32: AppIdentity.Resolved]
}

final class ProcessSamplingCheckpoint: @unchecked Sendable {
    private let restoreState: () -> Void

    init(restoreState: @escaping () -> Void) { self.restoreState = restoreState }

    func restore() { restoreState() }
}

public struct ProcessSnapshot: Sendable, Equatable {
    public let pid: Int32
    public let parentPid: Int32?
    public let bundleIdentifier: String?
    public let processName: String
    public let path: String?
    public let cpuUserNs: UInt64
    public let cpuSystemNs: UInt64
    /// Cumulative DPE-estimated energy in nanojoules for this task, from
    /// ri_energy_nj (recount/context-switch accounting). On Intel this field
    /// is always 0 because there is no per-CPU DPE counter (see energyAvailable).
    public let energyTotal: UInt64
    public let wakeupsTotal: UInt64
    public let diskReadTotal: UInt64
    public let diskWriteTotal: UInt64
    public let procStartAbstime: UInt64  // serves as a process-identity hash to detect PID reuse
}

public final class ProcessSampler: @unchecked Sendable {
    typealias SnapshotReader = @Sendable () -> (snapshots: [ProcessSnapshot], unreadableCount: Int)

    /// Last successful cumulative state, keyed by (pid, procStartAbstime).
    /// A baseline survives up to two missed scans, and a changed start time is
    /// treated as a new process to defend against PID reuse.
    private struct ProcessKey: Hashable {
        let pid: Int32
        let startAbstime: UInt64
    }

    struct MetadataKey: Hashable {
        let pid: Int32
        let startAbstime: UInt64
    }

    struct ProcessMetadata: Equatable {
        let comm: String
        let name: String
        let path: String?
        let bundleId: String?
        let resolvedIdentity: AppIdentity.Resolved
    }

    struct TickMetadata {
        let process: ProcessMetadata
        let parentPid: Int32?
    }

    struct MetadataCache<Key: Hashable, Value> {
        private(set) var values: [Key: Value] = [:]
        private var insertionOrder: [Key] = []
        let capacity: Int

        init(capacity: Int = 4_096) { self.capacity = max(0, capacity) }

        func value(for key: Key) -> Value? { values[key] }

        mutating func insert(_ value: Value, for key: Key) {
            guard capacity > 0 else { return }
            if values[key] == nil { insertionOrder.append(key) }
            values[key] = value
            while insertionOrder.count > capacity {
                values.removeValue(forKey: insertionOrder.removeFirst())
            }
        }

        mutating func retain(_ activeKeys: Set<Key>) {
            values = values.filter { activeKeys.contains($0.key) }
            insertionOrder.removeAll { !activeKeys.contains($0) }
        }

        mutating func removeValue(for key: Key) {
            values.removeValue(forKey: key)
            insertionOrder.removeAll { $0 == key }
        }
    }

    static func metadataForTick(
        key: MetadataKey,
        comm: String?,
        parentPid: Int32?,
        cache: inout MetadataCache<MetadataKey, ProcessMetadata>,
        resolve: () -> ProcessMetadata
    ) -> TickMetadata {
        if let comm, let cached = cache.value(for: key), cached.comm == comm {
            return TickMetadata(process: cached, parentPid: parentPid)
        }

        cache.removeValue(for: key)
        let metadata = resolve()
        if comm != nil && metadata.path != nil && !isFallbackProcessName(metadata.name) {
            cache.insert(metadata, for: key)
        }
        return TickMetadata(process: metadata, parentPid: parentPid)
    }

    static func isFallbackProcessName(_ name: String) -> Bool {
        let parts = name.split(separator: " ")
        return parts.count == 2 && parts[0] == "pid" && Int32(parts[1]) != nil
    }

    static func processStartMatches(_ expected: UInt64, _ observed: UInt64) -> Bool {
        expected == observed
    }

    private var metadataCache = MetadataCache<MetadataKey, ProcessMetadata>()

    private var previous: [ProcessKey: ProcessSnapshot] = [:]
    private var missedScans: [ProcessKey: Int] = [:]
    private let queue = DispatchQueue(label: "com.dimpurr.voltscope.processsampler")
    private let snapshotReader: SnapshotReader?
    private static let maximumMissedScans = 2

    /// Cached mach_timebase_info read once at init. Used to convert
    /// ri_user_time / ri_system_time (mach absolute time units) to nanoseconds.
    /// Formula: ns = ticks × numer / denom.
    /// On Apple Silicon: numer=125, denom=3 (verified: selftest2 in W1 probe).
    /// On Intel: numer=1, denom=1 (mach absolute time equals ns).
    private let timebaseNumer: UInt32
    private let timebaseDenom: UInt32

    /// True on Apple Silicon (or any SoC with CONFIG_PERVASIVE_ENERGY +
    /// HAS_CPU_DPE_COUNTER); false on Intel where ri_energy_nj is always 0.
    /// Determined once at init by reading kern.pervasive_energy sysctl.
    public let energyAvailable: Bool

    /// Captures the last committed counter baseline so a rejected database
    /// tick can be replayed from cumulative counters on the next scan.
    func makeCheckpoint() -> ProcessSamplingCheckpoint {
        let state = queue.sync { (previous, missedScans, metadataCache) }
        return ProcessSamplingCheckpoint { [weak self] in
            guard let self else { return }
            self.queue.sync {
                self.previous = state.0
                self.missedScans = state.1
                self.metadataCache = state.2
            }
        }
    }

    public init() {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.pervasive_energy", &value, &size, nil, 0)
        self.energyAvailable = (value == 1)
        self.snapshotReader = nil

        var tb = mach_timebase_info(numer: 1, denom: 1)
        mach_timebase_info(&tb)
        self.timebaseNumer = tb.numer
        self.timebaseDenom = tb.denom
    }

    init(energyAvailable: Bool, snapshotReader: @escaping SnapshotReader) {
        self.energyAvailable = energyAvailable
        self.snapshotReader = snapshotReader
        var tb = mach_timebase_info(numer: 1, denom: 1)
        mach_timebase_info(&tb)
        self.timebaseNumer = tb.numer
        self.timebaseDenom = tb.denom
    }

    /// Samples all visible processes once and returns a `ProcessSampleResult`
    /// containing delta rows plus coverage counts for this tick.
    ///
    /// - Delta rows represent the change since the previous sample (zero on first sight).
    /// - `visibleCount` counts processes successfully read by proc_pid_rusage.
    /// - `unreadableCount` counts processes where proc_pid_rusage failed with EPERM.
    public func sampleAll(at date: Date = Date()) -> ProcessSampleResult {
        queue.sync {
            let (snapshots, unreadableCount) = snapshotReader?() ?? readAllProcesses()
            let timestamp = Int64(date.timeIntervalSince1970 * 1000)
            let calendar = Calendar(identifier: .gregorian)
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let year = comps.year ?? 0
            let month = comps.month ?? 0
            let day = comps.day ?? 0
            let hour = comps.hour ?? 0
            let minute = comps.minute ?? 0

            var output: [EnergySample] = []
            output.reserveCapacity(snapshots.count)
            var identitiesByPID: [Int32: AppIdentity.Resolved] = [:]
            identitiesByPID.reserveCapacity(min(snapshots.count, 512))

            var nextPrevious: [ProcessKey: ProcessSnapshot] = [:]
            nextPrevious.reserveCapacity(snapshots.count)
            var nextMissedScans: [ProcessKey: Int] = [:]
            let observedKeys = Set(snapshots.map { ProcessKey(pid: $0.pid, startAbstime: $0.procStartAbstime) })

            for (key, prior) in previous where !observedKeys.contains(key) {
                let missed = missedScans[key, default: 0] + 1
                if missed <= Self.maximumMissedScans {
                    nextPrevious[key] = prior
                    nextMissedScans[key] = missed
                }
            }

            for snap in snapshots {
                let key = ProcessKey(pid: snap.pid, startAbstime: snap.procStartAbstime)
                // Always record the latest snapshot: the baseline advances even
                // when the process emits no row this interval.
                nextPrevious[key] = snap

                if let row = Self.deltaSample(
                    from: previous[key],
                    to: snap,
                    timestamp: timestamp,
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute,
                    energyAvailable: energyAvailable
                ) {
                    output.append(row)
                    let metadataKey = MetadataKey(pid: snap.pid, startAbstime: snap.procStartAbstime)
                    identitiesByPID[snap.pid] = metadataCache.value(for: metadataKey)?.resolvedIdentity
                }
            }

            previous = nextPrevious
            missedScans = nextMissedScans
            // Keep metadata alongside counter baselines during the two-scan
            // grace period; otherwise a transient unreadable scan would force
            // identity resolution again when the same process becomes readable.
            let activeMetadataKeys = Set(nextPrevious.keys.map {
                MetadataKey(pid: $0.pid, startAbstime: $0.startAbstime)
            })
            metadataCache.retain(activeMetadataKeys)
            return ProcessSampleResult(
                samples: output,
                visibleCount: snapshots.count,
                unreadableCount: unreadableCount,
                identitiesByPID: identitiesByPID
            )
        }
    }

    /// Pure delta rule for one process between two consecutive snapshots.
    ///
    /// Returns `nil` when the interval reports no measurable activity for the process.
    /// `ri_energy_nj` is cumulative hardware-estimated energy, so
    /// most of the 300–500 processes in the roster report an unchanged
    /// cumulative counter on any given tick. Emitting those rows produced the
    /// overwhelming majority of historical storage growth while contributing
    /// nothing to the energy-based History queries, which sum energy or filter
    /// with `energy > 0`. On platforms without this counter, CPU time is the
    /// activity signal and CPU-active rows are retained with zero energy.
    ///
    /// `prior == nil` is the first-sighting case: the process has no baseline
    /// yet, so nothing is emitted and the caller only records the snapshot.
    /// A regressed counter (`current < previous`, e.g. after PID reuse) is
    /// clamped to a zero delta and therefore also yields `nil`; the caller still
    /// advances its baseline. CPU, wakeup, and disk deltas are reported on
    /// retained rows.
    static func deltaSample(
        from prior: ProcessSnapshot?,
        to current: ProcessSnapshot,
        timestamp: Int64,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        energyAvailable: Bool = true
    ) -> EnergySample? {
        guard let prior else { return nil }

        let energyDelta = saturatingDelta(current.energyTotal, prior.energyTotal)
        // Compute non-negative deltas; counters are monotonic but we clamp defensively.
        let wakeupsDelta = saturatingDelta(current.wakeupsTotal, prior.wakeupsTotal)
        let diskReadDelta = saturatingDelta(current.diskReadTotal, prior.diskReadTotal)
        let diskWriteDelta = saturatingDelta(current.diskWriteTotal, prior.diskWriteTotal)
        let cpuUserDelta = saturatingDelta(current.cpuUserNs, prior.cpuUserNs)
        let cpuSystemDelta = saturatingDelta(current.cpuSystemNs, prior.cpuSystemNs)
        guard energyAvailable ? energyDelta > 0 : (cpuUserDelta > 0 || cpuSystemDelta > 0) else { return nil }

        return EnergySample(
            timestamp: timestamp,
            pid: current.pid,
            bundleIdentifier: current.bundleIdentifier,
            processName: current.processName,
            path: current.path,
            parentPid: current.parentPid,
            cpuUserNs: Int64(clamping: cpuUserDelta),
            cpuSystemNs: Int64(clamping: cpuSystemDelta),
            energyNJ: Int64(clamping: energyDelta),
            wakeups: Int64(clamping: wakeupsDelta),
            diskReadBytes: Int64(clamping: diskReadDelta),
            diskWriteBytes: Int64(clamping: diskWriteDelta),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    }

    // MARK: - Internal: enumerate PIDs and read rusage

    /// Returns all successfully-read snapshots plus a count of unreadable processes.
    private func readAllProcesses() -> (snapshots: [ProcessSnapshot], unreadableCount: Int) {
        let pids = listAllPids()
        var results: [ProcessSnapshot] = []
        results.reserveCapacity(pids.count)
        var errors: [Int32] = []

        for pid in pids where pid > 0 {
            var errorNumber: Int32 = 0
            if let snap = readSnapshot(for: pid, errorNumber: &errorNumber) {
                results.append(snap)
            } else {
                errors.append(errorNumber)
            }
        }
        return (results, Self.unreadableCount(forErrors: errors))
    }

    private func listAllPids() -> [Int32] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        // Add headroom — process count can grow between the two calls.
        let capacity = Int(needed) + 32
        var buffer = [pid_t](repeating: 0, count: capacity)
        let bytesWritten = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            let bufSize = Int32(ptr.count * MemoryLayout<pid_t>.stride)
            return proc_listallpids(ptr.baseAddress, bufSize)
        }
        guard bytesWritten > 0 else { return [] }
        let count = Self.pidCount(fromProcListAllPids: bytesWritten)
        return Array(buffer.prefix(count))
    }

    static func pidCount(fromProcListAllPids returnValue: Int32) -> Int {
        max(0, Int(returnValue))
    }

    static func isUnreadableError(_ errorNumber: Int32) -> Bool {
        errorNumber == EPERM
    }

    static func unreadableCount(forErrors errors: [Int32]) -> Int {
        errors.filter(isUnreadableError).count
    }

    private func readSnapshot(for pid: pid_t, errorNumber: inout Int32) -> ProcessSnapshot? {
        var info = rusage_info_v6()
        let result = voltscope_proc_pid_rusage_v6(pid, &info)
        guard result == 0 else {
            errorNumber = errno
            return nil
        }

        let metadataKey = MetadataKey(pid: Int32(pid), startAbstime: info.ri_proc_start_abstime)
        var ppidRaw: Int32 = -1
        var commandBuffer = [CChar](repeating: 0, count: 32)
        let processInfoResult = commandBuffer.withUnsafeMutableBufferPointer { buffer in
            voltscope_get_process_info(pid, &ppidRaw, buffer.baseAddress, buffer.count)
        }
        let parentPid = processInfoResult == 0 && ppidRaw > 0 ? ppidRaw : nil
        let comm: String? = processInfoResult == 0
            ? commandBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            : nil
        let tickMetadata = Self.metadataForTick(
            key: metadataKey,
            comm: comm,
            parentPid: parentPid,
            cache: &metadataCache
        ) {
            let identity = resolveIdentity(pid: pid)
            let resolvedIdentity = AppIdentity.resolve(bundleIdentifier: identity.bundleId,
                                                       processName: identity.name, path: identity.path)
            return ProcessMetadata(comm: comm ?? identity.name, name: identity.name, path: identity.path,
                                   bundleId: identity.bundleId, resolvedIdentity: resolvedIdentity)
        }
        var verifiedInfo = rusage_info_v6()
        guard voltscope_proc_pid_rusage_v6(pid, &verifiedInfo) == 0 else {
            errorNumber = errno
            metadataCache.removeValue(for: metadataKey)
            return nil
        }
        guard Self.processStartMatches(info.ri_proc_start_abstime, verifiedInfo.ri_proc_start_abstime) else {
            metadataCache.removeValue(for: metadataKey)
            return nil
        }
        let metadata = tickMetadata.process

        // ri_user_time and ri_system_time are in mach absolute time units.
        // Multiply by timebaseNumer/timebaseDenom to convert to nanoseconds.
        // Apple Silicon: 125/3 (~41.7ns per tick). Intel: 1/1 (already ns).
        // Source: W1 selftest2 output (getrusage 2.990s vs ri_user_time 0.072s = 41.7×).
        let cpuUserNs = Self.timebaseNanoseconds(info.ri_user_time, numer: timebaseNumer, denom: timebaseDenom)
        let cpuSystemNs = Self.timebaseNanoseconds(info.ri_system_time, numer: timebaseNumer, denom: timebaseDenom)

        return ProcessSnapshot(
            pid: pid,
            parentPid: tickMetadata.parentPid,
            bundleIdentifier: metadata.bundleId,
            processName: metadata.name,
            path: metadata.path,
            cpuUserNs: cpuUserNs,
            cpuSystemNs: cpuSystemNs,
            energyTotal: Self.energyTotal(from: info),
            wakeupsTotal: info.ri_pkg_idle_wkups &+ info.ri_interrupt_wkups,
            diskReadTotal: info.ri_diskio_bytesread,
            diskWriteTotal: info.ri_diskio_byteswritten,
            procStartAbstime: info.ri_proc_start_abstime
        )
    }

    static func energyTotal(from info: rusage_info_v6) -> UInt64 {
        info.ri_energy_nj
    }

    /// Converts a mach absolute time value to nanoseconds using the cached timebase.
    static func timebaseNanoseconds(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        // Avoid overflow: ticks * numer may exceed UInt64 on long-running processes.
        // Use UInt128-equivalent via two-step 64-bit arithmetic with saturation.
        if numer == denom { return ticks }
        // Safe wide multiplication: split into high/low 32-bit halves.
        let hi = UInt64(ticks >> 32) * UInt64(numer)
        let lo = UInt64(ticks & 0xFFFF_FFFF) * UInt64(numer)
        let combined = (hi << 32) &+ lo
        return combined / UInt64(denom)
    }

    private struct Identity {
        var name: String
        var path: String?
        var bundleId: String?
    }

    private func resolveIdentity(pid: pid_t) -> Identity {
        #if canImport(AppKit)
        // 1. NSRunningApplication — gives us bundle ID + localized name + path for GUI app processes.
        if let app = NSRunningApplication(processIdentifier: pid) {
            let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
            let path = app.bundleURL?.path ?? app.executableURL?.path
            return Identity(name: name, path: path, bundleId: app.bundleIdentifier)
        }
        #endif

        // 2. proc_pidpath fallback — works for any process under our UID.
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN = 4 * 1024; the macro is not exported to Swift.
        let pathCapacity = 4 * 1024
        var pathBuffer = [CChar](repeating: 0, count: pathCapacity)
        let written = pathBuffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_pidpath(pid, ptr.baseAddress, UInt32(pathCapacity))
        }
        if written > 0 {
            let path = pathBuffer.withUnsafeBufferPointer { ptr -> String in
                guard let base = ptr.baseAddress else { return "" }
                return String(cString: base)
            }
            let name = (path as NSString).lastPathComponent
            // 3. Some helper-process executables sit *inside* an app bundle — derive the bundle ID
            //    from the enclosing .app/Contents/Info.plist if we can find one in the path.
            let bundleId = bundleIdentifier(forExecutablePath: path)
            return Identity(
                name: name.isEmpty ? "pid \(pid)" : name,
                path: path,
                bundleId: bundleId
            )
        }
        return Identity(name: "pid \(pid)", path: nil, bundleId: nil)
    }

    /// Walks up the path looking for a `*.app` ancestor and returns its `CFBundleIdentifier`.
    /// Lets us catch helper executables like `Chrome.app/Contents/Frameworks/Chrome Helper.app/Contents/MacOS/Chrome Helper`
    /// and roll them up under the parent app bundle.
    private func bundleIdentifier(forExecutablePath path: String) -> String? {
        #if canImport(AppKit)
        var url = URL(fileURLWithPath: path)
        // Walk up at most 8 levels to find a .app.
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                if let bundle = Bundle(url: url) {
                    return bundle.bundleIdentifier
                }
                return nil
            }
            if url.path == "/" || url.path.isEmpty { break }
        }
        #endif
        return nil
    }

    static func saturatingDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current &- previous : 0
    }
}
