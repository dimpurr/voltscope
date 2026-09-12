import Foundation
import IOKit

/// IOReport sampler that talks to the IOReportHub user client directly via
/// IOConnect, bypassing the user-space `IOReport.framework` (which Apple
/// removed in macOS 26 — see ENERGY_MODEL.md §5b).
///
/// Implements the IOReportHub user-client protocol and is verified end-to-end
/// against macOS 26.3.1 on Apple Silicon (M3).
///
/// Scope: subscribes to the "Energy Model" group (CPU per-cluster, GPU,
/// ANE, DRAM, PCIe, etc) and reads cumulative joule counters per channel.
/// Each `sample()` call updates the kernel buffer and returns delta rows
/// since the previous call (first call is baseline-only and returns []).
public final class IOReportConnectSampler: @unchecked Sendable {
    // IOReportHub user-client method selectors.
    private static let kOpen: UInt32 = 0
    private static let kConfigureInterests: UInt32 = 2
    private static let kUpdateKernelBuffer: UInt32 = 3

    /// In-registry legend metadata + provider id we need to (a) build the
    /// IOReportInterest struct and (b) translate the raw integer back to nJ.
    private struct ChannelDescriptor {
        let providerId: UInt64
        let channelId: UInt64
        let channelType: UInt64    // packed IOReportChannelType (8 bytes)
        let channelName: String
        /// Multiplier to convert the raw integer to nanojoules. Decoded once
        /// from `IOReportChannelInfo.IOReportChannelUnit` per channel.
        let nJPerUnit: Double
    }

    private let queue = DispatchQueue(label: "com.dimpurr.voltscope.ioreportconnect")
    private var connection: io_connect_t = 0
    private var dwordPtr: UInt64 = 0
    private var mappedAddr: mach_vm_address_t = 0
    private var mappedSize: mach_vm_size_t = 0
    private var channels: [ChannelDescriptor] = []
    private var previousValues: [UInt64: Int64] = [:]   // keyed by (providerId ^ channelId)
    private var setupAttempted = false
    private var setupSucceeded = false

    public init() {}

    public var available: Bool { setupSucceeded }

    public func sample(at date: Date = Date()) -> [SystemBucket] {
        queue.sync {
            ensureSetup()
            guard setupSucceeded, mappedAddr != 0, !channels.isEmpty else { return [] }

            // Refresh kernel buffer with latest sample
            var inputScalar: UInt64 = dwordPtr
            let updateResult = IOConnectCallMethod(
                connection,
                Self.kUpdateKernelBuffer,
                &inputScalar, 1,
                nil, 0,
                nil, nil,
                nil, nil
            )
            guard updateResult == KERN_SUCCESS else { return [] }

            let basePtr = UnsafePointer<UInt64>(bitPattern: UInt(mappedAddr))!
            let timestamp = Int64(date.timeIntervalSince1970 * 1000)

            // Each IOReportElement is 64 bytes: provider_id, channel_id,
            // channel_type, timestamp, then values[4]. Simple format keeps
            // the cumulative integer at values[0] (byte offset 32 → uint64
            // index 4 within the 8-uint64 element).
            var deltas: [String: Int64] = [:]   // bucketName → energyNJ delta
            for (i, desc) in channels.enumerated() {
                let elBase = basePtr.advanced(by: i * 8)
                let rawValue = Int64(bitPattern: elBase[4])
                let key = desc.providerId ^ desc.channelId
                let prevOpt = previousValues[key]
                previousValues[key] = rawValue
                guard let prev = prevOpt else { continue }
                // Counter is monotonic; clamp negatives (post-sleep wraparound, etc).
                let delta = max(0, rawValue - prev)
                guard delta > 0 else { continue }
                let energyNJ = Int64(Double(delta) * desc.nJPerUnit)
                let bucket = BucketSampler.normalizeBucketName(desc.channelName)
                deltas[bucket, default: 0] += energyNJ
            }

            return deltas.map { (name, nj) in
                SystemBucket(timestamp: timestamp, bucketName: name, energyNJ: nj)
            }
        }
    }

    private func ensureSetup() {
        guard !setupAttempted else { return }
        setupAttempted = true

        // 1. Walk IORegistry collecting Energy Model channels
        let descriptors = collectEnergyModelChannels()
        guard !descriptors.isEmpty else { return }

        // 2. Open IOReportHub
        let matching = IOServiceMatching("IOReportHub")
        var serviceIter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &serviceIter) == KERN_SUCCESS else {
            return
        }
        let service = IOIteratorNext(serviceIter)
        IOObjectRelease(serviceIter)
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else { return }
        guard IOConnectCallScalarMethod(connect, Self.kOpen, nil, 0, nil, nil) == KERN_SUCCESS else {
            IOServiceClose(connect)
            return
        }

