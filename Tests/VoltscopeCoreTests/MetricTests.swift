import XCTest
import Darwin
@testable import VoltscopeCore

final class TimebaseConversionTests: XCTestCase {
    func testProductionTimebaseConversion() {
        XCTAssertEqual(ProcessSampler.timebaseNanoseconds(72_000_000, numer: 125, denom: 3), 3_000_000_000)
        XCTAssertEqual(ProcessSampler.timebaseNanoseconds(1_500_000_000, numer: 1, denom: 1), 1_500_000_000)
        XCTAssertEqual(ProcessSampler.timebaseNanoseconds(0, numer: 125, denom: 3), 0)
        XCTAssertEqual(ProcessSampler.timebaseNanoseconds(2_073_600_000_000, numer: 125, denom: 3), 86_400_000_000_000)
    }
}

final class BucketDeduplicationTests: XCTestCase {
    // M1 Max channel names copied from the existing legend fixture. Synthetic
    // generation lists below are organized from the open-source implementations
    // cited by the review and are not measurements from those chips.
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

    func testM1MaxRetainedChannelSetExactly() {
        let expected: Set<String> = [
            "PCIe Port 0 Energy", "PCIe Port 1 Energy", "apciec0 Energy", "apciec1 Energy", "apciec2 Energy",
            "CPU Energy", "GPU Energy", "GPU SRAM0", "ANE0", "ISP0", "AVE0", "MSR0", "DCS0", "DRAM0", "AMCC0",
        ]
        XCTAssertEqual(BucketSampler.selectedChannelNames(allChannelNames), expected)
    }

    func testM3ProSummarySuppressesECPUAndPCPUFamily() {
        let names = ["CPU Energy", "ECPU", "ECPU0", "PCPU", "PCPU0", "ECPM", "PCPM"]
        XCTAssertEqual(BucketSampler.selectedChannelNames(names), ["CPU Energy"])
    }

    func testM4SummarySuppressesECPUAndPCPUFamily() {
        let names = ["CPU Energy", "ECPU", "ECPU0", "PCPU", "PCPU0", "GPU Energy", "GPU0"]
        XCTAssertEqual(BucketSampler.selectedChannelNames(names), ["CPU Energy", "GPU Energy"])
    }

    func testUltraSelectsSummaryIndependentlyForEachDie() {
        let names = ["DIE_0_CPU Energy", "DIE_0_EACC_CPU", "DIE_0_ECPUDTL00",
                     "DIE_1_CPU Energy", "DIE_1_PACC1_CPU", "DIE_1_ECPUDTL00"]
        XCTAssertEqual(BucketSampler.selectedChannelNames(names), ["DIE_0_CPU Energy", "DIE_1_CPU Energy"])
    }

    func testM5FamilyChannelsAreSuppressedBySummary() {
        let names = ["CPU Energy", "MCPU0_0", "PACC_0", "MCPM0"]
        XCTAssertEqual(BucketSampler.selectedChannelNames(names), ["CPU Energy"])
    }

    func testClusterFallbackKeepsOnlyThatLevel() {
        let names = ["EACC_CPU", "PACC0_CPU", "EACC_CPU0", "PACC0_CPU0", "ECPUDTL00"]
        XCTAssertEqual(BucketSampler.selectedChannelNames(names), ["EACC_CPU", "PACC0_CPU"])
    }

    func testUnknownCPUFamilyIsDroppedOnlyWhenSummaryExists() {
        let names = ["CPU Energy", "MYSTERY_ACC_CPU", "Unclassified Rail"]
        XCTAssertEqual(BucketSampler.selectedChannelNames(names), ["CPU Energy", "Unclassified Rail"])
        XCTAssertEqual(BucketSampler.normalizeBucketName("Unclassified Rail"), "Unclassified Rail")
    }

    func testGPUSRAMHasItsOwnBucketForBothNames() {
        XCTAssertEqual(BucketSampler.normalizeBucketName("GPU SRAM"), "GPU SRAM")
        XCTAssertEqual(BucketSampler.normalizeBucketName("GPU SRAM0"), "GPU SRAM")
        XCTAssertEqual(BucketSampler.selectedChannelNames(["GPU Energy", "GPU0", "GPU SRAM", "GPU SRAM0"]),
                       ["GPU Energy", "GPU SRAM", "GPU SRAM0"])
    }
}

final class ProcessMetricSemanticsTests: XCTestCase {
    func testProcListAllPidsReturnValueIsNumberOfPids() {
        XCTAssertEqual(ProcessSampler.pidCount(fromProcListAllPids: 626), 626)
        XCTAssertEqual(ProcessSampler.pidCount(fromProcListAllPids: -1), 0)
    }

    func testOnlyEPERMCountsAsUnreadable() {
        XCTAssertTrue(ProcessSampler.isUnreadableError(EPERM))
        XCTAssertFalse(ProcessSampler.isUnreadableError(ESRCH))
        XCTAssertFalse(ProcessSampler.isUnreadableError(EACCES))
        XCTAssertEqual(ProcessSampler.unreadableCount(forErrors: [EPERM, ESRCH, EACCES]), 1)
    }

    func testRusageEnergyComesFromRiEnergyNJ() {
        var info = rusage_info_v6()
        info.ri_energy_nj = 9_876_543
        info.ri_billed_energy = 123
        XCTAssertEqual(ProcessSampler.energyTotal(from: info), 9_876_543)
    }
}

final class IOReportUnitTests: XCTestCase {
    private func energyUnit(scale: UInt64) -> UInt64 { (3 << 56) | (scale << 32) }

    func testEnergyUnitMultipliers() {
        XCTAssertEqual(IOReportConnectSampler.unitToNJMultiplier(energyUnit(scale: 124)) ?? -1, 1_000_000, accuracy: 0.001)
        XCTAssertEqual(IOReportConnectSampler.unitToNJMultiplier(energyUnit(scale: 121)) ?? -1, 1_000, accuracy: 0.001)
        XCTAssertEqual(IOReportConnectSampler.unitToNJMultiplier(energyUnit(scale: 118)) ?? -1, 1, accuracy: 0.001)
        XCTAssertNil(IOReportConnectSampler.unitToNJMultiplier((2 << 56) | (118 << 32)))
    }
}

final class EnergyAvailabilityTests: XCTestCase {
    func testEnergyAvailableIsConsistentWithPervasiveEnergy() {
        let sampler = ProcessSampler()
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.pervasive_energy", &value, &size, nil, 0)
        XCTAssertEqual(sampler.energyAvailable, value == 1)
    }
}
