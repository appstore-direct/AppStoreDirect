import Foundation

/// Runs blocking libimobiledevice work off the Swift concurrency cooperative pool.
///
/// Every call into libimobiledevice blocks its thread — AFC uploads and
/// `instproxy_install` can each block for minutes. Doing that on the cooperative
/// pool would starve it: the pool sizes itself to the core count, so a handful of
/// concurrent installs would stall unrelated work, including the UI's own tasks.
///
/// A dedicated concurrent queue keeps that blocking where it belongs. The queue is
/// unbounded on purpose; how many installs may run at once is a policy decision made
/// by `InstallScheduler`, not a property of the transport.
enum DeviceIO {
    private static let queue = DispatchQueue(
        label: "com.appstoredirect.device-io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
