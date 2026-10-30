import Foundation
import Security
import CommonCrypto

protocol OathPasscodeRecordWriting: Sendable {
    func insert(_ record: Data) throws
}

/// Standalone verifier store for the reusable setup component and its tests.
/// The app injects OathWalletSetupStore to commit its encrypted wallet and PIN
/// together; wallet unlocking and throttling live in OathWalletVault.
actor OathKeychainPasscodeStore: OathPasscodeSaving {
    private let writer: any OathPasscodeRecordWriting

    init(writer: any OathPasscodeRecordWriting = OathKeychainPasscodeWriter()) {
        self.writer = writer
    }

    func save(_ digits: [UInt8]) async throws {
        guard digits.count == 6, digits.allSatisfy({ $0 <= 9 }) else {
            throw OathPasscodeSaveError.invalidPasscode
        }
        try Task.checkCancellation()
        var salt = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw OathPasscodeSaveError.unavailable }
        let record = try OathPasscodeRecord.make(digits: digits, salt: salt)
        let encoded = try JSONEncoder().encode(record)
        try Task.checkCancellation()
        // Insert-only: an existing app passcode is never silently replaced.
        try writer.insert(encoded)
    }
}

struct OathPasscodeRecord: Codable, Sendable {
    let version: Int
    let algorithm: String
    let iterations: UInt32
    let digitCount: Int
    let salt: Data
    let verifier: Data

    static func make(digits: [UInt8], salt: [UInt8], iterations: UInt32 = 600_000) throws -> Self {
        guard digits.count == 6, digits.allSatisfy({ $0 <= 9 }), salt.count >= 16, iterations > 0 else {
            throw OathPasscodeSaveError.invalidPasscode
        }
        var password = digits.map { $0 + 48 }
        defer { _ = password.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBufferPointer { saltBytes in
                derived.withUnsafeMutableBufferPointer { output in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                        saltBytes.baseAddress!, saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        output.baseAddress!, output.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw OathPasscodeSaveError.unavailable }
        return Self(version: 1, algorithm: "PBKDF2-HMAC-SHA256", iterations: iterations,
                    digitCount: digits.count, salt: Data(salt), verifier: Data(derived))
    }
}

struct OathKeychainPasscodeWriter: OathPasscodeRecordWriting {
    let service: String
    let installation: OathInstallationSecurity

    init(service: String = (Bundle.main.bundleIdentifier ?? "org.oathwallet.atmosphere.studio") + ".passcode",
         installation: OathInstallationSecurity = .shared) {
        self.service = service
        self.installation = installation
    }

    func insert(_ record: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "app-passcode-v1",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: try installation.seal(record, context: "passcode:\(service)")
        ]
        try Self.check(SecItemAdd(query as CFDictionary, nil))
    }

    static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecDuplicateItem: throw OathPasscodeSaveError.alreadyConfigured
        case errSecInteractionNotAllowed, errSecAuthFailed: throw OathPasscodeSaveError.deviceLocked
        default: throw OathPasscodeSaveError.unavailable
        }
    }
}
