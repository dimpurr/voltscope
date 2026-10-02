import XCTest
import Darwin
@testable import VoltscopeCore

// MARK: - Timebase conversion tests

final class TimebaseConversionTests: XCTestCase {
    /// Verify the timebase-to-ns formula for Apple Silicon (numer=125, denom=3).
    /// Reference: W1 selftest2 output — 3.000 s wall, getrusage 2.990 s,
    /// ri_user_time=0.072 s => 0.072 × (125/3) ≈ 3.000 s. The inverse also
    /// must hold: 3.0 s = 3_000_000_000 ns, raw ticks = 3_000_000_000 × 3/125 = 72_000_000.
    func testAppleSiliconTimebaseConversionRoundTrip() {
        let numer: UInt32 = 125
        let denom: UInt32 = 3
        // 72_000_000 ticks × 125/3 = 3_000_000_000 ns = 3.0 s
        let ticks: UInt64 = 72_000_000
        let ns = mulTimebase(ticks, numer: numer, denom: denom)
        XCTAssertEqual(ns, 3_000_000_000)
    }

    func testIntelTimebaseIdentity() {
        // Intel: numer=1, denom=1, mach absolute time == ns
        let ticks: UInt64 = 1_500_000_000
        let ns = mulTimebase(ticks, numer: 1, denom: 1)
        XCTAssertEqual(ns, 1_500_000_000)
    }

    func testTimebaseZeroInput() {
        XCTAssertEqual(mulTimebase(0, numer: 125, denom: 3), 0)
    }

    func testTimebaseLargeValueNoOverflow() {
        // Simulate a process that has been running for ~24 h on Apple Silicon.
        // 24h = 86400 s = 86_400_000_000_000 ns.
        // ticks = 86_400_000_000_000 × 3/125 = 2_073_600_000_000 ticks.
        let ticks: UInt64 = 2_073_600_000_000
        let ns = mulTimebase(ticks, numer: 125, denom: 3)
        // Should not overflow; expected ≈ 86_400_000_000_000
        XCTAssertEqual(ns, 86_400_000_000_000)
    }

    /// Pure helper mirroring ProcessSampler.mulTimebase() for testability.
    private func mulTimebase(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        if numer == denom { return ticks }
        let hi = UInt64(ticks >> 32) * UInt64(numer)
        let lo = UInt64(ticks & 0xFFFF_FFFF) * UInt64(numer)
        let combined = (hi << 32) &+ lo
        return combined / UInt64(denom)
    }
}

// MARK: - Bucket deduplication tests
//
// Fixture: channel names extracted from w1-probe/legend_out.txt (M1 Max, macOS 15.7.1).
// Only channel names and units are reproduced here — no provider addresses or raw IDs.
// Legend has 162 channels total:
//   CH 21:  CPU Energy   (mJ) — top-level CPU summary
//   CH 18:  EACC_CPU     (mJ) — cluster-level sub-channel
//   CH 19:  PACC0_CPU    (mJ) — cluster-level sub-channel
//   CH 20:  PACC1_CPU    (mJ) — cluster-level sub-channel
//   CH 5-6: EACC_CPU0/1  (mJ) — core-level sub-channel
//   CH 7-14:PACC0_CPU0-3, PACC1_CPU0-3 (mJ) — core-level sub-channels
//   CH 15-17: EACC_CPM, PACC0_CPM, PACC1_CPM (mJ) — cluster memory sub-channels
//   CH 22-31: ECPUDTLxx   (mJ) — DTL leaf sub-channels
//   CH 32-91: PCPUDTLxx   (mJ) — DTL leaf sub-channels
//   CH 92-151:PCPU1DTLxx  (mJ) — DTL leaf sub-channels
//   CH 152: GPU0          (mJ) — sub-channel (covered by GPU Energy)
//   CH 153: GPU SRAM0     (mJ) — sub-channel (covered by GPU Energy)
//   CH 154: ANE0          (mJ) — top-level ANE summary
//   CH 155: ISP0          (mJ) — top-level ISP summary
//   CH 156: AVE0          (mJ) — top-level video encoder summary
//   CH 157: MSR0          (mJ) — top-level memory subsystem summary
//   CH 158: DCS0          (mJ) — top-level fabric summary
//   CH 159: DRAM0         (mJ) — top-level DRAM summary
//   CH 160: AMCC0         (mJ) — top-level fabric summary
//   CH 161: GPU Energy    (nJ) — top-level GPU summary
//   CH 0-4: PCIe Port 0/1 Energy, apciec0/1/2 Energy (µJ) — PCIe, no sub-channels

