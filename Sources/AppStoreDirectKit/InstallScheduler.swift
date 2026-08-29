import Foundation

/// Admission control for device installs.
///
/// Enforces two rules at once:
///
/// 1. **A global cap.** Each install holds a USB device session, an AFC transfer and
///    an installation_proxy session open for minutes. Running twenty at once makes
///    usbmuxd the bottleneck and the whole app unstable, so the number in flight is
///    capped and configurable.
/// 2. **One job per device.** Two apps installing onto the same phone would both
///    write to `PublicStaging` and race in installation_proxy. Work against a given
///    UDID is serialised regardless of the global cap.
///
/// Waiters are admitted in FIFO order, except that a waiter whose device is busy is
/// skipped rather than blocking the queue behind it — so a phone that is slow to
/// install never stalls installs onto other phones.
public actor InstallScheduler {
    public static let defaultLimit = 3
    /// Settable range in Settings. The ceiling matches the largest bench a user is
    /// expected to drive at once; the practical limit is usbmuxd, not this number,
    /// and a device that cannot be reached reports its own failure rather than being
    /// dropped from the batch.
    public static let limitRange = 1...20

    /// Clamps a stored or user-supplied value into the settable range.
    public static func clampLimit(_ value: Int) -> Int {
        min(max(value, limitRange.lowerBound), limitRange.upperBound)
    }

    private var limit: Int
    private var running = 0
    private var busyDevices: Set<String> = []
    private var waiters: [(id: UUID, udid: String, continuation: CheckedContinuation<Void, Never>)] = []

    public init(limit: Int = InstallScheduler.defaultLimit) {
        self.limit = max(1, limit)
    }

    /// Changes the cap at runtime. Raising it admits any waiters that now fit;
    /// lowering it never interrupts work already in flight.
    public func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        admitWaiters()
    }

    public var currentLimit: Int { limit }

    /// Runs `body` once a slot for `udid` is free, releasing the slot afterwards.
    public func withSlot<T>(udid: String, _ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire(udid: udid)
        defer { release(udid: udid) }
        return try await body()
    }

    private func acquire(udid: String) async {
        if canRun(udid: udid) {
            running += 1
            busyDevices.insert(udid)
            return
        }

        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append((id: id, udid: udid, continuation: continuation))
        }
        // `admitWaiters` has already counted this job in before resuming us.
    }

    private func release(udid: String) {
        running = max(0, running - 1)
        busyDevices.remove(udid)
        admitWaiters()
    }

    private func canRun(udid: String) -> Bool {
        running < limit && !busyDevices.contains(udid)
    }

    /// Admits every waiter that can now start, in arrival order. A waiter blocked
    /// only by its own device being busy is passed over, not treated as a barrier.
    private func admitWaiters() {
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            guard running < limit else { break }
            guard !busyDevices.contains(waiter.udid) else {
                index += 1
                continue
            }
            running += 1
            busyDevices.insert(waiter.udid)
            waiters.remove(at: index)
            waiter.continuation.resume()
        }
    }
}
