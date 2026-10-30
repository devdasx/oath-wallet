import Foundation
import XCTest
@testable import OathBitcoin

final class BitcoinPrivateKeysTests: XCTestCase {
    func testIndependentLeafWIFVectorsForAllNetworksTypesAndBothPaths() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "private-key-vectors", withExtension: "json"))
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let seed = Data(hex: fixture["seed"] as! String)!
        for row in fixture["vectors"] as! [[String: Any]] {
            let network = UTXONetwork(rawValue: row["network"] as! String)!
            let type = BitcoinAddressType(rawValue: row["purpose"] as! Int)!
            let account = UInt32(row["account"] as! Int), change = UInt32(row["change"] as! Int), index = UInt32(row["index"] as! Int)
            let descriptor = try network.wallet(seed: seed, account: account)
            let branch = try XCTUnwrap(descriptor.branches.first { $0.type == type && $0.change == change })
            let address = try BitcoinKeys.addresses(branch: branch, range: index..<(index + 1))[0]
            let wif = try network.privateKeyWIF(source: .seed(seed, account: account), address: address)
            XCTAssertTrue(wif == row["wif"] as! String, "Independent leaf WIF mismatch: \(network) \(address.path)")
            let decoded = try network.decodeImport(wif)
            XCTAssertNil(decoded.extended)
            let leaf = try network.singleKey(bytes: decoded.bytes, compressed: decoded.compressed)
            let leafBranch = try XCTUnwrap(leaf.branches.first { $0.type == type })
            XCTAssertEqual(try BitcoinKeys.addresses(branch: leafBranch, range: 0..<1)[0].address, address.address)
        }
    }

    func testExtendedRootAndScopedImportsExportLeafInsteadOfParent() throws {
        for network in UTXONetwork.allCases {
            let fixtureName = network == .bitcoin ? "litecoin" : network.rawValue
            let url = try XCTUnwrap(Bundle.module.url(forResource: fixtureName + "-vectors", withExtension: "json"))
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var imports = [(fixture["rootXprv"] ?? fixture["root"]) as! String]
            if network != .bitcoin { imports.append(fixture["root"] as! String) }
            // Non-root scopes from independent Python BIP32 fixtures include
            // purpose, coin, account, single branch, and single leaf imports.
            if network == .litecoin {
                for scope in fixture["scopes"] as! [[String: Any]] {
                    imports.append((scope["keys"] as! [String: String])["Ltpv"]!)
                }
            } else if network == .bitcoincash {
                imports += (fixture["scopes"] as! [[String: Any]]).map { $0["private"] as! String }
            } else if network == .dogecoin {
                imports += [fixture["accountPrivate"] as! String, fixture["accountXprv"] as! String]
            }
            for text in imports {
                let wallet = try network.extended(text)
                for branch in wallet.branches {
                    let index: UInt32 = branch.isHD ? 7 : 0
                    let address = try BitcoinKeys.addresses(branch: branch, range: index..<(index + 1))[0]
                    let wif = try network.privateKeyWIF(source: .extended(text), address: address)
                    XCTAssertNotEqual(wif, text)
                    let decoded = try network.decodeImport(wif)
                    XCTAssertNil(decoded.extended)
                    let leaf = try network.singleKey(bytes: decoded.bytes, compressed: true)
                    let selected = try XCTUnwrap(leaf.branches.first { $0.type == address.type })
                    XCTAssertEqual(try BitcoinKeys.addresses(branch: selected, range: 0..<1)[0].address, address.address)
                }
            }
        }
    }

    func testSingleCompressedAndUncompressedKeyScopes() throws {
        let bytes = Data(repeating: 0, count: 31) + Data([1])
        for network in UTXONetwork.allCases {
            for compressed in [true, false] {
                let wallet = try network.singleKey(bytes: bytes, compressed: compressed)
                XCTAssertTrue(wallet.branches.allSatisfy { !$0.isHD })
                for branch in wallet.branches {
                    let address = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0]
                    let wif = try network.privateKeyWIF(source: .single(bytes, compressed: compressed), address: address)
                    let decoded = try network.decodeImport(wif)
                    XCTAssertTrue(decoded.bytes == bytes)
                    XCTAssertEqual(decoded.compressed, compressed)
                }
            }
        }
    }

    func testMismatchedAddressPathIndexTypeWalletAndNetworkAreRejected() throws {
        let seed = Data(0..<32)
        for network in UTXONetwork.allCases {
            let wallet = try network.wallet(seed: seed)
            let address = try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<1)[0]
            let variants: [BitcoinDerivedAddress] = [
                .init(branchID: address.branchID, type: address.type, change: address.change, index: 1, path: address.path, address: address.address, script: address.script, scriptHash: address.scriptHash),
                .init(branchID: address.branchID, type: address.type, change: address.change, index: 0, path: "m/44'/0'/9'/0/0", address: address.address, script: address.script, scriptHash: address.scriptHash),
                .init(branchID: address.branchID, type: address.type, change: address.change, index: 0, path: address.path, address: "wrong-address", script: address.script, scriptHash: address.scriptHash),
                .init(branchID: "84:99", type: address.type, change: 99, index: 0, path: address.path, address: address.address, script: address.script, scriptHash: address.scriptHash)
            ]
            for invalid in variants { XCTAssertThrowsError(try network.privateKeyWIF(source: .seed(seed, account: 0), address: invalid)) }
            XCTAssertThrowsError(try network.privateKeyWIF(source: .seed(Data(1...32), account: 0), address: address))
            XCTAssertThrowsError(try network.privateKeyWIF(source: .seed(seed, account: 1), address: address))
            let wrongNetwork: UTXONetwork = network == .bitcoin ? .litecoin : .bitcoin
            XCTAssertThrowsError(try wrongNetwork.privateKeyWIF(source: .seed(seed, account: 0), address: address))
        }
    }
}
