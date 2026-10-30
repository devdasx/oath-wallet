import XCTest
import CryptoKit
@testable import OathCloudBackup

final class BackupDocumentTests: XCTestCase {
    func testPrivateKeyBackupIsEncryptedAndRetainsScopeAndCustomization() throws {
        let material = BackupWallet.ImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: ["ethereum", "base"])
        let keyWallet = BackupWallet(id: UUID(), name: "Imported test wallet", mnemonic: "", language: "",
            createdAt: Date(timeIntervalSince1970: 1),
            accounts: material.networks.map { .init(network: $0, derivationPath: "imported", index: 0) },
            colorHex: "DF438D", privateKey: material)
        let encrypted = try BackupDocument.seal(keyWallet, password: "fixture-password")
        let restored = try BackupDocument.open(encrypted, password: "fixture-password")
        XCTAssertTrue(restored == keyWallet)
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains(material.bytes.base64EncodedString()))
        XCTAssertThrowsError(try BackupDocument.open(encrypted, password: "wrong-fixture-password"))
    }

    func testPrivateKeyBackupRejectsAmbiguousMaterialAndMismatchedAccounts() throws {
        let key = BackupWallet.ImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: ["ethereum"])
        for (mnemonic, language, network, path) in [(wallet.mnemonic, "english", "ethereum", "imported"),
                                                   ("", "", "bitcoin", "imported"),
                                                   ("", "", "ethereum", "m/44'/60'/0'/0/0")] {
            let invalid = BackupWallet(id: wallet.id, name: "", mnemonic: mnemonic, language: language,
                createdAt: wallet.createdAt, accounts: [.init(network: network, derivationPath: path, index: 0)], privateKey: key)
            XCTAssertThrowsError(try BackupDocument.seal(invalid, password: "fixture-password")) {
                XCTAssertEqual($0 as? CloudBackupError, .invalidDocument)
            }
        }
    }

    func testBitcoinCompressionAndExtendedKeySurviveEncryptedBackup() throws {
        // Serialization fixtures only; the wallet engine validates the actual
        // BIP32 curve/key data when restoring. No private material is logged.
        for (compressed, extended) in [(false, Optional<String>.none), (true, "xprv-fixture")] {
            let material = BackupWallet.ImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: ["bitcoin"],
                                                           compressed: compressed, bitcoinExtendedKey: extended)
            let value = BackupWallet(id: UUID(), name: "Bitcoin", mnemonic: "", language: "", createdAt: .now,
                accounts: [.init(network: "bitcoin", derivationPath: "imported", index: 0)], colorHex: "112233", privateKey: material)
            let bytes = try BackupDocument.seal(value, password: "fixture-password")
            let envelope = try JSONDecoder().decode(BackupDocument.Envelope.self, from: bytes)
            XCTAssertEqual(envelope.header.version, 3)
            XCTAssertEqual(try BackupDocument.open(bytes, password: "fixture-password"), value)
            var downgraded = envelope; downgraded.header.version = 1
            XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(downgraded), password: "fixture-password"))
        }
    }

    func testSpecialBitcoinKeyFlagsCannotBeAppliedToOtherNetworks() throws {
        for (networks, compressed, extended) in [(["ethereum"], false, Optional<String>.none), (["bitcoin", "ethereum"], true, "xprv-fixture"), (["bitcoin"], false, "xprv-fixture")] {
            let material = BackupWallet.ImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: networks,
                                                           compressed: compressed, bitcoinExtendedKey: extended)
            let value = BackupWallet(id: UUID(), name: "Invalid", mnemonic: "", language: "", createdAt: .now,
                accounts: networks.map { .init(network: $0, derivationPath: "imported", index: 0) }, privateKey: material)
            XCTAssertThrowsError(try BackupDocument.seal(value, password: "fixture-password"))
        }
    }

    func testDogecoinExtendedAndUncompressedEncryptedRoundTrips() throws {
        for (compressed, extended) in [(false, Optional<String>.none), (true, "dgpv-serialization-fixture")] {
            let material = BackupWallet.ImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: ["dogecoin"],
                compressed: compressed, dogecoinExtendedKey: extended)
            let wallet = BackupWallet(id: UUID(), name: "Doge", mnemonic: "", language: "", createdAt: .now,
                accounts: [.init(network: "dogecoin", derivationPath: "imported", index: 0)], privateKey: material)
            let bytes = try BackupDocument.seal(wallet, password: "fixture-password")
            let envelope = try JSONDecoder().decode(BackupDocument.Envelope.self, from: bytes)
            XCTAssertEqual(envelope.header.version, 4)
            XCTAssertEqual(try BackupDocument.open(bytes, password: "fixture-password"), wallet)
            var downgraded = envelope; downgraded.header.version = 3
            XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(downgraded), password: "fixture-password"))
        }
        let invalid = BackupWallet(id: UUID(), name: "Invalid scope", mnemonic: "", language: "", createdAt: .now,
            accounts: [.init(network: "bitcoin", derivationPath: "imported", index: 0)],
            privateKey: .init(bytes: Data(repeating: 7, count: 32), networks: ["bitcoin"], dogecoinExtendedKey: "dgpv-fixture"))
        XCTAssertThrowsError(try BackupDocument.seal(invalid, password: "fixture-password"))
    }

    func testLitecoinExtendedAndUncompressedEncryptedRoundTrips() throws {
        for (compressed, extended) in [(false, Optional<String>.none), (true, "Ltpv-serialization-fixture")] {
            let material = BackupWallet.ImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: ["litecoin"],
                compressed: compressed, litecoinExtendedKey: extended)
            let wallet = BackupWallet(id: UUID(), name: "Litecoin", mnemonic: "", language: "", createdAt: .now,
                accounts: [.init(network: "litecoin", derivationPath: "imported", index: 0)], privateKey: material)
            let bytes = try BackupDocument.seal(wallet, password: "fixture-password")
            let envelope = try JSONDecoder().decode(BackupDocument.Envelope.self, from: bytes)
            XCTAssertEqual(envelope.header.version, 5)
            XCTAssertEqual(try BackupDocument.open(bytes, password: "fixture-password"), wallet)
            var downgraded = envelope; downgraded.header.version = 3
            XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(downgraded), password: "fixture-password"))
        }
        let invalid = BackupWallet(id: UUID(), name: "Invalid scope", mnemonic: "", language: "", createdAt: .now,
            accounts: [.init(network: "bitcoin", derivationPath: "imported", index: 0)],
            privateKey: .init(bytes: Data(repeating: 7, count: 32), networks: ["bitcoin"], litecoinExtendedKey: "Ltpv-fixture"))
        XCTAssertThrowsError(try BackupDocument.seal(invalid, password: "fixture-password"))
    }

    func testBitcoinCashExtendedAndUncompressedEncryptedRoundTrips() throws {
        for (compressed, extended) in [(false, Optional<String>.none), (true, "xprv-serialization-fixture")] {
            let material = BackupWallet.ImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: ["bitcoincash"],
                compressed: compressed, bitcoinCashExtendedKey: extended)
            let wallet = BackupWallet(id: UUID(), name: "BitcoinCash", mnemonic: "", language: "", createdAt: .now,
                accounts: [.init(network: "bitcoincash", derivationPath: "imported", index: 0)], privateKey: material)
            let bytes = try BackupDocument.seal(wallet, password: "fixture-password")
            let envelope = try JSONDecoder().decode(BackupDocument.Envelope.self, from: bytes)
            XCTAssertEqual(envelope.header.version, 6)
            XCTAssertEqual(try BackupDocument.open(bytes, password: "fixture-password"), wallet)
            var downgraded = envelope; downgraded.header.version = 3
            XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(downgraded), password: "fixture-password"))
        }
        let invalid = BackupWallet(id: UUID(), name: "Invalid scope", mnemonic: "", language: "", createdAt: .now,
            accounts: [.init(network: "bitcoin", derivationPath: "imported", index: 0)],
            privateKey: .init(bytes: Data(repeating: 7, count: 32), networks: ["bitcoin"], bitcoinCashExtendedKey: "xprv-fixture"))
        XCTAssertThrowsError(try BackupDocument.seal(invalid, password: "fixture-password"))
    }

    private var wallet: BackupWallet {
        // Public BIP-39 test vector only. Never use this fixture for funds.
        BackupWallet(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "محفظتي",
            mnemonic: String(repeating: "abandon ", count: 11) + "about", language: "english",
            createdAt: Date(timeIntervalSince1970: 100),
            accounts: [.init(network: "bitcoin", derivationPath: "m/84'/0'/0'/0/0", index: 0)])
    }
    func testRoundTripAndRandomizedCiphertextContainsNoPlaintext() throws {
        let a = try BackupDocument.seal(wallet, password: "fixture-password")
        let b = try BackupDocument.seal(wallet, password: "fixture-password")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try BackupDocument.open(a, password: "fixture-password"), wallet)
        XCTAssertFalse(String(decoding: a, as: UTF8.self).contains(wallet.mnemonic))
        XCTAssertFalse(String(decoding: a, as: UTF8.self).contains(wallet.name))
    }
    func testWrongPasswordAndTamperingFailClosed() throws {
        let data = try BackupDocument.seal(wallet, password: "fixture-password")
        XCTAssertThrowsError(try BackupDocument.open(data, password: "wrong-password")) {
            XCTAssertEqual($0 as? CloudBackupError, .authenticationFailed)
        }
        var envelope = try JSONDecoder().decode(BackupDocument.Envelope.self, from: data)
        envelope.sealed[13] ^= 1
        XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(envelope), password: "fixture-password"))
        envelope = try JSONDecoder().decode(BackupDocument.Envelope.self, from: data)
        envelope.header.salt[0] ^= 1
        XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(envelope), password: "fixture-password"))
    }
    func testBoundsAndUnknownFormatsRejectedBeforeExpensiveKDF() throws {
        for password in ["", "1234567", String(repeating: "x", count: 1025)] {
            XCTAssertThrowsError(try BackupDocument.seal(wallet, password: password))
        }
        let data = try BackupDocument.seal(wallet, password: "12345678")
        var envelope = try JSONDecoder().decode(BackupDocument.Envelope.self, from: data)
        envelope.header.rounds = UInt32.max
        XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(envelope), password: "12345678")) {
            XCTAssertEqual($0 as? CloudBackupError, .invalidDocument)
        }
        XCTAssertThrowsError(try BackupDocument.open(Data(repeating: 0, count: BackupDocument.maximumBytes + 1), password: "12345678"))
    }
    func testUnicodeAndWhitespacePasswordsAreNotSilentlyAltered() throws {
        let password = "  كلمة مرور🔑  "
        let data = try BackupDocument.seal(wallet, password: password)
        XCTAssertEqual(try BackupDocument.open(data, password: password), wallet)
        XCTAssertThrowsError(try BackupDocument.open(data, password: password.trimmingCharacters(in: .whitespaces)))
    }
    func testCoordinatedFileWriteIsAtomicIdempotentAndNeverOverwritesOtherBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(CloudDrive.fileName(UUID()))
        let sealed = try BackupDocument.seal(wallet, password: "fixture-password")
        try CloudFileWriter.write(sealed, to: url)
        try CloudFileWriter.write(sealed, to: url)
        XCTAssertEqual(try BackupDocument.open(Data(contentsOf: url), password: "fixture-password"), wallet)
        XCTAssertThrowsError(try CloudFileWriter.write(Data([0]), to: url)) {
            XCTAssertEqual($0 as? CloudBackupError, .fileConflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), sealed)
    }
    func testCanonicalUnicodePasswordsMatchAcrossKeyboardEncodings() throws {
        let composed = "caf\u{00e9}-fixture"
        let decomposed = "cafe\u{0301}-fixture"
        XCTAssertEqual(composed, decomposed, "Native confirmation considers these the same password")
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let sealed = try BackupDocument.seal(wallet, password: composed)
        XCTAssertEqual(try BackupDocument.open(sealed, password: decomposed), wallet)
    }

    func testNameAndCustomArtworkSurviveEncryptedRoundTrip() throws {
        let customized = BackupWallet(id: wallet.id, name: "ادخار 🏡", mnemonic: wallet.mnemonic,
            language: wallet.language, createdAt: wallet.createdAt, accounts: wallet.accounts, colorHex: "DF438D")
        let encrypted = try BackupDocument.seal(customized, password: "fixture-password")
        let restored = try BackupDocument.open(encrypted, password: "fixture-password")
        XCTAssertEqual(restored, customized)
        XCTAssertEqual(restored.name, "ادخار 🏡")
        XCTAssertEqual(restored.colorHex, "DF438D")
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains(customized.name))
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("DF438D"))
    }

    func testOlderBackupPayloadWithoutColorKeepsNameAndOriginalPalette() throws {
        // The original version-1 payload has no colorHex field. Optional
        // encoding here produces precisely that same field set and envelope.
        let plaintext = try JSONEncoder().encode(wallet)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        XCTAssertNil(fields["colorHex"])
        let decoded = try JSONDecoder().decode(BackupWallet.self, from: plaintext)
        XCTAssertNil(decoded.colorHex)
        let restored = try BackupDocument.open(BackupDocument.seal(decoded, password: "fixture-password"), password: "fixture-password")
        XCTAssertEqual(restored.name, wallet.name)
        XCTAssertNil(restored.colorHex)
    }

    func testMalformedArtworkIsRejectedBeforeEncryption() throws {
        for color in ["", "#FF0000", "ff0000", "12345", "1234567", "GG0000", "１２３４５６"] {
            let invalid = BackupWallet(id: wallet.id, name: wallet.name, mnemonic: wallet.mnemonic,
                language: wallet.language, createdAt: wallet.createdAt, accounts: wallet.accounts, colorHex: color)
            XCTAssertThrowsError(try BackupDocument.seal(invalid, password: "fixture-password")) {
                XCTAssertEqual($0 as? CloudBackupError, .invalidDocument)
            }
        }
    }
}