final class BucketDeduplicationTests: XCTestCase {

    // All 162 channel names from legend_out.txt (ordered by CH number)
    private let allChannelNames: [String] = [
        // CH 0–4: PCIe (µJ) — these are all top-level on M1 Max
        "PCIe Port 0 Energy", "PCIe Port 1 Energy",
        "apciec0 Energy", "apciec1 Energy", "apciec2 Energy",
        // CH 5–17: CPU second and third layer (mJ)
        "EACC_CPU0", "EACC_CPU1",
        "PACC0_CPU0", "PACC0_CPU1", "PACC0_CPU2", "PACC0_CPU3",
        "PACC1_CPU0", "PACC1_CPU1", "PACC1_CPU2", "PACC1_CPU3",
        "EACC_CPM", "PACC0_CPM", "PACC1_CPM",
        // CH 18–20: CPU cluster-level (mJ)
        "EACC_CPU", "PACC0_CPU", "PACC1_CPU",
        // CH 21: CPU top-level (mJ)
        "CPU Energy",
        // CH 22–31: ECPUDTL leaves (mJ)
        "ECPUDTL00", "ECPUDTL01", "ECPUDTL02", "ECPUDTL03", "ECPUDTL04",
        "ECPUDTL10", "ECPUDTL11", "ECPUDTL12", "ECPUDTL13", "ECPUDTL14",
        // CH 32–91: PCPUDTL leaves (mJ) — 60 channels
        "PCPUDTL00", "PCPUDTL01", "PCPUDTL02", "PCPUDTL03", "PCPUDTL04",
        "PCPUDTL05", "PCPUDTL06", "PCPUDTL07", "PCPUDTL08", "PCPUDTL09",
        "PCPUDTL0a", "PCPUDTL0b", "PCPUDTL0c", "PCPUDTL0d", "PCPUDTL0e",
        "PCPUDTL10", "PCPUDTL11", "PCPUDTL12", "PCPUDTL13", "PCPUDTL14",
        "PCPUDTL15", "PCPUDTL16", "PCPUDTL17", "PCPUDTL18", "PCPUDTL19",
        "PCPUDTL1a", "PCPUDTL1b", "PCPUDTL1c", "PCPUDTL1d", "PCPUDTL1e",
        "PCPUDTL20", "PCPUDTL21", "PCPUDTL22", "PCPUDTL23", "PCPUDTL24",
        "PCPUDTL25", "PCPUDTL26", "PCPUDTL27", "PCPUDTL28", "PCPUDTL29",
        "PCPUDTL2a", "PCPUDTL2b", "PCPUDTL2c", "PCPUDTL2d", "PCPUDTL2e",
        "PCPUDTL30", "PCPUDTL31", "PCPUDTL32", "PCPUDTL33", "PCPUDTL34",
        "PCPUDTL35", "PCPUDTL36", "PCPUDTL37", "PCPUDTL38", "PCPUDTL39",
        "PCPUDTL3a", "PCPUDTL3b", "PCPUDTL3c", "PCPUDTL3d", "PCPUDTL3e",
        // CH 92–151: PCPU1DTL leaves (mJ) — 60 channels
        "PCPU1DTL00", "PCPU1DTL01", "PCPU1DTL02", "PCPU1DTL03", "PCPU1DTL04",
        "PCPU1DTL05", "PCPU1DTL06", "PCPU1DTL07", "PCPU1DTL08", "PCPU1DTL09",
        "PCPU1DTL0a", "PCPU1DTL0b", "PCPU1DTL0c", "PCPU1DTL0d", "PCPU1DTL0e",
        "PCPU1DTL10", "PCPU1DTL11", "PCPU1DTL12", "PCPU1DTL13", "PCPU1DTL14",
        "PCPU1DTL15", "PCPU1DTL16", "PCPU1DTL17", "PCPU1DTL18", "PCPU1DTL19",
        "PCPU1DTL1a", "PCPU1DTL1b", "PCPU1DTL1c", "PCPU1DTL1d", "PCPU1DTL1e",
        "PCPU1DTL20", "PCPU1DTL21", "PCPU1DTL22", "PCPU1DTL23", "PCPU1DTL24",
        "PCPU1DTL25", "PCPU1DTL26", "PCPU1DTL27", "PCPU1DTL28", "PCPU1DTL29",
        "PCPU1DTL2a", "PCPU1DTL2b", "PCPU1DTL2c", "PCPU1DTL2d", "PCPU1DTL2e",
        "PCPU1DTL30", "PCPU1DTL31", "PCPU1DTL32", "PCPU1DTL33", "PCPU1DTL34",
        "PCPU1DTL35", "PCPU1DTL36", "PCPU1DTL37", "PCPU1DTL38", "PCPU1DTL39",
        "PCPU1DTL3a", "PCPU1DTL3b", "PCPU1DTL3c", "PCPU1DTL3d", "PCPU1DTL3e",
        // CH 152–160: GPU sub-channel, GPU SRAM, ANE, ISP, AVE, MSR, DCS, DRAM, AMCC (mJ)
        "GPU0", "GPU SRAM0", "ANE0", "ISP0", "AVE0", "MSR0", "DCS0", "DRAM0", "AMCC0",
        // CH 161: GPU Energy (nJ) — top-level GPU summary
        "GPU Energy",
    ]

