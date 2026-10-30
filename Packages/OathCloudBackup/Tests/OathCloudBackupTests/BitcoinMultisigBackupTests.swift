import XCTest
@testable import OathCloudBackup

final class BitcoinMultisigBackupTests: XCTestCase {
    // Serialization fixtures only; the app separately validates keys and derives addresses.
    private let signers: [BackupWallet.BitcoinMultisig.Signer] = [
        .init(wif: "K" + String(repeating: "1", count: 51)),
        .init(mnemonic: String(repeating: "abandon ", count: 11) + "about", language: "english", passphrase: " public fixture ")
    ]
    private func wallet(_ material: BackupWallet.BitcoinMultisig, mnemonic: String = "", accounts: [BackupWallet.Account]? = nil) -> BackupWallet {
        .init(id: UUID(), name: "Fixture", mnemonic: mnemonic, language: "", createdAt: .now,
              accounts: accounts ?? [.init(network: "bitcoin", derivationPath: "m/48'/0'/0'/2'/0/0", index: 0)], bitcoinMultisig: material)
    }
    func testEncryptedRoundTripPreservesThresholdAndEverySigner() throws {
        let original = wallet(.init(required: 2, signers: signers))
        let bytes = try BackupDocument.seal(original, password: "fixture-password")
        let header = try JSONDecoder().decode(BackupDocument.Envelope.self, from: bytes)
        XCTAssertEqual(header.header.version, 8)
        let restored = try BackupDocument.open(bytes, password: "fixture-password")
        XCTAssertTrue(restored == original, "Encrypted recovery must preserve all material exactly")
        for text in [signers[0].wif!, signers[1].mnemonic!, signers[1].passphrase!] {
            XCTAssertNil(bytes.range(of: Data(text.utf8)))
        }
        XCTAssertThrowsError(try BackupDocument.open(bytes, password: "wrong-password"))
        var downgraded = header; downgraded.header.version = 7
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
            XCTAssertThrowsError(try BackupDocument.seal(wallet(policy), password: "fixture-password"))
        }
        let valid = BackupWallet.BitcoinMultisig(required: 2, signers: signers)
        XCTAssertThrowsError(try BackupDocument.seal(wallet(valid, mnemonic: "ambiguous"), password: "fixture-password"))
        for accounts: [BackupWallet.Account] in [[], [.init(network: "ethereum", derivationPath: "m/48'/0'/0'/2'/0/0", index: 0)],
             [.init(network: "bitcoin", derivationPath: "m/84'/0'/0'/0/0", index: 0)],
             [.init(network: "bitcoin", derivationPath: "m/48'/0'/0'/2'/0/0", index: 1)]] {
            XCTAssertThrowsError(try BackupDocument.seal(wallet(valid, accounts: accounts), password: "fixture-password"))
        }
    }
}
