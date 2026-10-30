import XCTest
@testable import OathCloudBackup

final class BitcoinCashMultisigBackupTests: XCTestCase {
    // Serialization fixtures only; the app separately validates keys and derives addresses.
    private let signers: [BackupWallet.BitcoinMultisig.Signer] = [
        .init(wif: "T" + String(repeating: "1", count: 51)),
        .init(mnemonic: String(repeating: "abandon ", count: 11) + "about", language: "english", passphrase: " public fixture ")
    ]
    private func wallet(_ material: BackupWallet.BitcoinMultisig, mnemonic: String = "", accounts: [BackupWallet.Account]? = nil) -> BackupWallet {
        .init(id: UUID(), name: "Fixture", mnemonic: mnemonic, language: "", createdAt: .now,
              accounts: accounts ?? [.init(network: "bitcoincash", derivationPath: "m/48'/145'/0'/0'/0/0", index: 0)], bitcoinMultisig: material)
    }
    func testEncryptedRoundTripPreservesThresholdAndEverySigner() throws {
        let original = wallet(.init(required: 2, signers: signers, network: "bitcoincash"))
        let bytes = try BackupDocument.seal(original, password: "fixture-password")
        let header = try JSONDecoder().decode(BackupDocument.Envelope.self, from: bytes)
        XCTAssertEqual(header.header.version, 19)
        let restored = try BackupDocument.open(bytes, password: "fixture-password")
        XCTAssertTrue(restored == original, "Encrypted recovery must preserve all material exactly")
        for text in [signers[0].wif!, signers[1].mnemonic!, signers[1].passphrase!] {
            XCTAssertNil(bytes.range(of: Data(text.utf8)))
        }
        XCTAssertThrowsError(try BackupDocument.open(bytes, password: "wrong-password"))
        var downgraded = header; downgraded.header.version = 18
        XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(downgraded), password: "fixture-password"))
    }
    func testRejectsMissingKeysImpossibleThresholdAndAmbiguousMaterial() throws {
        let policies: [BackupWallet.BitcoinMultisig] = [
            .init(required: 0, signers: signers), .init(required: 3, signers: signers),
            .init(required: 1, signers: []), .init(required: 1, signers: [signers[0]]),
            .init(required: 2, signers: Array(repeating: signers[0], count: 16)),
            .init(required: 2, signers: [signers[0], .init(wif: signers[0].wif, mnemonic: "ambiguous", language: "english")]),
            .init(required: 2, signers: [signers[0], .init(mnemonic: "fixture", language: "english", passphrase: String(repeating: "a", count: 257))])
        ]
        for policy in policies {
            XCTAssertThrowsError(try BackupDocument.seal(wallet(.init(required: policy.required, signers: policy.signers, network: "bitcoincash")), password: "fixture-password"))
        }
        let bitcoin = BackupWallet.BitcoinMultisig(required: 2, signers: signers)
        let bitcoincash = BackupWallet.BitcoinMultisig(required: 2, signers: signers, network: "bitcoincash")
        XCTAssertFalse(bitcoin.hasSameMaterial(as: bitcoincash))
        XCTAssertFalse(BackupWallet.BitcoinMultisig(required: 2, signers: signers, network: "unsupported").isValidStructure)
        let legacy = try JSONDecoder().decode(BackupWallet.BitcoinMultisig.self, from: JSONEncoder().encode(bitcoin))
        XCTAssertEqual(legacy.chainID, "bitcoin")
        XCTAssertTrue(legacy.isValidStructure)
        let valid = BackupWallet.BitcoinMultisig(required: 2, signers: signers, network: "bitcoincash")
        XCTAssertThrowsError(try BackupDocument.seal(wallet(valid, mnemonic: "ambiguous"), password: "fixture-password"))
        for accounts: [BackupWallet.Account] in [[], [.init(network: "bitcoin", derivationPath: "m/48'/0'/0'/2'/0/0", index: 0)], [.init(network: "ethereum", derivationPath: "m/48'/145'/0'/0'/0/0", index: 0)],
             [.init(network: "bitcoincash", derivationPath: "m/84'/0'/0'/0/0", index: 0)],
             [.init(network: "bitcoincash", derivationPath: "m/48'/145'/0'/0'/0/0", index: 1)]] {
            XCTAssertThrowsError(try BackupDocument.seal(wallet(valid, accounts: accounts), password: "fixture-password"))
        }
    }
}
