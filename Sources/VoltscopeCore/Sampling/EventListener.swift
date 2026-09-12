import Foundation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public final class EventListener {
    public typealias Handler = (PowerEvent) -> Void

    private var handler: Handler?
    private var observers: [NSObjectProtocol] = []
    private var lastSleepTimestamp: Int64?

    public init() {}

    public func start(handler: @escaping Handler) {
        self.handler = handler

        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter

        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification queue is OperationQueue.main, but Swift 6 still
            // requires explicit isolation since the closure is non-isolated.
            Task { @MainActor in self?.emitSleep() }
        }
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.emitWake() }
        }
        observers = [sleep, wake]
        #endif
    }

    public func stop() {
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        #endif
        handler = nil
    }

    private func emitSleep() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        lastSleepTimestamp = now
        handler?(PowerEvent(timestamp: now, eventType: .sleep))
    }

    private func emitWake() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var duration: Int?
        if let sleepStart = lastSleepTimestamp {
            duration = Int((now - sleepStart) / 1000)
            lastSleepTimestamp = nil
        }
        handler?(PowerEvent(timestamp: now, eventType: .wake, durationSeconds: duration))
    }
}
