import Foundation
import GRDB

/// One row per (timestamp, bucketName) emitted by `BucketSampler`. The
/// `energyNJ` value is the *delta* over the interval since the previous
/// sample — computed by IOReport's own delta API, not by the app — so
/// summing energyNJ over a time window gives total joules consumed by
/// that hardware bucket in nanojoules.
public struct SystemBucket: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var timestamp: Int64
    public var bucketName: String
    public var energyNJ: Int64

    public static let databaseTableName = "SystemBuckets"

    public init(timestamp: Int64, bucketName: String, energyNJ: Int64) {
        self.timestamp = timestamp
        self.bucketName = bucketName
        self.energyNJ = energyNJ
    }
}