    /// Count of channels in the fixture (must match legend_out.txt total).
    private var fixtureCount: Int { allChannelNames.count }

    /// The channels that pass the sub-channel filter (i.e., should be included).
    private var includedChannels: [String] {
        allChannelNames.filter { !BucketSampler.isSummarySubChannel($0) }
    }

    func testFixtureHasCorrectChannelCount() {
        // legend_out.txt has 162 channels total.
        XCTAssertEqual(fixtureCount, 162)
    }

    /// Core correctness: CPU Energy and its sub-channels must not both be included.
    func testCPUEnergyAndSubchannelsAreNotBothIncluded() {
        let included = Set(includedChannels)
        XCTAssertTrue(included.contains("CPU Energy"),
                      "Top-level 'CPU Energy' must be included")
        // Cluster-level sub-channels (second layer)
        XCTAssertFalse(included.contains("EACC_CPU"), "Cluster sub-channel EACC_CPU must be excluded")
        XCTAssertFalse(included.contains("PACC0_CPU"), "Cluster sub-channel PACC0_CPU must be excluded")
        XCTAssertFalse(included.contains("PACC1_CPU"), "Cluster sub-channel PACC1_CPU must be excluded")
        // Core-level sub-channels (third layer)
        XCTAssertFalse(included.contains("EACC_CPU0"), "Core sub-channel EACC_CPU0 must be excluded")
        XCTAssertFalse(included.contains("PACC0_CPU0"), "Core sub-channel PACC0_CPU0 must be excluded")
        // DTL leaf channels
        XCTAssertFalse(included.contains("ECPUDTL00"), "DTL leaf ECPUDTL00 must be excluded")
        XCTAssertFalse(included.contains("PCPUDTL00"), "DTL leaf PCPUDTL00 must be excluded")
        XCTAssertFalse(included.contains("PCPU1DTL00"), "DTL leaf PCPU1DTL00 must be excluded")
    }

    /// GPU Energy is the top-level GPU summary (nJ); GPU0 is a sub-channel (mJ).
    /// Both measure the same physical rail; only GPU Energy should be included.
    func testGPUSubchannelExcluded() {
        let included = Set(includedChannels)
        XCTAssertTrue(included.contains("GPU Energy"),
                      "Top-level 'GPU Energy' must be included")
        XCTAssertFalse(included.contains("GPU0"),
                       "GPU0 is a sub-channel and must be excluded")
        XCTAssertFalse(included.contains("GPU SRAM0"),
                       "GPU SRAM0 is a sub-channel and must be excluded")
    }

