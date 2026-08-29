import CMobileDevice
import Foundation

/// Bridges installation_proxy's C status callback back into Swift.
///
/// `instproxy_install` returns as soon as the device accepts the command; the real
/// outcome arrives asynchronously on libimobiledevice's thread. This class blocks the
/// calling task until a terminal status ("Complete" or an error) shows up, and carries
/// the failure across the thread boundary.
final class InstallObserver: @unchecked Sendable {
    private let progress: @Sendable (TransferPhase) -> Void
    private let condition = NSCondition()
    private var isFinished = false
    private var failure: DeviceError?

    /// installation_proxy never reports progress for some steps, so a stuck install
    /// must not hang the app forever.
    private let timeout: TimeInterval = 15 * 60

    init(progress: @escaping @Sendable (TransferPhase) -> Void) {
        self.progress = progress
    }

    func report(percent: Int?, stage: String) {
        progress(.installing(fraction: Double(percent ?? 0) / 100.0, stage: stage))
    }

    func complete(with error: DeviceError?) {
        condition.lock()
        failure = error
        isFinished = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForCompletion() throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while !isFinished {
            if !condition.wait(until: deadline) {
                condition.unlock()
                throw DeviceError.installationFailed(
                    name: "Timed out",
                    description: "The device stopped reporting installation progress.",
                    code: 0
                )
            }
        }
        let error = failure
        condition.unlock()
        if let error { throw error }
    }
}

/// C trampoline for `instproxy_status_cb_t`.
func installStatusCallback(command: plist_t?, status: plist_t?, userData: UnsafeMutableRawPointer?) {
    guard let userData else { return }
    let observer = Unmanaged<InstallObserver>.fromOpaque(userData).takeUnretainedValue()

    // A nil status means the operation ended without a status plist.
    guard let status else {
        observer.complete(with: .installationFailed(
            name: "Install failed",
            description: "The device returned no status.",
            code: 0
        ))
        return
    }

    var errorName: UnsafeMutablePointer<CChar>?
    var errorDescription: UnsafeMutablePointer<CChar>?
    var errorCode: UInt64 = 0
    let errorResult = instproxy_status_get_error(status, &errorName, &errorDescription, &errorCode)

    if errorResult == INSTPROXY_E_SUCCESS, let errorName {
        let name = String(cString: errorName)
        let description = errorDescription.map { String(cString: $0) } ?? name
        free(errorName)
        if let errorDescription { free(errorDescription) }
        observer.complete(with: .installationFailed(
            name: name, description: description, code: errorCode
        ))
        return
    }
    if let errorName { free(errorName) }
    if let errorDescription { free(errorDescription) }

    var stageName: UnsafeMutablePointer<CChar>?
    instproxy_status_get_name(status, &stageName)
    let stage = stageName.map { String(cString: $0) } ?? ""
    if let stageName { free(stageName) }

    if stage == "Complete" {
        observer.report(percent: 100, stage: stage)
        observer.complete(with: nil)
        return
    }

    var percent: Int32 = -1
    instproxy_status_get_percent_complete(status, &percent)
    observer.report(percent: percent >= 0 ? Int(percent) : nil, stage: stage)
}
