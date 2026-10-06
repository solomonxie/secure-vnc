import Foundation
import LocalAuthentication
import Security

public enum SecretStoreError: Error, LocalizedError {
    case status(OSStatus)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .status(let s): (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
        case .notFound: "Secret not found in Keychain"
        }
    }
}

public protocol SecretStore: Sendable {
    func set(_ data: Data, for account: String, requireUserPresence: Bool) throws
    func get(_ account: String, context: LAContext?) throws -> Data
    func delete(_ account: String)
}

/// Generic-password items pinned to this device; never synced or backed up off-device.
public struct KeychainStore: SecretStore {
    let service: String

    public init(service: String = "SecureVNC") { self.service = service }

    public func set(_ data: Data, for account: String, requireUserPresence: Bool) throws {
        delete(account)
        var query = base(account)
        query[kSecValueData] = data
        if requireUserPresence {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error)
            else { throw error!.takeRetainedValue() }
            query[kSecAttrAccessControl] = access
        } else {
            query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.status(status) }
    }

    public func get(_ account: String, context: LAContext?) throws -> Data {
        var query = base(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        if let context { query[kSecUseAuthenticationContext] = context }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { throw SecretStoreError.notFound }
        guard status == errSecSuccess, let data = out as? Data else { throw SecretStoreError.status(status) }
        return data
    }

    public func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private func base(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
         kSecUseDataProtectionKeychain: true]
    }
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func set(_ data: Data, for account: String, requireUserPresence: Bool) throws {
        lock.withLock { items[account] = data }
    }
    public func get(_ account: String, context: LAContext?) throws -> Data {
        guard let d = lock.withLock({ items[account] }) else { throw SecretStoreError.notFound }
        return d
    }
    public func delete(_ account: String) { _ = lock.withLock { items.removeValue(forKey: account) } }
}
