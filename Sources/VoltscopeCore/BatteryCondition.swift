import Foundation

public enum BatteryCondition: String, Sendable {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case service = "Service Recommended"
    case unknown = "—"

    /// Coarse classifier mirroring Apple's own "Service Recommended" cutoff
    /// (which fires at ~80 % maximum capacity) plus the cycle-count
    /// thresholds Apple publishes for current Mac batteries (1000 cycles).
    ///
    /// Inputs are nilable because v0.1 BatterySnapshot fields are nilable —
    /// returns `.unknown` if we can't determine confidently.
    public static func classify(cycleCount: Int?, capacityMAh: Int?, designMAh: Int?) -> BatteryCondition {
        let healthRatio: Double? = {
            guard let capacity = capacityMAh, let design = designMAh, design > 0 else { return nil }
            return Double(capacity) / Double(design)
        }()

        if let ratio = healthRatio, ratio < 0.80 {
            return .service
        }
        if let cycles = cycleCount, cycles >= 1000 {
            return .service
        }

        switch (cycleCount, healthRatio) {
        case let (cycles?, ratio?) where cycles < 300 && ratio >= 0.92:
            return .excellent
        case let (cycles?, ratio?) where cycles < 600 && ratio >= 0.88:
            return .good
        case let (_?, ratio?) where ratio >= 0.85:
            return .good
        case let (_?, ratio?) where ratio >= 0.80:
            return .fair
        case let (cycles?, _) where cycles < 300:
            return .excellent
        case let (cycles?, _) where cycles < 600:
            return .good
        case let (cycles?, _) where cycles < 1000:
            return .fair
        default:
            return .unknown
        }
    }
}
