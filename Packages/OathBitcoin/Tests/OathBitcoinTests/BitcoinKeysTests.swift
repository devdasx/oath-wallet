import XCTest
import BitcoinDevKit
import CryptoKit
@testable import OathBitcoin

final class BitcoinKeysTests: XCTestCase {
    // Public BIP84/BIP86 test vector, never use these words for real funds.
    static let words = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    static func wallet() throws -> BitcoinWalletDescriptor {
        let mnemonic = try Mnemonic.fromString(mnemonic: words)
        let key = DescriptorSecretKey(networkKind: .main, mnemonic: mnemonic, password: nil)
        return try BitcoinKeys.extended(key.description, defaultType: .nativeSegwit)
    }
    func testFinalNormalChildMatchesIndependentBIP44ScriptsAndExports() throws {
        // Synthetic seed 00...1f. Expected P2PKH scripts computed with OpenSSL and BIP32 HMAC-SHA512.
        let scripts: [UTXONetwork: String] = [
            .bitcoin: "76a91428a14196f50a64075abed24de16d6b0e8b56256688ac",
            .bitcoincash: "76a91489d703ce6370ecb5721bcd00a55939f37ccfc8a188ac",
            .dogecoin: "76a91450e4725efe58aabadf8f50dbb4b6208d5eb1a71e88ac",
            .litecoin: "76a91425231776cdd41631012a1ae248160f7137d1b1c188ac",
        ]
        let seed = Data(0..<32)
        for (network, expected) in scripts {
            let branch = try XCTUnwrap(network.wallet(seed: seed).branches.first { $0.change == 0 && $0.type == .legacy })
            let leaf = try XCTUnwrap(BitcoinKeys.addresses(branch: branch, range: 0x7fff_ffff..<0x8000_0000).first)
            XCTAssertEqual(leaf.script, expected)
            let wif = try network.privateKeyWIF(source: .seed(seed, account: 0), address: leaf)
            let decoded = try network.decodeImport(wif)
            let single = try XCTUnwrap(network.singleKey(bytes: decoded.bytes, compressed: decoded.compressed).branches.first { $0.type == .legacy })
            XCTAssertEqual(try BitcoinKeys.addresses(branch: single, range: 0..<1).first?.script, expected)
        }
    }

    func testFinalNormalChildStillRejectsHardenedAndFixedKeys() throws {
        let branch = try XCTUnwrap(Self.wallet().branches.first)
        XCTAssertThrowsError(try BitcoinKeys.addresses(branch: branch, range: 0x8000_0000..<0x8000_0001))
        let fixed = try XCTUnwrap(BitcoinKeys.singleKey(bytes: Data(1...32), compressed: true).branches.first)
        XCTAssertThrowsError(try BitcoinKeys.addresses(branch: fixed, range: 0x7fff_ffff..<0x8000_0000))
    }

