import Foundation
import Security

/// The signed-in session, as persisted.
public struct StoredSession: Codable, Sendable {
    public let account: StoreAccount
    /// Opaque cookie blob from the bridge.
    public let cookies: String

    public init(account: StoreAccount, cookies: String) {
        self.account = account
        self.cookies = cookies
    }
}

/// Session persistence in the macOS Keychain.
///
/// The Apple Account password is never stored — only what Apple issues at login
/// (`passwordToken`, `dsPersonId`, storefront, pod) plus the cookie jar. Those are
/// what authorise later purchase and download calls, so keeping them is what lets
/// the user stay signed in across launches without a password prompt.
public struct KeychainStore: Sendable {
    private let service: String
    private let accountName = "app-store-session"

    public init(service: String = "com.appstoredirect.mac.session") {
        self.service = service
    }

    // MARK: - Async API
    //
    // Keychain calls are IPC to securityd and can block for a long time — indefinitely
    // when macOS decides to ask the user to authorise access, which happens whenever
    // the app's code signature changes. Running that on the main actor deadlocks
    // launch: the window never appears, so the very prompt being waited on can never
    // be answered. Every caller therefore uses these wrappers, not the `*Sync` forms.

    public func load() async throws -> StoredSession? {
        try await offMainThread { try loadSync() }
    }

    public func save(_ session: StoredSession) async throws {
        try await offMainThread { try saveSync(session) }
    }

    public func clear() async throws {
        try await offMainThread { try clearSync() }
    }

    private func offMainThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Blocking API

    public func saveSync(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)

        // Update in place when an item already exists; SecItemAdd would fail with
        // errSecDuplicateItem and leave the old session behind.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Available only while the Mac is unlocked, and never synced to iCloud
            // or included in a backup.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpected(status: updateStatus)
        }

        var insert = query
        insert.merge(attributes) { current, _ in current }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpected(status: addStatus)
        }
    }

    public func loadSync() throws -> StoredSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpected(status: status)
        }

        // A session written by an older build may not decode. Treat that as
        // "signed out" rather than as a hard failure the user cannot clear.
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    public func clearSync() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpected(status: status)
        }
    }
}

public enum KeychainError: Error, LocalizedError {
    case unexpected(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpected(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Keychain error: \(detail)"
        }
    }
}
