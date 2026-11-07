import Foundation

/// Clock plus delayed work for the live battery layer.
///
/// The live layer never spins a repeating timer: it waits for one system
/// notification, then arms a fixed list of short re-samples and stops. Funneling
/// every wait through one seam lets a test advance a virtual clock and assert the
/// settle timeline and the panel refresh start/stop without spending seconds, and
/// it is why "panel closed means no new wakeups" is checkable by construction:
/// the only waits the monitor can arm are `start`, `settle`, `quietWindow` and
/// `panelRefresh`, and the last one is cancelled on close.
@MainActor
public protocol BatteryTimeSource: AnyObject, Sendable {
    /// Current time. The settle window is measured against this, so a test clock
    /// controls when a transitional caption stops being shown.
    var now: Date { get }

    /// Runs `work` once, about `delay` seconds from now, unless the returned
    /// handle is cancelled first.
    @discardableResult
    func schedule(
        after delay: TimeInterval,
        _ work: @escaping @MainActor @Sendable () -> Void
    ) -> ScheduledBatteryWork
}

/// Handle for one wait armed through `BatteryTimeSource`.
@MainActor
public final class ScheduledBatteryWork {
    public private(set) var isCancelled = false
    fileprivate var task: Task<Void, Never>?

    /// Open to an alternate time source, which supplies its own way of firing or
    /// dropping a scheduled wait.
    public init() {}

    /// Stops the pending work. Cancelling twice is harmless, and a wait that has
    /// already run ignores this.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        task?.cancel()
        task = nil
    }
}

/// Production time source: waits with a cancellable `Task.sleep`, so a quiet
/// system costs nothing and no scheduler thread exists.
@MainActor
public final class SleepingBatteryTimeSource: BatteryTimeSource {
    public init() {}

    public var now: Date { Date() }

    @discardableResult
    public func schedule(
        after delay: TimeInterval,
        _ work: @escaping @MainActor @Sendable () -> Void
    ) -> ScheduledBatteryWork {
        let scheduled = ScheduledBatteryWork()
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        scheduled.task = Task { @MainActor [weak scheduled] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let scheduled, !scheduled.isCancelled else { return }
            work()
        }
        return scheduled
    }
}