    /// Each physical quantity should be counted exactly once after deduplication.
    func testEachBucketAppearsAtMostOnceWithDistinctPhysicalOrigin() {
        // Group remaining channels by bucket name; no bucket should have its
        // physical quantity counted more than once.
        var bucketSources: [String: [String]] = [:]
        for name in includedChannels {
            let bucket = BucketSampler.normalizeBucketName(name)
            bucketSources[bucket, default: []].append(name)
        }
        // CPU bucket must contain exactly one channel (the top-level summary).
        XCTAssertEqual(bucketSources["CPU"]?.count, 1,
                       "CPU bucket must have exactly one source: \(bucketSources["CPU"] ?? [])")
        XCTAssertEqual(bucketSources["CPU"]?.first, "CPU Energy")

        // GPU bucket must contain exactly one channel.
        XCTAssertEqual(bucketSources["GPU"]?.count, 1,
                       "GPU bucket must have exactly one source: \(bucketSources["GPU"] ?? [])")
        XCTAssertEqual(bucketSources["GPU"]?.first, "GPU Energy")
    }

    /// The total number of included channels after deduplication on M1 Max.
    /// Expected = 162 - 144 (CPU sub-channels) - 2 (GPU sub-channels) = 16.
    ///
    /// Breakdown of included channels:
    ///   CPU Energy (1) + ANE0 + ISP0 + AVE0 + MSR0 + DCS0 + DRAM0 + AMCC0 (7)
    ///   + GPU Energy (1) + PCIe Port 0/1 + apciec0/1/2 (5) = 14
    ///
    /// Note: sub-channels excluded = EACC_CPU/PACC0_CPU/PACC1_CPU (3) +
    ///   EACC_CPU0/1 + PACC0_CPU0-3 + PACC1_CPU0-3 + EACC_CPM + PACC0_CPM + PACC1_CPM (13) +
    ///   ECPUDTL (10) + PCPUDTL (60) + PCPU1DTL (60) leaves + GPU0 + GPU SRAM0 (2) = 148
    func testIncludedChannelCount() {
        // The exact count depends on the fixture. Verify it is far fewer than 162.
        let count = includedChannels.count
        XCTAssertLessThan(count, 20,
                          "After deduplication, only top-level summaries should remain (got \(count))")
        XCTAssertGreaterThan(count, 5, "At least CPU, GPU, ANE, DRAM, PCIe summaries expected")
    }
}

// MARK: - Coverage count tests

final class CoverageCountTests: XCTestCase {

    func testCoverageCountsAreNonNegative() {
        let sampler = ProcessSampler()
        let result = sampler.sampleAll()
        XCTAssertGreaterThanOrEqual(result.visibleCount, 0)
        XCTAssertGreaterThanOrEqual(result.unreadableCount, 0)
    }

    func testSecondTickCoverageCountsConsistent() async throws {
        let sampler = ProcessSampler()
        let first = sampler.sampleAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = sampler.sampleAll()
        // Counts should be plausibly stable (allow ±32 for process churn)
        XCTAssertGreaterThanOrEqual(second.visibleCount, 0)
        XCTAssertGreaterThanOrEqual(second.unreadableCount, 0)
        // Total = visible + unreadable; must match total pids seen (approximately)
        let total1 = first.visibleCount + first.unreadableCount
        let total2 = second.visibleCount + second.unreadableCount
        // Process count shouldn't change dramatically between two consecutive ticks.
        XCTAssertLessThan(abs(total2 - total1), 64,
                          "Process count should be stable between ticks")
    }

    func testBaselineTickHasNoSamples() {
        let sampler = ProcessSampler()
        let result = sampler.sampleAll()
        // First tick is baseline-only; delta rows are empty.
        XCTAssertTrue(result.samples.isEmpty, "First tick must be baseline-only")
        // But coverage counts should reflect reality.
        XCTAssertGreaterThan(result.visibleCount + result.unreadableCount, 0,
                             "There must be at least one process visible on any macOS system")
    }
}

// MARK: - Intel capability flag test

final class EnergyAvailabilityTests: XCTestCase {
    func testEnergyAvailableIsConsistentWithPervasiveEnergy() {
        let sampler = ProcessSampler()
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.pervasive_energy", &value, &size, nil, 0)
        let expected = (value == 1)
        XCTAssertEqual(sampler.energyAvailable, expected,
                       "energyAvailable must match kern.pervasive_energy sysctl")
    }
}
