import Foundation
import CoreFoundation

/// Samples hardware energy counters from the system Energy Model.
public final class BucketSampler: @unchecked Sendable {
    private let connectSampler = IOReportConnectSampler()

    public init() {}

    public var available: Bool { connectSampler.available }

    public func sample(at date: Date = Date()) -> [SystemBucket] {
        connectSampler.sample(at: date)
    }

    /// Select one available level per physical quantity and per die. A top-level
    /// summary wins; without one, CPU cluster channels are the fallback level.
    static func selectedChannelNames(_ rawNames: [String]) -> Set<String> {
        let byDie = Dictionary(grouping: rawNames) { dieIndexAndName($0).die }
        var selected = Set<String>()
        for names in byDie.values {
            let normalized = names.map { ($0, dieIndexAndName($0).name) }
            let hasCPUSummary = normalized.contains { isCPUSummary($0.1) }
            let hasCPUCluster = normalized.contains { isCPUCluster($0.1) }
            let hasGPUSummary = normalized.contains { $0.1.caseInsensitiveCompare("GPU Energy") == .orderedSame }
            for (original, name) in normalized {
                if isCPUSummary(name) || name.caseInsensitiveCompare("GPU Energy") == .orderedSame {
                    selected.insert(original)
                } else if hasCPUSummary && isCPUFamily(name) {
                    continue
                } else if hasGPUSummary && isGPUCore(name) {
                    continue
                } else if hasCPUCluster && isCPUCore(name) {
                    continue
                } else if isCPUCluster(name) || isCPUCore(name) || isGPUCore(name) {
                    selected.insert(original)
                } else if isCPUFamily(name) {
                    continue
                } else {
                    selected.insert(original)
                }
            }
        }
        return selected
    }

    private static func dieIndexAndName(_ raw: String) -> (die: String, name: String) {
        guard let range = raw.range(of: #"(?i)^DIE_(\d+)_"#, options: .regularExpression) else {
            return ("", raw)
        }
        let die = String(raw[range]).replacingOccurrences(of: #"(?i)^DIE_|_$"#, with: "", options: .regularExpression)
        return (die, String(raw[range.upperBound...]))
    }

    private static func isCPUSummary(_ name: String) -> Bool {
        name.caseInsensitiveCompare("CPU Energy") == .orderedSame || name.lowercased().hasSuffix("cpu energy")
    }

    private static func isCPUFamily(_ name: String) -> Bool {
        let value = name.uppercased()
        return value.hasPrefix("ECPU") || value.hasPrefix("PCPU") || value.hasPrefix("MCPU") ||
            value.contains("ACC") || value.contains("DTL") || value.contains("CPM") ||
            value == "ECPM" || value == "PCPM"
    }

    private static func isCPUCluster(_ name: String) -> Bool {
        let value = name.uppercased()
        return value == "EACC_CPU" || value.range(of: #"^PACC\d+_CPU$"#, options: .regularExpression) != nil ||
            value == "ECPU" || value == "PCPU" ||
            value.range(of: #"^MCPU\d+$"#, options: .regularExpression) != nil
    }

    private static func isCPUCore(_ name: String) -> Bool {
        let value = name.uppercased()
        return value.range(of: #"^MCPU\d+_\d+$"#, options: .regularExpression) != nil ||
            value.range(of: #"^PACC_\d+$"#, options: .regularExpression) != nil
    }

    private static func isGPUCore(_ name: String) -> Bool {
        name.range(of: #"(?i)^GPU\d+(?:_\d+)?$"#, options: .regularExpression) != nil ||
            name.range(of: #"(?i)^GPU CS\d+(?:_\d+)?$"#, options: .regularExpression) != nil
    }

    /// Maps selected channels to distinct physical buckets. Unrecognized names
    /// remain separate buckets rather than being merged into a catch-all sum.
    static func normalizeBucketName(_ raw: String) -> String {
        let name = dieIndexAndName(raw).name
        let lower = name.lowercased()
        if lower.contains("ecpm") || lower.contains("pcpm") || lower.contains("cpm") { return "Power Mgmt" }
        if isCPUSummary(name) || isCPUFamily(name) { return "CPU" }
        if name.caseInsensitiveCompare("GPU Energy") == .orderedSame || isGPUCore(name) { return "GPU" }
        if lower.range(of: #"^gpu(?: .+)? sram.*$"#, options: .regularExpression) != nil { return "GPU SRAM" }
        if lower.contains("ane") { return "ANE" }
        if lower.contains("ave") { return "Video" }
        if lower.contains("isp") { return "Camera" }
        if lower.contains("dram") { return "DRAM" }
        if lower.contains("amcc") || lower.contains("dcs") || lower.contains("msr") { return "Fabric" }
        if lower.contains("disp") { return "Display" }
        if lower.contains("pcie") || lower.contains("apciec") { return "PCIe" }
        return name
    }
}
