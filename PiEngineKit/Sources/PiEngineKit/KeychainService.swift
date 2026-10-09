import Foundation
import Security

/// The engine's `keychain` service: credentials pi-ai stores (API keys, OAuth tokens), one generic-password item per
/// provider; other services keep their secrets with one of their own. Items are readable after first unlock (so
/// background runs can refresh tokens). A `synchronizable` one goes to the user's other devices through iCloud Keychain
/// (end-to-end encrypted), and items it kept on this device only move there.
@MainActor
public final class KeychainService {
    private let service: String
    private let synchronizable: Bool

    public init(service: String = "dev.pimobile.credentials", synchronizable: Bool = false) {
        self.service = service
        self.synchronizable = synchronizable
        if synchronizable { moveToICloud() }
    }

    public func install(on engine: PiEngine) {
        engine.register(service: "keychain") { [weak self] method, params in
            guard let self else { throw EngineError.unknownService("keychain") }
            let arguments = JSONValue(bridged: params)
            let account = arguments["account"]?.string ?? ""
            switch method {
            case "get": return try self.get(account) ?? NSNull()
            case "set":
                try self.set(account, arguments["value"]?.string ?? "")
                return nil
            case "delete":
                try self.delete(account)
                return nil
            case "list": return try self.accounts()
            default: throw EngineError.unknownMethod("keychain.\(method)")
            }
        }
    }

    /// Its items, on this device only and synced alike.
    private func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// Items kept on this device only (from before syncing), saved again to sync.
    private func moveToICloud() {
        var local: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: false, kSecReturnAttributes as String: true,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: AnyObject?
        guard SecItemCopyMatching(local as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data else { continue }
            local = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                     kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
            if (try? set(account, String(decoding: data, as: UTF8.self))) != nil { SecItemDelete(local as CFDictionary) }
        }
    }

    public func get(_ account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func set(_ account: String, _ value: String) throws {
        var item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecAttrSynchronizable as String: synchronizable]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            item.merge(attributes) { $1 }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func accounts() throws -> [String] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw KeychainError(status: status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}
