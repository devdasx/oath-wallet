import XCTest
@testable import OathCloudBackup

final class AptosMultisigBackupTests: XCTestCase {
    // Shape-only serialization fixtures. Crypto identities are checked in the app.
    private var signers: [BackupWallet.AptosMultisig.Signer] {
        [.init(publicKey: Data(repeating: 1, count: 32), key: Data(repeating: 1, count: 32)),
         .init(publicKey: Data(repeating: 2, count: 32), mnemonic: String(repeating: "abandon ", count: 11) + "about", language: "english", passphrase: " public fixture ")]
    }
    private func wallet(required: Int = 2, signers: [BackupWallet.AptosMultisig.Signer]? = nil, network: String = "aptos") -> BackupWallet {
        .init(id: UUID(), name: "Fixture", mnemonic: "", language: "", createdAt: .now,
            accounts: [.init(network: network, derivationPath: "aptos-multisig-v1", index: 0)],
            aptosMultisig: .init(required: required, address: "0x" + String(repeating: "c", count: 64), signers: signers ?? self.signers))
    }
    func testEncryptedRoundTripPreservesAccountAndEverySigner() throws {
        let original = wallet(), encrypted = try BackupDocument.seal(original, password: "fixture-password")
        let envelope = try JSONDecoder().decode(BackupDocument.Envelope.self, from: encrypted)
        XCTAssertEqual(envelope.header.version, 13)
        XCTAssertTrue(try BackupDocument.open(encrypted, password: "fixture-password") == original)
        XCTAssertNil(encrypted.range(of: Data(signers[1].mnemonic!.utf8)))
        XCTAssertNil(encrypted.range(of: Data(signers[1].passphrase!.utf8)))
        XCTAssertThrowsError(try BackupDocument.open(encrypted, password: "wrong-password"))
        var downgraded = envelope; downgraded.header.version = 12
        XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(downgraded), password: "fixture-password"))
    }
    func testRejectsImpossibleAndAmbiguousRecovery() throws {
        for invalid in [wallet(required: 0), wallet(required: 3), wallet(signers: []), wallet(signers: [signers[0]]),
                        wallet(signers: [signers[0],signers[0]]), wallet(network: "bitcoin"),
                        wallet(signers: [.init(publicKey: signers[0].publicKey, key: Data(repeating: 1, count: 32), mnemonic: "ambiguous"),signers[1]])] {
            XCTAssertThrowsError(try BackupDocument.seal(invalid, password: "fixture-password"))
        }
    }
}
