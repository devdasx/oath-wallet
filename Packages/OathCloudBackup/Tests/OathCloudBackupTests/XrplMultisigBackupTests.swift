import XCTest
@testable import OathCloudBackup

final class XrplMultisigBackupTests: XCTestCase {
    // Shape-only serialization fixtures. Crypto identities are checked in the app.
    private var signers: [BackupWallet.XrplMultisig.Signer] {
        [.init(address: String(repeating: "A", count: 34), key: Data(repeating: 1, count: 32)),
         .init(address: String(repeating: "B", count: 34), mnemonic: String(repeating: "abandon ", count: 11) + "about", language: "english", passphrase: " public fixture ")]
    }
    private func wallet(required: Int = 2, signers: [BackupWallet.XrplMultisig.Signer]? = nil, network: String = "xrpl") -> BackupWallet {
        .init(id: UUID(), name: "Fixture", mnemonic: "", language: "", createdAt: .now,
            accounts: [.init(network: network, derivationPath: "xrpl-multisig-v1", index: 0)],
            xrplMultisig: .init(required: required, accountKey: Data(repeating: 3, count: 32), address: String(repeating: "C", count: 34), signers: signers ?? self.signers))
    }
    func testEncryptedRoundTripPreservesAccountAndEverySigner() throws {
        let original = wallet(), encrypted = try BackupDocument.seal(original, password: "fixture-password")
        let envelope = try JSONDecoder().decode(BackupDocument.Envelope.self, from: encrypted)
        XCTAssertEqual(envelope.header.version, 11)
        XCTAssertTrue(try BackupDocument.open(encrypted, password: "fixture-password") == original)
        XCTAssertNil(encrypted.range(of: Data(signers[1].mnemonic!.utf8)))
        XCTAssertNil(encrypted.range(of: Data(signers[1].passphrase!.utf8)))
        XCTAssertThrowsError(try BackupDocument.open(encrypted, password: "wrong-password"))
        var downgraded = envelope; downgraded.header.version = 10
        XCTAssertThrowsError(try BackupDocument.open(JSONEncoder().encode(downgraded), password: "fixture-password"))
    }
    func testRejectsImpossibleAndAmbiguousRecovery() throws {
        for invalid in [wallet(required: 0), wallet(required: 3), wallet(signers: []), wallet(signers: [signers[0]]),
                        wallet(signers: [signers[0],signers[0]]), wallet(network: "bitcoin"),
                        wallet(signers: [.init(address: signers[0].address, key: Data(repeating: 1, count: 32), mnemonic: "ambiguous"),signers[1]])] {
            XCTAssertThrowsError(try BackupDocument.seal(invalid, password: "fixture-password"))
        }
    }
}
