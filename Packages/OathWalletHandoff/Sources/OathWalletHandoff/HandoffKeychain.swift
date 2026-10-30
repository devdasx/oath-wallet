import Foundation
import Security

/// Explicit group selection preserves each app's existing default Keychain.
/// Unique accounts make read/delete consumption safe across app processes.
public struct HandoffKeychain: HandoffStorage {
    private let group: String
    private static let service = "org.oathwallet.wallet-handoff.v1"
    public init(accessGroup: String) throws {
        guard !accessGroup.isEmpty, !accessGroup.contains("$("),
              accessGroup.hasSuffix(".org.oathwallet.wallet-handoff") else { throw HandoffError.unavailable }
        group = accessGroup
    }
    private func query(_ id: UUID? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true]
        if let id { q[kSecAttrAccount as String] = id.uuidString.lowercased() }
        return q
    }
    public func put(_ data: Data, id: UUID) throws {
        guard data.count <= 65_536 else { throw HandoffError.invalid }
        // One outgoing handoff at a time. A new explicit tap replaces any
        // abandoned item, bounding retained secrets even if Oath is never opened.
        let removed = SecItemDelete(query() as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else { throw HandoffError.keychain(removed) }
        var q = query(id)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecValueData as String] = data
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw HandoffError.keychain(status) }
    }
    public func take(id: UUID) throws -> Data? {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw HandoffError.keychain(status) }
        let removed = SecItemDelete(query(id) as CFDictionary)
        if removed == errSecItemNotFound { return nil }
        guard removed == errSecSuccess else { throw HandoffError.keychain(removed) }
        return data
    }
    public func remove(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HandoffError.keychain(status) }
    }
    public static func mailbox(bundle: Bundle = .main) throws -> HandoffMailbox {
        guard let group = bundle.object(forInfoDictionaryKey: "OathHandoffAccessGroup") as? String else { throw HandoffError.unavailable }
        return HandoffMailbox(storage: try HandoffKeychain(accessGroup: group))
    }
}
