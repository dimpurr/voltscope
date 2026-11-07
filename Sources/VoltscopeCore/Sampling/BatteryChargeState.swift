import Foundation

/// What the battery is doing right now.
///
/// The four steady states read the three public Power Sources keys directly:
/// `kIOPSPowerSourceStateKey` (AC or battery), `kIOPSIsChargingKey` and
/// `kIOPSIsChargedKey`. `startingToCharge` is the one derived state: it covers
/// the seconds after a plug where the system has reported AC power but has not
/// yet reported that it is charging. Nothing here infers *why* charging has not
/// started — that would need keys Apple does not expose publicly, and a guess
/// would be wrong whenever a charger is simply limited to 80 percent.
///
/// Wording is owned by `docs/UI_SPEC.md`.
public enum BatteryChargeState: String, CaseIterable, Equatable, Sendable {
    case charging
    case startingToCharge
    case pluggedNotCharging
    case charged
    case onBattery

    /// Caption in the panel header.
    public var displayName: String {
        switch self {
        case .charging: "Charging"
        case .startingToCharge: "Plugged In, Starting to Charge…"
        case .pluggedNotCharging: "Plugged In, Not Charging"
        case .charged: "Battery Is Charged"
        case .onBattery: "On Battery"
        }
    }

    /// Lowercase form for spoken values such as "84 percent, charging".
    public var spokenName: String {
        switch self {
        case .charging: "charging"
        case .startingToCharge: "plugged in, starting to charge"
        case .pluggedNotCharging: "plugged in but not charging"
        case .charged: "battery is charged"
        case .onBattery: "on battery"
        }
    }

    /// Sentence spoken when the state changes under VoiceOver. Stands on its own,
    /// because it is announced without the percentage next to it.
    public var announcementText: String {
        switch self {
        case .charging: "Charging"
        case .startingToCharge: "Plugged in, starting to charge"
        case .pluggedNotCharging: "Plugged in but not charging"
        case .charged: "Battery is charged"
        case .onBattery: "Running on battery power"
        }
    }

    /// SF Symbol for the menu bar and panel header.
    ///
    /// `battery.100` and `battery.50` are the two level glyphs the app already
    /// used on battery; the plug and bolt distinguish the two AC states that
    /// used to share one "Battery Is Charged" caption.
    public var symbolName: String {
        switch self {
        case .charging: "bolt.fill"
        case .startingToCharge: "powerplug.fill"
        case .pluggedNotCharging: "powerplug.fill"
        case .charged: "battery.100"
        case .onBattery: "battery.50"
        }
    }

    /// True when the battery is taking power from the adapter rather than from
    /// its own charge, so surfaces can colour and word themselves consistently.
    public var isConnectedToPower: Bool {
        switch self {
        case .charging, .startingToCharge, .pluggedNotCharging, .charged: true
        case .onBattery: false
        }
    }

    /// Derives the state from the three public keys plus the settle window.
    ///
    /// - Parameter settlingAfterPlugChange: `true` inside the re-sample window
    ///   that follows a plug or unplug, where charging has not had time to
    ///   start yet. Only ever turns `pluggedNotCharging` into
    ///   `startingToCharge`; it never invents a `charging` or `charged` state.
    public static func resolve(
        isACPlugged: Bool,
        isCharging: Bool,
        isCharged: Bool,
        settlingAfterPlugChange: Bool = false
    ) -> BatteryChargeState {
        guard isACPlugged else { return .onBattery }
        if isCharging { return .charging }
        if isCharged { return .charged }
        if settlingAfterPlugChange { return .startingToCharge }
        return .pluggedNotCharging
    }
}