        // 3. ConfigureInterests with the channel set
        let bufSize = 8 + descriptors.count * 24
        var interestBuf = [UInt8](repeating: 0, count: bufSize)
        interestBuf.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            base.withMemoryRebound(to: UInt32.self, capacity: 1) { $0[0] = UInt32(descriptors.count) }
            let interestsBase = base.advanced(by: 8)
            for (i, d) in descriptors.enumerated() {
                interestsBase.advanced(by: i * 24).withMemoryRebound(to: UInt64.self, capacity: 3) { qp in
                    qp[0] = d.providerId
                    qp[1] = d.channelId
                    qp[2] = d.channelType
                }
            }
        }
        var dword: UInt64 = 0
        var outCnt: UInt32 = 1
        let configResult = interestBuf.withUnsafeBytes { p -> kern_return_t in
            return IOConnectCallMethod(
                connect, Self.kConfigureInterests,
                nil, 0,
                p.baseAddress, p.count,
                &dword, &outCnt,
                nil, nil
            )
        }
        guard configResult == KERN_SUCCESS else {
            IOServiceClose(connect)
            return
        }

        // 4. MapMemory to get the kernel sample buffer
        var addr: mach_vm_address_t = 0
        var size: mach_vm_size_t = 0
        let mapResult = IOConnectMapMemory(
            connect, UInt32(dword), mach_task_self_,
            &addr, &size, IOOptionBits(kIOMapAnywhere)
        )
        guard mapResult == KERN_SUCCESS, addr != 0 else {
            IOServiceClose(connect)
            return
        }

        self.connection = connect
        self.dwordPtr = dword
        self.mappedAddr = addr
        self.mappedSize = size
        self.channels = descriptors
        self.setupSucceeded = true
    }

    private func collectEnergyModelChannels() -> [ChannelDescriptor] {
        var output: [ChannelDescriptor] = []
        var iter: io_iterator_t = 0
        let kr = IORegistryCreateIterator(
            kIOMainPortDefault,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iter
        )
        guard kr == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var entry = IOIteratorNext(iter)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iter)
            }
            guard let legendUM = IORegistryEntryCreateCFProperty(
                entry, "IOReportLegend" as CFString, kCFAllocatorDefault, 0
            ) else { continue }
            guard let legend = legendUM.takeRetainedValue() as? [[String: Any]] else { continue }

            var entid: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &entid)

            for legendEntry in legend {
                guard let group = legendEntry["IOReportGroupName"] as? String,
                      group == "Energy Model" else { continue }
                guard let channelArr = legendEntry["IOReportChannels"] as? [[Any]] else { continue }

                // Decode unit from per-legend channel info (default to nJ if missing)
                var nJPerUnit: Double = 1.0
                if let info = legendEntry["IOReportChannelInfo"] as? [String: Any],
                   let unit = (info["IOReportChannelUnit"] as? NSNumber)?.uint64Value {
                    nJPerUnit = Self.unitToNJMultiplier(unit)
                }

                for ch in channelArr {
                    guard ch.count >= 3,
                          let cid = (ch[0] as? NSNumber)?.uint64Value,
                          let ctype = (ch[1] as? NSNumber)?.uint64Value,
                          let cname = ch[2] as? String else { continue }
                    output.append(ChannelDescriptor(
                        providerId: entid,
                        channelId: cid,
                        channelType: ctype,
                        channelName: cname,
                        nJPerUnit: nJPerUnit
                    ))
                }
            }
        }
        return output
    }

    /// Decode an IOReportUnit (8-bit quantity in high byte, exponent encoded
    /// in the SI scale slot at bits 32-39) into a multiplier that converts a
    /// raw value in that unit into nanojoules. Only meaningful when the unit's
    /// quantity is Energy (kIOReportQuantityEnergy = 3).
    static func unitToNJMultiplier(_ unit: UInt64) -> Double {
        let quantity = (unit >> 56) & 0xFF
        // Energy quantity = 3; if it's something else we still default to nJ
        // to avoid silently returning 0.
        guard quantity == 3 else { return 1.0 }
        let scaleByte = Int((unit >> 32) & 0xFF)
        // kIOReportExpZeroOffset = 127; exp = scaleByte - 127
        // Special case: scaleByte == 0 means kIOReportScaleUnity (exp = 0)
        let exp = scaleByte == 0 ? 0 : (scaleByte - 127)
        // exp -12 = pico, -9 = nano, -6 = micro, -3 = milli, 0 = unity (J)
        // multiplier from this unit to nJ: 10^(9 + exp)
        return pow(10.0, Double(9 + exp))
    }
}
