import Foundation

/// One power-source reading that never went through the database.
///
/// History keeps its own `BatterySnapshot` rows on the 30 s cadence; the menu bar
/// and panel read this instead, so a plug or unplug can show up in under a
/// second without moving the history cadence. `chargeState` is decided at sample
/// time, while the settle window around the sample is still known, so no surface
/// can disagree with the moment it came from.
public struct LiveBatteryReading: Equatable, Sendable {
    public let snapshot: BatterySnapshot
    /// `kIOPSIsChargedKey`. History has no column for it and the schema does not
    /// change, so "Battery Is Charged" is only ever said by a live reading.
    public let isCharged: Bool
    public let chargeState: BatteryChargeState

    public init(
        snapshot: BatterySnapshot,
        isCharged: Bool,
        settlingAfterPlugChange: Bool = false
    ) {
        self.snapshot = snapshot
        self.isCharged = isCharged
        self.chargeState = BatteryChargeState.resolve(
            isACPlugged: snapshot.isACPlugged,
            isCharging: snapshot.isCharging,
            isCharged: isCharged,
            settlingAfterPlugChange: settlingAfterPlugChange
        )
    }

    public var levelPercent: Double? { snapshot.levelPercent }
    public var timestamp: Int64 { snapshot.timestamp }
}

/// Reads the current battery state without touching history.
///
/// `BatterySampler` is the production implementation. Tests inject a scripted
/// source so the coalescing and settle timeline can be asserted exactly.
public protocol LiveBatterySampling: Sendable {
    func liveSample(at date: Date) -> LiveBatteryReading?
}
