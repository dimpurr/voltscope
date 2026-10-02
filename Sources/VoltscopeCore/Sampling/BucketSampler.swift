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
    // IOConnect path (works on all Apple Silicon macOS versions including 26+,
    // and also on macOS 13–15 where IOReport.framework may or may not exist).
    // The framework path was removed because IOReport.framework is absent from
    // the dyld cache on macOS 15.7.1 and was officially removed in macOS 26.
    // IOConnect is the only path verified to work end-to-end on this hardware.
    // See: W1-ENERGY-REPORT.md §4.1 (dltest output confirming framework absence).
    private let connectSampler = IOReportConnectSampler()

    public init() {}

    public var available: Bool { connectSampler.available }

    /// Group of channels exposed by the system Energy Model on Apple Silicon.
    private static let energyModelGroup: String = "Energy Model"

    /// Returns the per-bucket energy delta rows for the interval since the
    /// previous call (or [] for the first call, which only baselines).
    public func sample(at date: Date = Date()) -> [SystemBucket] {
        connectSampler.sample(at: date)
    }

    // MARK: - Channel classification

    /// The set of "top-level summary" channel names recognised on Apple Silicon
    /// (M1 Max observed, legend_out.txt CH 21 / CH 161).
    ///
    /// On Apple Silicon the Energy Model exposes a four-level hierarchy for CPU:
    ///   1. `CPU Energy`         — top-level sum for all CPU clusters (mJ)
    ///   2. `EACC_CPU`, `PACC0_CPU`, `PACC1_CPU` — per-cluster totals (mJ)
    ///   3. `EACC_CPU0`, `PACC0_CPU0`… — per-core totals (mJ)
    ///   4. `ECPUDTLxx`, `PCPUDTLxx`, `PCPU1DTLxx` — DTL leaf channels (mJ)
    ///
    /// GPU has two channels that represent the same physical rail:
    ///   `GPU0` (mJ) and `GPU Energy` (nJ) — both map to the GPU rail.
    ///
    /// The previous `normalizeBucketName` used `contains("cpu")` which matched
    /// all four layers and ~3.6× over-counted (W1-ENERGY-REPORT.md §4.5).
    ///
    /// This set lists names that ARE top-level summaries and should be kept.
    /// Channels not in any summary group are mapped individually (PCIe, etc).
    ///
    /// **Implementation contract**: a channel is a sub-channel and should be
    /// skipped if `isSummarySubChannel(rawName:)` returns true.
    nonisolated(unsafe) static let summaryChannels: Set<String> = [
        "CPU Energy",
        "GPU Energy",
        "ANE0",
        "DRAM0",
        "AVE0",
        "ISP0",
        "MSR0",
        "DCS0",
        "AMCC0",
    ]

    /// Returns true if `rawName` is a sub-channel that is already accounted for
    /// by a top-level summary channel in `summaryChannels`, and therefore should
    /// be skipped to avoid double-counting.
    ///
    /// Sub-channel patterns (from legend_out.txt, M1 Max):
    /// - CPU second layer: `EACC_CPU`, `PACC0_CPU`, `PACC1_CPU`
    /// - CPU third layer: `EACC_CPU0`, `EACC_CPU1`, `PACC0_CPU0`…, `EACC_CPM`, `PACC0_CPM`…
    /// - CPU DTL leaves: `ECPUDTLxx`, `PCPUDTLxx`, `PCPU1DTLxx`
    /// - GPU sub-channel: `GPU0`, `GPU SRAM0` (covered by `GPU Energy`)
    /// - DRAM sub-channels: none observed beyond `DRAM0` on M1 Max
    static func isSummarySubChannel(_ rawName: String) -> Bool {
        // Already a top-level summary — keep it, do not skip.
        if summaryChannels.contains(rawName) { return false }

        let lower = rawName.lowercased()

        // CPU sub-channels: EACC_CPU*, PACC0_CPU*, PACC1_CPU*, ECPUDTL*, PCPUDTL*, PCPU1DTL*
        if lower.hasPrefix("eacc_cpu") || lower.hasPrefix("pacc0_cpu") || lower.hasPrefix("pacc1_cpu") { return true }
        if lower.hasPrefix("ecpudtl") || lower.hasPrefix("pcpudtl") || lower.hasPrefix("pcpu1dtl") { return true }

        // GPU sub-channels: GPU0, GPU SRAM0 — covered by GPU Energy
        if rawName == "GPU0" || rawName == "GPU SRAM0" { return true }

        return false
    }

    /// Maps a raw channel name to a user-facing bucket name.
    ///
    /// Only called for channels that have already passed `isSummarySubChannel`
    /// (i.e. sub-channels have been filtered out upstream). This function does
    /// not need to defend against the nested-channel inflation problem.
    static func normalizeBucketName(_ raw: String) -> String {
        let lower = raw.lowercased()
        // Top-level CPU summary
        if raw == "CPU Energy" || lower.hasPrefix("ecpu") || lower.hasPrefix("pcpu") { return "CPU" }
        // GPU
        if raw == "GPU Energy" || lower.contains("gpu") { return "GPU" }
        // ANE (Apple Neural Engine)
        if lower.contains("ane") { return "ANE" }
        // Video encoder
        if lower.contains("ave") { return "Video" }
        // Image Signal Processor
        if lower.contains("isp") { return "Camera" }
        // Memory
        if lower.contains("dram") { return "DRAM" }
        if lower.contains("amcc") { return "Fabric" }
        if lower.contains("dcs") { return "Fabric" }
        if lower.contains("msr") { return "Fabric" }
        // Display / IO
        if lower.contains("disp") { return "Display" }
        if lower.contains("pcie") { return "PCIe" }
        if lower.contains("apciec") { return "PCIe" }
        // Power management overhead
        if lower.contains("ecpm") || lower.contains("pcpm") { return "Power Mgmt" }
        return "SoC Other"
    }
}
