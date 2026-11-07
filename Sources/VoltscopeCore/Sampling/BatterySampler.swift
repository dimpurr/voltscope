import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

public final class BatterySampler: @unchecked Sendable {
    public init() {}

    public func sample(at date: Date = Date()) -> BatterySnapshot? {
        guard let power = readPowerSource() else { return nil }
        return snapshot(from: power, at: date)
    }

    /// The same reading with `kIOPSIsChargedKey` attached, for the live layer.
    ///
    /// History has no column for "charged" and its schema does not change, so the
    /// key is read here rather than stored.
    public func liveSample(at date: Date = Date()) -> LiveBatteryReading? {
        guard let power = readPowerSource() else { return nil }
        return LiveBatteryReading(
            snapshot: snapshot(from: power, at: date),
            isCharged: power.isCharged
        )
    }

    private func snapshot(from power: PowerSourceReading, at date: Date) -> BatterySnapshot {
        // AppleSmartBattery IORegistry → mAh, mV, mA, temperature, cycle count.
        let smart = readSmartBattery()
        let timestamp = Int64(date.timeIntervalSince1970 * 1000)

        return BatterySnapshot(
            timestamp: timestamp,
            levelPercent: power.levelPercent,
            capacityMAh: smart.capacityMAh,
            designMAh: smart.designMAh,
            cycleCount: smart.cycleCount,
            voltageMV: smart.voltageMV,
            amperageMA: smart.amperageMA,
            temperatureC: smart.temperatureC,
            timeRemainingMin: power.timeRemainingMin,
            isCharging: power.isCharging,
            isACPlugged: power.isACPlugged
        )
    }

    private struct PowerSourceReading {
        var levelPercent: Double?
        var timeRemainingMin: Int?
        var isCharging = false
        var isACPlugged = false
        var isCharged = false
    }

    /// Power Sources API → percentage, time remaining, charging state.
    private func readPowerSource() -> PowerSourceReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        var reading = PowerSourceReading()

        for source in sources {
            guard let descRef = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() else { continue }
            guard let desc = descRef as? [String: Any] else { continue }

            // Internal battery only.
            if let type = desc[kIOPSTypeKey as String] as? String,
               type != kIOPSInternalBatteryType as String {
                continue
            }

            if let current = desc[kIOPSCurrentCapacityKey as String] as? Int,
               let max = desc[kIOPSMaxCapacityKey as String] as? Int,
               max > 0 {
                reading.levelPercent = (Double(current) / Double(max)) * 100.0
            }

            if let powerState = desc[kIOPSPowerSourceStateKey as String] as? String {
                reading.isACPlugged = (powerState == kIOPSACPowerValue as String)
            }
            if let charging = desc[kIOPSIsChargingKey as String] as? Bool {
                reading.isCharging = charging
            }
            if let charged = desc[kIOPSIsChargedKey as String] as? Bool {
                reading.isCharged = charged
            }

            if let minutes = desc[kIOPSTimeToEmptyKey as String] as? Int, minutes > 0 {
                reading.timeRemainingMin = minutes
            } else if let minutes = desc[kIOPSTimeToFullChargeKey as String] as? Int, minutes > 0 {
                reading.timeRemainingMin = minutes
            }
        }
        return reading
    }

    private struct SmartBatteryReading {
        var capacityMAh: Int?
        var designMAh: Int?
        var cycleCount: Int?
        var voltageMV: Int?
        var amperageMA: Int?
        var temperatureC: Double?
    }

    private func readSmartBattery() -> SmartBatteryReading {
        var reading = SmartBatteryReading()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return reading }
        defer { IOObjectRelease(service) }

        var unmanagedProps: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &unmanagedProps, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props = unmanagedProps?.takeRetainedValue() as? [String: Any] else {
            return reading
        }

        // capacityMAh stores the *maximum* capacity (full-charge capacity at this
        // moment in the battery's life), so health = capacityMAh / designMAh
        // matches the percentage System Settings → Battery shows under
        // "Maximum Capacity". v0.6 used `AppleRawCurrentCapacity` here which
        // is the *current charge*, leading to a health % that drifted with
        // the battery level instead of representing wear.
        if let value = props["AppleRawMaxCapacity"] as? Int {
            reading.capacityMAh = value
        } else if let value = props["MaxCapacity"] as? Int {
            reading.capacityMAh = value
        } else if let value = props["AppleRawCurrentCapacity"] as? Int {
            // Last-resort fallback so older platforms don't lose the field
            // entirely; the resulting health % will be off by the level
            // factor on those systems.
            reading.capacityMAh = value
        }
        if let value = props["DesignCapacity"] as? Int { reading.designMAh = value }
        if let value = props["CycleCount"] as? Int { reading.cycleCount = value }
        if let value = props["Voltage"] as? Int { reading.voltageMV = value }
        if let value = props["Amperage"] as? Int {
            // Amperage is reported as Int64 sign-extended; AppleSmartBattery returns negative on discharge.
            // Cast through signed semantics.
            let signed = Int(Int32(truncatingIfNeeded: value))
            reading.amperageMA = signed
        }
        if let value = props["Temperature"] as? Int {
            // Reported in 0.01°C units.
            reading.temperatureC = Double(value) / 100.0
        }
        return reading
    }
}

/// The history loop's sampler seam.
public protocol BatterySampling: Sendable {
    func sample(at date: Date) -> BatterySnapshot?
}

/// The live layer reads the same sampler the history loop uses.
extension BatterySampler: LiveBatterySampling, BatterySampling {}
