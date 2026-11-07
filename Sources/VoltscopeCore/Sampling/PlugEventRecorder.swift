import Foundation

/// Single owner of the AC state already written to `PowerEvents`.
///
/// Two paths can report a plug or unplug: the live layer, which samples at
/// notification time, and the history loop, which compares two consecutive 30 s
/// snapshots. If each compared against its own previous sample, one transition
/// would write two rows about 30 s apart. Both consult this actor instead, so the
/// state that is already on file is the only thing a new sample is compared
/// against and one transition writes one row.
///
/// A run's first reading only fills the ledger, through `adopt(isACPlugged:)`:
/// starting the app while the charger is connected is not a plug event. Once the
/// ledger holds a state, `record(isACPlugged:timestamp:)` can tell a real change
/// apart from a state that is already on file.
public actor PlugEventRecorder {
    public typealias Writer = @Sendable (PowerEvent) async -> Void

    private var recordedACPlugged: Bool?
    private let write: Writer

    public init(write: @escaping Writer) {
        self.write = write
    }

    /// Recorder that writes through the history database, reporting a failed
    /// insert the way the sampling loop has always reported it.
    public init(database: HistoryDatabase) {
        write = Self.databaseWriter(database)
    }

    private static func databaseWriter(_ database: HistoryDatabase) -> Writer {
        { event in
            do { try await database.writePowerEvent(event) }
            catch {
                FileHandle.standardError.write(
                    Data("[Voltscope] AC PowerEvent insert failed: \(error)\n".utf8)
                )
            }
        }
    }

    /// Notes the AC state the process starts out in, without writing anything.
    public func adopt(isACPlugged: Bool) {
        recordedACPlugged = isACPlugged
    }

    /// Records the AC state carried by a sample and writes the transition row when
    /// it differs from the state on file.
    ///
    /// - Returns: the event that was written, or `nil` when the state is the one
    ///   already on file — which is how the 30 s loop stands down after the live
    ///   layer wrote the same transition.
    @discardableResult
    public func record(isACPlugged: Bool, timestamp: Int64) async -> PowerEvent? {
        let previous = recordedACPlugged
        recordedACPlugged = isACPlugged
        guard previous != isACPlugged else { return nil }
        let event = PowerEvent(timestamp: timestamp, eventType: isACPlugged ? .plug : .unplug)
        await write(event)
        return event
    }

    /// The AC state currently on file, if any.
    public var recordedState: Bool? { recordedACPlugged }
}
