import XCTest
import WalletCore
import CryptoKit
@testable import OathAtmosphere

final class OathPrivateKeyImportTests: XCTestCase {
    // Public BIP-39 vector only; never read a user's Keychain or pasteboard.
    private let fixture = String(repeating: "abandon ", count: 11) + "about"

    func testExportedKeysImportIntoTheSameAccountsForEverySupportedChain() throws {
        let source = OathWalletSecret(id: UUID(), mnemonic: fixture, language: "english", createdAt: .now, backedUp: true)
        let original = try OathWalletEngine.profile(for: source)
        for choice in OathPrivateKeyChoice.all {
            let chain = try XCTUnwrap(choice.networks.first)
            let address = try XCTUnwrap(original.addresses.first { $0.chain == chain })
            let account = OathPrivateKeyAccount(id: chain.id, chain: chain, address: address.address, path: address.path)
            let exported = try OathWalletEngine.privateKey(for: source, account: account)
            let material = try OathWalletEngine.importedPrivateKey(exported.value, choice: choice)
            let imported = try OathWalletEngine.imported(material)
            let profile = try OathWalletEngine.profile(for: imported)
            XCTAssertTrue(imported.mnemonic.isEmpty && imported.language.isEmpty)
            XCTAssertEqual(Set(profile.addresses.map(\.chain)), Set(choice.networks))
            for result in profile.addresses {
                XCTAssertEqual(result.address, original.addresses.first { $0.chain == result.chain }?.address, result.chain.id)
                XCTAssertEqual(result.path, "imported")
                let reexport = try OathWalletEngine.privateKey(for: imported,
                    account: .init(id: result.id, chain: result.chain, address: result.address, path: result.path))
                let roundTrip = try OathWalletEngine.importedPrivateKey(reexport.value, choice: choice)
                XCTAssertTrue(roundTrip.bytes == material.bytes)
            }
        }
    }

    func testInvalidInputChecksumsNetworksAndAlgorithmsAreRejected() throws {
        let key = try XCTUnwrap(PrivateKey(data: Data(repeating: 7, count: 32)))
        let bitcoin = try XCTUnwrap(OathPrivateKeyChoice.individual.first { $0.id == "bitcoin" })
        let litecoin = try XCTUnwrap(OathPrivateKeyChoice.individual.first { $0.id == "litecoin" })
        let wif = Base58.encode(data: Data([0x80]) + key.data + Data([1]))
        XCTAssertNoThrow(try OathWalletEngine.importedPrivateKey(wif, choice: bitcoin))
        XCTAssertThrowsError(try OathWalletEngine.importedPrivateKey(wif, choice: litecoin))
        XCTAssertThrowsError(try OathWalletEngine.importedPrivateKey(Base58.encode(data: Data([0x80]) + key.data), choice: bitcoin))
        XCTAssertThrowsError(try OathWalletEngine.importedPrivateKey(String(wif.dropLast()) + (wif.last == "1" ? "2" : "1"), choice: bitcoin))
        for invalid in ["", "0x", String(repeating: "0", count: 64), String(repeating: "f", count: 64),
                        String(repeating: "1", count: 63), String(repeating: "1", count: 65),
                        "0x" + String(repeating: "z", count: 64), String(repeating: "a", count: 2_049)] {
            XCTAssertThrowsError(try OathWalletEngine.importedPrivateKey(invalid, choice: .evm))
        }
        let sui = try XCTUnwrap(OathPrivateKeyChoice.individual.first { $0.id == "sui" })
        XCTAssertThrowsError(try OathWalletEngine.importedPrivateKey(Bech32.encode(hrp: "suiprivkey", data: Data([1]) + key.data), choice: sui))
        let stellar = try XCTUnwrap(OathPrivateKeyChoice.individual.first { $0.id == "stellar" })
        XCTAssertThrowsError(try OathWalletEngine.importedPrivateKey(Base32.encode(data: Data([144]) + key.data + Data([0, 0])), choice: stellar))
    }

    func testSolanaKeypairPublicHalfMustMatchAndJSONIsSupported() throws {
        let choice = try XCTUnwrap(OathPrivateKeyChoice.individual.first { $0.id == "solana" })
        let key = try XCTUnwrap(PrivateKey(data: Data(repeating: 7, count: 32)))
        let pair = key.data + key.getPublicKeyEd25519().data
        let json = String(decoding: try JSONEncoder().encode(Array(pair)), as: UTF8.self)
        let imported = try OathWalletEngine.importedPrivateKey(json, choice: choice)
        XCTAssertTrue(imported.bytes == key.data)
        var mismatched = pair
        mismatched[63] ^= 1
        XCTAssertThrowsError(try OathWalletEngine.importedPrivateKey(Base58.encodeNoCheck(data: mismatched), choice: choice))
        XCTAssertThrowsError(try OathWalletEngine.importedPrivateKey(Base58.encodeNoCheck(data: key.data), choice: choice))
    }

    func testImportedKeyExportRejectsWrongAccountScopePathAndAddress() throws {
        let material = OathImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: [.ethereum])
        let secret = try OathWalletEngine.imported(material)
        let address = try XCTUnwrap(OathWalletEngine.profile(for: secret).addresses.first)
        for (chain, value, path) in [(OathImportChain.ethereum, address.address, "m/44'/60'/0'/0/0"),
                                    (.base, address.address, "imported"), (.ethereum, "wrong", "imported")] {
            XCTAssertThrowsError(try OathWalletEngine.privateKey(for: secret,
                account: .init(id: "fixture", chain: chain, address: value, path: path)))
        }
        var ambiguous = secret
        ambiguous.privateKey = .init(bytes: material.bytes, networks: [.ethereum, .solana])
        XCTAssertThrowsError(try OathVaultContents(wallets: [ambiguous]).validate(rootID: secret.id))
    }
}
