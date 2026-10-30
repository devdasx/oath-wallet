import XCTest
import OathCloudBackup
import WalletCore
@testable import OathAtmosphere

final class OathCloudRestoreTests: XCTestCase {
    // Public BIP-39 test vector only.
    private let words = String(repeating: "abandon ", count: 11) + "about"

    func testRestoreDerivesOriginalNondefaultAccountsAndPassphrase() throws {
        let accounts: [BackupWallet.Account] = [
            .init(network: "ethereum", derivationPath: "m/44'/60'/0'/0/0", index: 0),
            .init(network: "ethereum", derivationPath: "m/44'/60'/3'/0/2", index: 3),
            .init(network: "solana", derivationPath: "m/44'/501'/1'", index: 1)
        ]
        let backup = BackupWallet(id: UUID(), name: "Travel", mnemonic: words, language: "english",
            createdAt: Date(timeIntervalSince1970: 123), accounts: accounts, colorHex: "DF438D", passphrase: "TREZOR")
        let document = try BackupDocument.seal(backup, password: "fixture-password")
        let restored = try OathRestoredWallet(backup: BackupDocument.open(document, password: "fixture-password"))
        let wallet = try XCTUnwrap(HDWallet(mnemonic: words, passphrase: "TREZOR"))
        XCTAssertEqual(restored.profile.addresses.count, 3)
        for (address, account) in zip(restored.profile.addresses, accounts) {
            let chain = try XCTUnwrap(OathImportChain(rawValue: account.network))
            let key = try XCTUnwrap(wallet.getKey(coin: chain.walletCoin, derivationPath: account.derivationPath))
            XCTAssertTrue(address.address == chain.walletCoin.deriveAddress(privateKey: key))
            XCTAssertEqual(address.path, account.derivationPath)
            XCTAssertEqual(address.accountIndex, account.index)
        }
        XCTAssertTrue(restored.secret.passphrase == "TREZOR")
        // Restored wallets receive a fresh localized default name; account identity remains exact.
        XCTAssertEqual(restored.secret.restoration?.name, "")
        XCTAssertEqual(restored.secret.restoration?.colorHex, "DF438D")
        XCTAssertFalse(restored.secret.createdWithCustomization == true)
    }

    func testRawPrivateKeyBackupRetainsNetworkScope() throws {
        let bytes = Data(repeating: 7, count: 32)
        let backup = BackupWallet(id: UUID(), name: "Key wallet", mnemonic: "", language: "", createdAt: .now,
            accounts: ["ethereum", "base"].map { .init(network: $0, derivationPath: "imported", index: 0) },
            privateKey: .init(bytes: bytes, networks: ["ethereum", "base"]))
        let restored = try OathRestoredWallet(backup: backup)
        XCTAssertEqual(Set(restored.profile.addresses.map(\.chain)), [.ethereum, .base])
        let key = try XCTUnwrap(PrivateKey(data: bytes))
        XCTAssertTrue(restored.profile.addresses.allSatisfy { $0.address == CoinType.ethereum.deriveAddress(privateKey: key) })
    }

    func testRestoreRejectsInvalidRecoveryMaterialBeforeSaving() {
        for phrase in ["not a recovery phrase", String(repeating: "abandon ", count: 12)] {
            let invalid = BackupWallet(id: UUID(), name: "Invalid fixture", mnemonic: phrase, language: "english", createdAt: .now,
                accounts: [.init(network: "ethereum", derivationPath: "m/44'/60'/0'/0/0", index: 0)])
            XCTAssertThrowsError(try OathRestoredWallet(backup: invalid))
        }
        let zeroKey = BackupWallet(id: UUID(), name: "Invalid key", mnemonic: "", language: "", createdAt: .now,
            accounts: [.init(network: "ethereum", derivationPath: "imported", index: 0)],
            privateKey: .init(bytes: Data(repeating: 0, count: 32), networks: ["ethereum"]))
        XCTAssertThrowsError(try OathRestoredWallet(backup: zeroKey))
    }

    func testDifferentIndicesCannotRestoreTheSameNetworkAddressTwice() {
        let backup = BackupWallet(id: UUID(), name: "Invalid duplicated account", mnemonic: words, language: "english", createdAt: .now,
            accounts: [0, 1].map { .init(network: "ethereum", derivationPath: "m/44'/60'/0'/0/0", index: $0) })
        XCTAssertThrowsError(try OathRestoredWallet(backup: backup)) {
            XCTAssertEqual($0 as? CloudBackupError, .invalidDocument)
        }
    }
}
