import Foundation
import CoreFoundation

/// Subscribes to the IOReport "Energy Model" group and emits per-bucket
/// energy deltas every tick. Channels typically include CPU Energy
/// (per cluster), GPU Energy, ANE Energy, DRAM Energy on Apple Silicon —
/// the exact channel set varies by chip generation, so we surface whatever
/// IOReport reports instead of hardcoding names.
///
/// On non–Apple Silicon or if private API loading fails, `available` returns
/// false and `sample()` returns []. The UI surfaces this gracefully.
public final class BucketSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dimpurr.voltscope.bucketsampler")
    // Framework path (works on macOS 13–15)
    private var subscription: CFTypeRef?
    private var subbedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var setupAttempted = false
    private var setupSucceeded = false
    // IOConnect path (works on macOS 26+ where the framework is gone, and
    // also on 13–15 as a backup; preferred when framework is unavailable)
    private let connectSampler = IOReportConnectSampler()

    public init() {}

    public var available: Bool { setupSucceeded || connectSampler.available }

    /// Group of channels exposed by the system Energy Model on Apple Silicon.
    private static let energyModelGroup: String = "Energy Model"

    /// Returns the per-bucket energy delta rows for the interval since the
    /// previous call (or [] for the first call, which only baselines).
    /// Tries the IOReport.framework path first (macOS 13–15) and falls back
    /// to the IOConnect path (works on every Apple Silicon macOS including 26+).
    public func sample(at date: Date = Date()) -> [SystemBucket] {
        if let frameworkRows = sampleViaFramework(at: date), !frameworkRows.isEmpty {
            return frameworkRows
        }
        return connectSampler.sample(at: date)
    }

    /// Framework-based sampler. Returns nil when IOReport.framework hasn't
    /// resolved (e.g. macOS 26+) so the caller knows to try the IOConnect
    /// path; returns [] when the framework loaded but produced no rows
    /// this tick.
    private func sampleViaFramework(at date: Date) -> [SystemBucket]? {
        queue.sync {
            ensureSetup()
            guard setupSucceeded,
                  let subscription = subscription,
                  let subbed = subbedChannels,
                  let createSamples = IOReport_CreateSamples,
                  let createDelta = IOReport_CreateSamplesDelta,
                  let getValue = IOReport_SimpleGetIntegerValue,
                  let getName = IOReport_ChannelGetChannelName,
                  let getGroup = IOReport_ChannelGetGroup,
                  let iterate = IOReport_Iterate
            else { return nil }

            guard let currUnmanaged = createSamples(subscription, subbed, nil) else {
                return []
            }
            let curr = currUnmanaged.takeRetainedValue()

            defer { previousSample = curr }
            guard let prev = previousSample else {
                // First sample is only a baseline; cannot compute a delta yet.
                return []
            }

            guard let deltaUnmanaged = createDelta(prev, curr, nil) else {
                return []
            }
            let delta = deltaUnmanaged.takeRetainedValue()

            let timestamp = Int64(date.timeIntervalSince1970 * 1000)
            var rows: [SystemBucket] = []

            // The IOReportIterate block is invoked for every channel sample.
            // Returning 0 means "continue" per IOReport convention.
            _ = iterate(delta) { channelSample in
                let nameOpt = getName(channelSample)?.takeUnretainedValue()
                let groupOpt = getGroup(channelSample)?.takeUnretainedValue()
                guard let rawName = nameOpt as String?,
                      let rawGroup = groupOpt as String?,
                      rawGroup == "Energy Model" else { return 0 }

                let value = getValue(channelSample, 0)
                guard value > 0 else { return 0 }

                rows.append(SystemBucket(
                    timestamp: timestamp,
                    bucketName: BucketSampler.normalizeBucketName(rawName),
                    energyNJ: value
                ))
                return 0
            }

            return rows
        }
    }

    private func ensureSetup() {
        guard !setupAttempted else { return }
        setupAttempted = true

        guard ioReportAvailable,
              let copyChannels = IOReport_CopyChannelsInGroup,
              let createSub = IOReport_CreateSubscription
        else { return }

        guard let channelsUnmanaged = copyChannels(
            BucketSampler.energyModelGroup as CFString, nil, 0, 0, 0
        ) else { return }
        let channels = channelsUnmanaged.takeRetainedValue()

        var subbedRef: Unmanaged<CFMutableDictionary>?
        guard let subUnmanaged = createSub(nil, channels, &subbedRef, 0, nil) else {
            return
        }
        let sub = subUnmanaged.takeRetainedValue()
        guard let subbed = subbedRef?.takeRetainedValue() else { return }

        self.subscription = sub
        self.subbedChannels = subbed
        self.setupSucceeded = true
    }

    /// Collapse multiple raw channel names that conceptually belong to the
    /// same hardware area into a single user-facing bucket. On Apple Silicon
    /// the CPU energy is split across performance + efficiency clusters and
    /// across many sub-subsystems (DCS, AMCC, SOC_REST, ECPM, etc); we map
    /// these into the bucket categories a user actually thinks in.
    static func normalizeBucketName(_ raw: String) -> String {
        let lower = raw.lowercased()
        // Compute / accelerators
        if lower.hasPrefix("ecpu") || lower.hasPrefix("pcpu") || lower.contains("cpu") { return "CPU" }
        if lower.contains("gpu") { return "GPU" }
        if lower.contains("ane") { return "ANE" }
        if lower.contains("ave") { return "Video" }   // Apple Video Encoder
        if lower.contains("isp") { return "Camera" }  // Image Signal Processor
        // Memory / fabric
        if lower.contains("dram") { return "DRAM" }
        if lower.contains("amcc") { return "Fabric" }  // Apple Memory Cache Controller
        if lower.contains("dcs") { return "Fabric" }   // Display Compression / fabric DCS
        if lower.contains("msr") { return "Fabric" }   // Memory subsystem
        // Display / IO
        if lower.contains("disp") { return "Display" }
        if lower.contains("pcie") { return "PCIe" }
        if lower.contains("apciec") { return "PCIe" }
        // Power management overhead (counted separately so user sees the cost)
        if lower.contains("ecpm") || lower.contains("pcpm") { return "Power Mgmt" }
        // Anything else under SOC_REST / SOC_AON / unrecognised → "SoC Other"
        return "SoC Other"
    }
}
