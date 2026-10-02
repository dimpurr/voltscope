import Foundation

/// Version tag stored on every persisted measurement.
///
/// Values of different versions are never summed together, so queries must
/// always name the version they want.
public enum EnergyMetric {
    /// Legacy measurement: `ri_billed_energy` for process energy and the
    /// nested-channel sum for buckets. Written only by the legacy importer.
    public static let legacyVersion = 0

    /// Current measurement: `ri_energy_nj` for process energy; CPU time is
    /// `(ri_user_time + ri_system_time)` scaled by the timebase, and each
    /// physical bucket quantity is counted once.
    public static let currentVersion = 1
}