    func testPublishedBIPAddresses() throws {
        let wallet = try Self.wallet()
        let expected: [BitcoinAddressType: String] = [
            .legacy: "1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA",
            .nestedSegwit: "37VucYSaXLCAsxYyAPfbSi9eh4iEcbShgf",
            .nativeSegwit: "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
            .taproot: "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"]
        XCTAssertEqual(wallet.branches.count, 8)
        for branch in wallet.branches where branch.change == 0 {
            let address = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0]
            XCTAssertEqual(address.address, expected[branch.type])
            XCTAssertEqual(address.scriptHash.count, 64)
            XCTAssertFalse(branch.descriptor.contains("prv"))
        }
    }
    func testUncompressedKeyIsFiniteLegacyOnly() throws {
        let bytes = Data(repeating: 0, count: 31) + Data([1])
        let wallet = try BitcoinKeys.singleKey(bytes: bytes, compressed: false)
        XCTAssertEqual(wallet.types, [.legacy])
        XCTAssertEqual(try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<1)[0].address, "1EHNa6Q4Jz2uvNExL497mE43ikXhwF6kZm")
        XCTAssertThrowsError(try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<20))
        let wif = try BitcoinKeys.wif(bytes: bytes, compressed: false)
        XCTAssertFalse(try BitcoinKeys.decodeImport(wif).compressed)
    }
    func testCompressedKeyHasAllFourTypes() throws {
        let bytes = Data(repeating: 0, count: 31) + Data([1])
        let wallet = try BitcoinKeys.singleKey(bytes: bytes, compressed: true)
        XCTAssertEqual(wallet.branches.count, 4)
        XCTAssertTrue(wallet.branches.allSatisfy { !$0.isHD })
        let values = try wallet.branches.map { try BitcoinKeys.addresses(branch: $0, range: 0..<1)[0].address }
        XCTAssertEqual(Set(values).count, 4)
        XCTAssertTrue(values.contains("1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"))
    }
    func testBIP39SeedMatchesAllPublishedAddresses() throws {
        let seed = try XCTUnwrap(Data(hex: "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4"))
        let fromSeed = try BitcoinKeys.wallet(seed: seed)
        let fromWords = try Self.wallet()
        for (a,b) in zip(fromSeed.branches, fromWords.branches) {
            XCTAssertEqual(try BitcoinKeys.addresses(branch: a, range: 0..<20).map(\.address),
                           try BitcoinKeys.addresses(branch: b, range: 0..<20).map(\.address))
        }
    }
    func testExtendedPrivateAndPublicVersionFamiliesRoundTrip() throws {
        let root = DescriptorSecretKey(networkKind: .main, mnemonic: try Mnemonic.fromString(mnemonic: Self.words), password: nil)
        for (purpose, prvVersion, pubVersion) in [(44, UInt32(0x0488ade4), UInt32(0x0488b21e)), (49, 0x049d7878, 0x049d7cb2), (84, 0x04b2430c, 0x04b24746)] {
            let key = try root.derive(path: DerivationPath(path: "m/\(purpose)'/0'/0'"))
            // Origins are valid descriptor syntax, but users import the actual
            // extended key. Extract its Base58Check payload for SLIP132 tests.
            let privateText = String(key.description.split(separator: "]").last!)
            let publicText = String(key.asPublic().description.split(separator: "]").last!)
            func version(_ text: String, _ version: UInt32) throws -> String {
                var bytes = try Base58Check.decode(text)
                bytes.replaceSubrange(0..<4, with: [24,16,8,0].map { UInt8(truncatingIfNeeded: version >> $0) })
                return Base58Check.encode(bytes)
            }
            let prv = try version(privateText, prvVersion); let pub = try version(publicText, pubVersion)
            let privateWallet = try BitcoinKeys.extended(prv)
            let publicWallet = try BitcoinKeys.extended(pub)
            XCTAssertTrue(privateWallet.scopedImport)
            XCTAssertEqual(privateWallet.defaultType.rawValue, purpose)
            for (a,b) in zip(privateWallet.branches, publicWallet.branches) {
                XCTAssertEqual(try BitcoinKeys.addresses(branch: a, range: 0..<20).map(\.address),
                               try BitcoinKeys.addresses(branch: b, range: 0..<20).map(\.address))
            }
            let imported = try BitcoinKeys.decodeImport(prv)
            XCTAssertEqual(imported.extended, prv)
            XCTAssertEqual(imported.bytes.count, 32)
        }
    }
    func testInvalidKeysAndUnsupportedNetworksFailClosed() throws {
        let root = DescriptorSecretKey(networkKind: .test, mnemonic: try Mnemonic.fromString(mnemonic: Self.words), password: nil)
        XCTAssertThrowsError(try BitcoinKeys.extended(root.description))
        for value in ["", "xprv1234", String(repeating: "0", count: 64), String(repeating: "f", count: 64), String(repeating: "x", count: 2048)] {
            XCTAssertThrowsError(try BitcoinKeys.decodeImport(value))
        }
        let main = DescriptorSecretKey(networkKind: .main, mnemonic: try Mnemonic.fromString(mnemonic: Self.words), password: nil)
        XCTAssertThrowsError(try BitcoinKeys.extended(main.asPublic().description))
    }

    func testLegacyImportOwnershipPublicKeyMatchesPublishedBIP84Address() throws {
        let root = DescriptorSecretKey(networkKind: .main, mnemonic: try Mnemonic.fromString(mnemonic: Self.words), password: nil)
        let key = try BitcoinKeys.importPublicKey(root.description, relativePath: "m/84'/0'/0'/0/0")
        let descriptor = try Descriptor(descriptor: "wpkh(\(key.hex))", networkKind: .main)
        XCTAssertEqual(try descriptor.deriveAddress(index: 0, network: .bitcoin).description,
                       "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
        XCTAssertThrowsError(try BitcoinKeys.importPublicKey(root.asPublic().description, relativePath: "m/0"))
        XCTAssertThrowsError(try BitcoinKeys.importPublicKey(root.description, relativePath: "m" + String(repeating: "/0", count: 33)))
    }
}
