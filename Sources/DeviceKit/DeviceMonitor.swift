import CMobileDevice
import Foundation

public enum DeviceEvent: Sendable, Hashable {
    case attached(udid: String, connection: ConnectionKind)
    case detached(udid: String)
    case paired(udid: String)
}

/// USB hotplug, surfaced as an `AsyncStream`.
///
/// libimobiledevice delivers events on its own usbmuxd listener thread through a
/// bare C function pointer, which cannot capture context. The subscription is
/// therefore process-wide and registered once; `events()` fans it out to any number
/// of consumers. A lock guards the continuation table because the callback thread is
/// not the main actor.
public final class DeviceMonitor: @unchecked Sendable {
    public static let shared = DeviceMonitor()

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<DeviceEvent>.Continuation] = [:]
    private var context: idevice_subscription_context_t?

    private init() {}

    /// A stream of attach/detach events. Cancelling the consuming task
    /// unregisters it; the underlying subscription stays up for other consumers.
    public func events() -> AsyncStream<DeviceEvent> {
        AsyncStream { continuation in
            let token = UUID()
            lock.lock()
            continuations[token] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: token)
                self.lock.unlock()
            }
        }
    }

    /// Idempotent. Safe to call from `.task` on every view appearance.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard context == nil else { return }

        var newContext: idevice_subscription_context_t?
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let result = idevice_events_subscribe(&newContext, deviceEventCallback, observer)
        guard result == IDEVICE_E_SUCCESS else {
            throw DeviceError.deviceUnavailable(udid: "*", code: result.rawValue)
        }
        context = newContext
    }

    public func stop() {
        lock.lock()
        let existing = context
        context = nil
        lock.unlock()

        if let existing { idevice_events_unsubscribe(existing) }
    }

    fileprivate func broadcast(_ event: DeviceEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets { target.yield(event) }
    }
}

/// C callback trampoline. Must stay a top-level function with C calling
/// convention — it cannot capture, so the monitor arrives via `user_data`.
private func deviceEventCallback(event: UnsafePointer<idevice_event_t>?, userData: UnsafeMutableRawPointer?) {
    guard let event, let userData else { return }
    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(userData).takeUnretainedValue()

    let udid = event.pointee.udid.map { String(cString: $0) } ?? ""
    guard !udid.isEmpty else { return }

    let connection: ConnectionKind =
        event.pointee.conn_type == CONNECTION_NETWORK ? .network : .usb

    switch event.pointee.event {
    case IDEVICE_DEVICE_ADD:
        monitor.broadcast(.attached(udid: udid, connection: connection))
    case IDEVICE_DEVICE_REMOVE:
        monitor.broadcast(.detached(udid: udid))
    case IDEVICE_DEVICE_PAIRED:
        monitor.broadcast(.paired(udid: udid))
    default:
        break
    }
}
