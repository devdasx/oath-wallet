import XCTest
import Security
@testable import OathAtmosphere

final class OathInstallationSecurityTests: XCTestCase {
    func testScopedCleanupAndBackupExclusionAcrossInstallationLoss() throws {
        let namespace = "org.oathwallet.installation-test." + UUID().uuidString
        let cleanup = OathInstallationKeychainCleanup(namespace: namespace)
        let unrelated = namespace + ".unrelated"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = OathInstallationKeyFile(directory: directory)
        let fixture = Data("public-fixture-only".utf8)
        defer {
            try? cleanup.clear()
            SecItemDelete(query(service: unrelated) as CFDictionary)
            try? FileManager.default.removeItem(at: directory)
        }
        for service in cleanup.services + [unrelated] { try insert(fixture, service: service) }
        let installation = OathInstallationSecurity(keys: file, credentials: cleanup)
        try installation.prepare()
        for service in cleanup.services { XCTAssertNil(try read(service: service)) }
        XCTAssertEqual(try read(service: unrelated), fixture)

        XCTAssertEqual(try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        let raw = OathVaultKeychain(service: namespace + ".wallet-vault")
        let storage = OathInstallationVaultStorage(raw: raw, installation: installation)
        try storage.insert(fixture, account: "vault-v1")
        try storage.insert(fixture, account: "unlock-attempts-v1")
        XCTAssertEqual(try storage.read("vault-v1"), fixture)
        XCTAssertEqual(try storage.read("unlock-attempts-v1"), fixture)
        XCTAssertNotEqual(try raw.read("vault-v1"), fixture)
        let retained = try XCTUnwrap(raw.read("vault-v1"))
        let reopened = OathInstallationVaultStorage(raw: raw,
            installation: OathInstallationSecurity(keys: file, credentials: cleanup))
        XCTAssertEqual(try reopened.read("vault-v1"), fixture)
        XCTAssertEqual(try raw.read("vault-v1"), retained, "An ordinary launch must not rotate or erase the wallet")

        try FileManager.default.removeItem(at: directory)
        let reinstalled = OathInstallationSecurity(keys: file, credentials: cleanup)
        let fresh = OathInstallationVaultStorage(raw: raw, installation: reinstalled)
        XCTAssertNil(try fresh.read("vault-v1"))
        XCTAssertNil(try fresh.read("unlock-attempts-v1"))
        XCTAssertThrowsError(try reinstalled.open(retained, context: "vault:vault-v1"))
        XCTAssertEqual(try read(service: unrelated), fixture, "Cleanup must remain scoped to owned credentials")
        try fresh.insert(fixture, account: "vault-v1")
        XCTAssertEqual(try fresh.read("vault-v1"), fixture)
    }

    func testCompleteFileProtectionOnDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The simulator does not expose hardware Data Protection metadata; this requires an explicitly authorized physical-device test.")
        #else
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = OathInstallationKeyFile(directory: directory)
        try file.write(Data("public-file-protection-fixture".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
        #endif
    }

    private func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "public-test-record",
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
    private func insert(_ data: Data, service: String) throws {
        var item = query(service: service)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw OathInstallationSecurityError.keychain(status) }
    }
    private func read(service: String) throws -> Data? {
        var item = query(service: service)
        item[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw OathInstallationSecurityError.keychain(status) }
        return result as? Data
    }
}
