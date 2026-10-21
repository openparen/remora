import Foundation
import Security

/// Device tokens in the login keychain, one generic password per account.
/// The account key is the token's `auth0-userid`.
public struct Keychain: Sendable {
    public struct Failure: Error, Equatable { public let status: OSStatus }

    public let service: String

    public init(service: String = "io.github.gveres.remora") {
        self.service = service
    }

    private func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func set(_ secret: String, account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var add = query(account)
        add[kSecValueData as String] = Data(secret.utf8)
        try check(SecItemAdd(add as CFDictionary, nil))
    }

    public func get(account: String) throws -> String? {
        var find = query(account)
        find[kSecReturnData as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(find as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return (out as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    public func accounts() throws -> [String] {
        var find = query()
        find[kSecReturnAttributes as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(find as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        try check(status)
        let items = out as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
