import Foundation
import Darwin
import VoltscopeC
#if canImport(AppKit)
import AppKit
#endif

public struct ProcessSnapshot: Sendable, Equatable {
    public let pid: Int32
    public let parentPid: Int32?
    public let bundleIdentifier: String?
    public let processName: String
    public let path: String?
    public let cpuUserNs: UInt64
    public let cpuSystemNs: UInt64
    public let energyTotal: UInt64       // ri_billed_energy (cumulative since process start)
    public let wakeupsTotal: UInt64      // pkg_idle + interrupt
    public let diskReadTotal: UInt64
    public let diskWriteTotal: UInt64
    public let procStartAbstime: UInt64  // serves as a process-identity hash to detect PID reuse
}

public final class ProcessSampler: @unchecked Sendable {
    /// Previous-tick cumulative state, keyed by (pid, procStartAbstime).
    /// We key on procStartAbstime as well to defend against PID reuse within
    /// the sampling window — if the start time changes, we treat it as a new process.
    private struct ProcessKey: Hashable {
        let pid: Int32
        let startAbstime: UInt64
    }

    private var previous: [ProcessKey: ProcessSnapshot] = [:]
    private let queue = DispatchQueue(label: "com.dimpurr.voltscope.processsampler")

    public init() {}

    /// Samples all visible processes once and returns one EnergySample row per process,
    /// with values representing the *delta* since the previous sample (or zero on first sight).
    public func sampleAll(at date: Date = Date()) -> [EnergySample] {
        queue.sync {
            let snapshots = readAllProcesses()
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

            var nextPrevious: [ProcessKey: ProcessSnapshot] = [:]
            nextPrevious.reserveCapacity(snapshots.count)

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
                    minute: minute
                ) {
                    output.append(row)
                }
            }

            previous = nextPrevious
            return output
        }
    }

    /// Pure delta rule for one process between two consecutive snapshots.
    ///
    /// Returns `nil` when the interval billed no new CPU energy to the process.
    /// `ri_billed_energy` is coarse-grained and only credited in whole units, so
    /// most of the 300–500 processes in the roster report an unchanged
    /// cumulative counter on any given tick. Emitting those rows produced the
    /// overwhelming majority of historical storage growth while contributing
    /// nothing to the energy-based History queries, which sum energy or filter
    /// with `energy > 0`.
    ///
    /// `prior == nil` is the first-sighting case: the process has no baseline
    /// yet, so nothing is emitted and the caller only records the snapshot.
    /// A regressed counter (`current < previous`, e.g. after PID reuse) is
    /// clamped to a zero delta and therefore also yields `nil`; the caller still
    /// advances its baseline. CPU, wakeup, and disk deltas are reported only on
    /// rows that carry energy, and no other field's meaning changes.
    static func deltaSample(
        from prior: ProcessSnapshot?,
        to current: ProcessSnapshot,
        timestamp: Int64,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> EnergySample? {
        guard let prior else { return nil }

        let energyDelta = saturatingDelta(current.energyTotal, prior.energyTotal)
        guard energyDelta > 0 else { return nil }

        // Compute non-negative deltas; counters are monotonic but we clamp defensively.
        let wakeupsDelta = saturatingDelta(current.wakeupsTotal, prior.wakeupsTotal)
        let diskReadDelta = saturatingDelta(current.diskReadTotal, prior.diskReadTotal)
        let diskWriteDelta = saturatingDelta(current.diskWriteTotal, prior.diskWriteTotal)
        let cpuUserDelta = saturatingDelta(current.cpuUserNs, prior.cpuUserNs)
        let cpuSystemDelta = saturatingDelta(current.cpuSystemNs, prior.cpuSystemNs)

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

    private func readAllProcesses() -> [ProcessSnapshot] {
        let pids = listAllPids()
        var results: [ProcessSnapshot] = []
        results.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard let snap = readSnapshot(for: pid) else { continue }
            results.append(snap)
        }
        return results
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
        let count = Int(bytesWritten) / MemoryLayout<pid_t>.stride
        return Array(buffer.prefix(count))
    }

    private func readSnapshot(for pid: pid_t) -> ProcessSnapshot? {
        var info = rusage_info_v6()
        let result = voltscope_proc_pid_rusage_v6(pid, &info)
        guard result == 0 else { return nil }

        let identity = resolveIdentity(pid: pid)
        let ppidRaw = voltscope_get_parent_pid(pid)
        let parentPid: Int32? = ppidRaw > 0 ? Int32(ppidRaw) : nil

        return ProcessSnapshot(
            pid: pid,
            parentPid: parentPid,
            bundleIdentifier: identity.bundleId,
            processName: identity.name,
            path: identity.path,
            cpuUserNs: info.ri_user_time,
            cpuSystemNs: info.ri_system_time,
            energyTotal: info.ri_billed_energy,
            wakeupsTotal: info.ri_pkg_idle_wkups &+ info.ri_interrupt_wkups,
            diskReadTotal: info.ri_diskio_bytesread,
            diskWriteTotal: info.ri_diskio_byteswritten,
            procStartAbstime: info.ri_proc_start_abstime
        )
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
