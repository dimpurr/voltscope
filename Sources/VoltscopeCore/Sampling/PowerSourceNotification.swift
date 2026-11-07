import Foundation
import IOKit
import IOKit.ps

/// Delivers "something about the power source changed" from the system.
///
/// Everything the live layer does starts here: it is the only path that can
/// report a plug or unplug in under a second, because the history loop that
/// notices the same change is bounded by its own sampling interval.
@MainActor
public protocol PowerSourceChangeNotifying: AnyObject, Sendable {
    /// Installed before `start()`; called on the main actor per notification.
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}

/// `IOPSNotificationCreateRunLoopSource` attached to the main run loop.
///
/// Public IOKit Power Sources API only. Attaching to the main run loop means no
/// worker thread and no timer: while nothing changes, the process is simply
/// blocked in the run loop it was already running, so a closed panel costs zero
/// wakeups. The callback hops to the main actor rather than touching app state
/// from a C context.
@MainActor
public final class IOPSPowerSourceNotifier: PowerSourceChangeNotifying {
    public var onChange: (() -> Void)?

    private var source: CFRunLoopSource?
    private var context: UnsafeMutableRawPointer?

    public init() {}

    public func start() {
        guard source == nil else { return }
        let box = PowerSourceCallbackBox { [weak self] in
            Task { @MainActor in self?.onChange?() }
        }
        let retained = Unmanaged.passRetained(box)
        let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceCallbackBox>.fromOpaque(context)
                .takeUnretainedValue()
                .deliver()
        }, retained.toOpaque()).takeRetainedValue()
        context = retained.toOpaque()
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
    }

    public func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            self.source = nil
        }
        if let context {
            Unmanaged<PowerSourceCallbackBox>.fromOpaque(context).release()
            self.context = nil
        }
    }
}

/// Retained C context for the run-loop source. Held by the source's own retain so
/// a missed `stop()` leaks one small object instead of leaving a dangling pointer.
final class PowerSourceCallbackBox: @unchecked Sendable {
    let deliver: @Sendable () -> Void

    init(deliver: @escaping @Sendable () -> Void) {
        self.deliver = deliver
    }
}
