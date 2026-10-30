import Foundation
import CryptoKit
import XCTest
@testable import OathCloudBackup

final class PassphraseTests: XCTestCase {
    // Published BIP-39 words, used only as synthetic test data.
    private let words = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"

    func testNormalizationPreservesCaseSpacesAndSupportsUnicode() throws {
        XCTAssertTrue(try RecoveryPassphrase.normalized("  TREZOR ") == "  TREZOR ")
        XCTAssertTrue(try RecoveryPassphrase.normalized("é") == RecoveryPassphrase.normalized("e\u{301}"))
        XCTAssertTrue(try RecoveryPassphrase.normalized("Ａ") == "A")
        XCTAssertTrue(try RecoveryPassphrase.normalized("أمان 🔑") == "أمان 🔑".decomposedStringWithCompatibilityMapping)
        XCTAssertTrue(try RecoveryPassphrase.normalized(" ") == " ")
        XCTAssertThrowsError(try RecoveryPassphrase.normalized(""))
        XCTAssertThrowsError(try RecoveryPassphrase.normalized("before\0after"))
        XCTAssertNoThrow(try RecoveryPassphrase.normalized(String(repeating: "a", count: 256)))
        XCTAssertThrowsError(try RecoveryPassphrase.normalized(String(repeating: "a", count: 257)))
        // The limit applies AFTER compatibility decomposition, in UTF-8 bytes.
        XCTAssertThrowsError(try RecoveryPassphrase.normalized(String(repeating: "é", count: 86)))
    }

    func testPassphraseIsInsideAuthenticatedBackupAndRequiresNewVersion() throws {
        let passphrase = try RecoveryPassphrase.normalized("  TéST 🔑  ")
        let wallet = BackupWallet(id: UUID(), name: "Passphrase fixture", mnemonic: words, language: "english",
            createdAt: .now, accounts: [.init(network: "ethereum", derivationPath: "m/44'/60'/0'/0/0", index: 0)],
            colorHex: "DF438D", passphrase: passphrase)
        let encrypted = try BackupDocument.seal(wallet, password: "fixture-password")
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains(passphrase))
        let restored = try BackupDocument.open(encrypted, password: "fixture-password")
        XCTAssertTrue(restored == wallet)
        var envelope = try JSONDecoder().decode(BackupDocument.Envelope.self, from: encrypted)
        XCTAssertEqual(envelope.header.version, 2)
        envelope.header.version = 1
        XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(envelope), password: "fixture-password"))
    }

    func testOldBackupCompatibilityAndInvalidMixedMaterial() throws {
        let old = BackupWallet(id: UUID(), name: "Old fixture", mnemonic: words, language: "english",
            createdAt: .now, accounts: [])
        let data = try BackupDocument.seal(old, password: "fixture-password")
        XCTAssertEqual(try JSONDecoder().decode(BackupDocument.Envelope.self, from: data).header.version, 1)
        XCTAssertNil(try BackupDocument.open(data, password: "fixture-password").passphrase)
        let key = BackupWallet(id: UUID(), name: "Invalid fixture", mnemonic: "", language: "", createdAt: .now,
            accounts: [.init(network: "ethereum", derivationPath: "imported", index: 0)],
            privateKey: .init(bytes: Data(repeating: 1, count: 32), networks: ["ethereum"]), passphrase: "fixture")
        XCTAssertThrowsError(try BackupDocument.seal(key, password: "fixture-password"))
    }

    func testLegacyLongPassphraseRoundTripRequiresCompatibilityVersion() throws {
        let passphrase = String(repeating: "x", count: 300)
        let wallet = BackupWallet(id: UUID(), name: "Upgrade fixture", mnemonic: words, language: "english",
            createdAt: .now, accounts: [.init(network: "ethereum", derivationPath: "m/44'/60'/0'/0/0", index: 0)],
            passphrase: passphrase, legacyPassphrase: true)
        let data = try BackupDocument.seal(wallet, password: "fixture-password")
        XCTAssertEqual(try BackupDocument.open(data, password: "fixture-password"), wallet)
        var envelope = try JSONDecoder().decode(BackupDocument.Envelope.self, from: data)
        XCTAssertEqual(envelope.header.version, 7)
        envelope.header.version = 2
        XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(envelope), password: "fixture-password"))
        XCTAssertThrowsError(try RecoveryPassphrase.normalized(passphrase), "New-wallet limits remain unchanged")
        XCTAssertThrowsError(try RecoveryPassphrase.normalizedLegacy(String(repeating: "x", count: 4_097)))
    }
}
