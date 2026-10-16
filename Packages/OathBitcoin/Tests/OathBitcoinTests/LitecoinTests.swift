import Foundation
import CryptoKit
import XCTest
@testable import OathBitcoin

struct LitecoinVectors: Decodable {
    let seed: String
    let roots: [String: String]
    struct Address: Decodable {
        let purpose: Int
        let change, index: UInt32
        let address, script, scriptHash: String
    }
    struct Scope: Decodable { let purpose, depth: Int; let keys: [String: String] }
    let addresses: [Address]
    let scopes: [Scope]
    let wifs: [DogecoinVectors.WIF]
    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "litecoin-vectors", withExtension: "json")!))
    }
}

final class LitecoinTests: XCTestCase, @unchecked Sendable {
    private struct PegoutFixture: Decodable { let txid, raw: String }
    private static func pegoutFixture() throws -> PegoutFixture {
        try JSONDecoder().decode(PegoutFixture.self, from: Data(contentsOf: Bundle.module.url(forResource: "litecoin-pegout", withExtension: "json")!))
    }

    func testAllHDTypesBothBranchesMatchIndependentReference() throws {
        let fixture = try LitecoinVectors.load()
        let wallet = try LitecoinKeys.wallet(seed: XCTUnwrap(Data(hex: fixture.seed)))
        let wallets = try [wallet] + fixture.roots.values.map { try LitecoinKeys.extended($0) }
        for value in wallets {
            XCTAssertEqual(value.network, .litecoin)
            XCTAssertEqual(value.types, BitcoinAddressType.allCases)
            XCTAssertEqual(value.branches.count, 8)
            XCTAssertFalse(value.scopedImport)
            for branch in value.branches {
                let actual = try BitcoinKeys.addresses(branch: branch, range: 0..<40)
                let expected = fixture.addresses.filter { $0.purpose == branch.type.rawValue && $0.change == branch.change }
                XCTAssertEqual(actual.map(\.address), expected.map(\.address))
                XCTAssertEqual(actual.map(\.script), expected.map(\.script))
                XCTAssertEqual(actual.map(\.scriptHash), expected.map(\.scriptHash))
                XCTAssertTrue(branch.path.contains("/2'/"))
                XCTAssertFalse(branch.descriptor.contains("prv"))
            }
        }
        XCTAssertEqual(wallet.defaultType, .nativeSegwit)
        for key in fixture.roots.values { XCTAssertEqual(try LitecoinKeys.decodeImport(key).extended, key) }
    }

    func testPurposeCoinAccountBranchAndLeafPrivatePublicScopes() throws {
        let fixture = try LitecoinVectors.load()
        for scope in fixture.scopes {
            for (prefix, key) in scope.keys {
                let wallet = try LitecoinKeys.extended(key)
                XCTAssertTrue(wallet.scopedImport)
                let branches = wallet.branches.filter { $0.type.rawValue == scope.purpose }
                XCTAssertEqual(branches.count, scope.depth < 4 ? 2 : 1)
                for branch in branches {
                    let count: UInt32 = scope.depth == 5 ? 1 : 40
                    let actual = try BitcoinKeys.addresses(branch: branch, range: 0..<count)
                    let expected = fixture.addresses.filter { $0.purpose == scope.purpose && $0.change == branch.change && $0.index < count }
                    XCTAssertEqual(actual.map(\.address), expected.map(\.address), "Scope \(scope.depth), \(prefix)")
                }
                if prefix.hasSuffix("pub") || prefix.hasSuffix("ub") {
                    XCTAssertThrowsError(try LitecoinKeys.decodeImport(key), "Watch-only key must not enter signing-key import")
                }
            }
        }
        let bitcoin = try BitcoinKeysTests.wallet()
        XCTAssertNotEqual(try BitcoinKeys.addresses(branch: bitcoin.branches[0], range: 0..<1)[0].address,
                          fixture.addresses[0].address)
        let root = try Base58Check.decode(XCTUnwrap(fixture.roots["xprv"]))
        var wrongCoin = root
        wrongCoin[4] = 2
        wrongCoin.replaceSubrange(9..<13, with: [0x80, 0, 0, 0])
        XCTAssertThrowsError(try LitecoinKeys.extended(Base58Check.encode(wrongCoin))) { XCTAssertEqual($0 as? BitcoinError, .wrongNetwork) }
    }

    func testCoreWIFCompressedUncompressedRawAndElectrumFormats() throws {
        let fixture = try LitecoinVectors.load()
        for vector in fixture.wifs {
            if vector.testnet { XCTAssertThrowsError(try LitecoinKeys.decodeImport(vector.wif)); continue }
            let parsed = try LitecoinKeys.decodeImport(vector.wif)
            XCTAssertEqual(parsed.bytes.hex, vector.hex)
            XCTAssertEqual(parsed.compressed, vector.compressed)
            XCTAssertEqual(try LitecoinKeys.wif(bytes: parsed.bytes, compressed: parsed.compressed), vector.wif)
            let wallet = try LitecoinKeys.singleKey(bytes: parsed.bytes, compressed: parsed.compressed)
            XCTAssertEqual(wallet.types, vector.compressed ? BitcoinAddressType.allCases : [.legacy])
            let legacy = try XCTUnwrap(wallet.branches.first { $0.type == .legacy })
            XCTAssertEqual(try BitcoinKeys.addresses(branch: legacy, range: 0..<1)[0].address, vector.address)
            XCTAssertThrowsError(try BitcoinKeys.addresses(branch: legacy, range: 0..<20))
            for raw in [vector.hex, "0x" + vector.hex, "0X" + vector.hex, parsed.bytes.base64EncodedString()] {
                XCTAssertEqual(try LitecoinKeys.decodeImport(raw).bytes, parsed.bytes)
            }
            XCTAssertEqual(try LitecoinKeys.decodeImport("p2pkh:" + vector.wif).compressed, vector.compressed)
            for style in ["p2wpkh:", "p2wpkh-p2sh:"] {
                if vector.compressed { XCTAssertEqual(try LitecoinKeys.decodeImport(style + vector.wif).bytes, parsed.bytes) }
                else { XCTAssertThrowsError(try LitecoinKeys.decodeImport(style + vector.wif)) }
            }
        }
        let bytes = Data(repeating: 0, count: 31) + Data([1])
        for prefix: UInt8 in [0x81, 0x82] {
            XCTAssertEqual(try LitecoinKeys.decodeImport(Base58Check.encode(Data([prefix]) + bytes + Data([1]))).bytes, bytes)
        }
        let mini = "S6c56bnXQiBjk9mqSYE7ykVQ7NzrRy" // Published Casascius test vector.
        let decoded = try LitecoinKeys.decodeImport(mini)
        XCTAssertEqual(decoded.bytes, Data(SHA256.hash(data: Data(mini.utf8))))
        XCTAssertFalse(decoded.compressed)
        for invalid in ["", String(repeating: "0", count: 64), String(repeating: "f", count: 64),
                        "6P-encrypted-key", "Ltpv-invalid", "p2wsh:" + (try LitecoinKeys.wif(bytes: bytes, compressed: true)),
                        try BitcoinKeys.wif(bytes: bytes, compressed: true), try DogecoinKeys.wif(bytes: bytes, compressed: false)] {
            XCTAssertThrowsError(try LitecoinKeys.decodeImport(invalid))
        }
    }

    func testGap20ScansSpentAddressesAndChangeAcrossEveryTypeInParallel() async throws {
        let wallet = try LitecoinKeys.wallet(seed: Data(0..<32))
        let query = QueryFixture()
        var replies: [String: BitcoinAddressState] = [:]
        for (i, branch) in wallet.branches.enumerated() {
            let address = try BitcoinKeys.addresses(branch: branch, range: 19..<20)[0]
            let hash = String(repeating: String(i + 1), count: 64)
            let value: Int64 = i == 0 ? 3_000_000_000_000_000 : 0 // LTC may exceed BTC's cap.
            replies[address.scriptHash] = .init(confirmed: value, unconfirmed: 0,
                history: [.init(txid: hash, height: 10)], unspent: value == 0 ? [] : [.init(txid: hash, vout: 0, value: value, height: 10)])
        }
        await query.configure(replies)
        let scan = try await BitcoinDiscovery(query: query).scan(wallet)
        XCTAssertEqual(scan.addresses.count, 320)
        XCTAssertEqual(scan.total, 3_000_000_000_000_000)
        try scan.validate(wallet: wallet, requiredThrough: [:])
        let peak = await query.peak; XCTAssertGreaterThan(peak, 1)
        let other = try BitcoinKeys.wallet(seed: Data(0..<32))
        XCTAssertThrowsError(try scan.validate(wallet: other, requiredThrough: [:]))
    }

    func testLitecoinPeerIdentityAndAmountLimitsRecover() async throws {
        let pool = ElectrumPool(servers: [.init("wrong-chain"), .init("litecoin")], maximumConnections: 1, network: .litecoin) {
            StubTransport(.empty, network: $0.host == "litecoin" ? .litecoin : .bitcoin)
        }
        let states = try await pool.query(scriptHashes: [String(repeating: "1", count: 64)])
        XCTAssertEqual(states.count, 1)
        let attempts = await pool.diagnostics()
        XCTAssertEqual(attempts.map(\.error), [.wrongNetwork, nil])
        let tip = try await pool.chainTip(); XCTAssertEqual(tip.header.count, 160)
        await pool.close()
    }

    func testTransparentMWEBHogExAndWitnessTxids() throws {
        let wallet = try LitecoinKeys.singleKey(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: false)
        let address = try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<1)[0]
        let hogOutput = "0000000000000000225820" + String(repeating: "22", count: 32)
        let body = "01" + String(repeating: "11", count: 32) + "0000000000ffffffff02" + hogOutput + "e80300000000000019" + address.script
        let canonical = try XCTUnwrap(Data(hex: "02000000" + body + "00000000"))
        let hash = Data(SHA256.hash(data: Data(SHA256.hash(data: canonical))).reversed()).hex
        for (flags, witness) in [("08", ""), ("09", "0101aa")] {
            let raw = try XCTUnwrap(Data(hex: "0200000000" + flags + body + witness + "00" + "00000000"))
            XCTAssertEqual(try BitcoinTransactions.txid(raw, network: .litecoin), hash)
            XCTAssertTrue(try BitcoinTransactions.validates(raw, txid: hash, vout: 1, value: 1000, script: address.script, network: .litecoin))
            XCTAssertFalse(try BitcoinTransactions.isCoinbase(raw, network: .litecoin))
            XCTAssertFalse(try BitcoinTransactions.validates(raw, txid: hash, vout: 1, value: 1001, script: address.script, network: .litecoin))
            XCTAssertThrowsError(try BitcoinTransactions.txid(raw))
        }
        // Core/Electrum's legacy serialization strips the flag but not the
        // HogAddr script. Peg-out maturity must survive both representations.
        XCTAssertTrue(try BitcoinTransactions.isPegout(canonical, vout: 1, network: .litecoin))
        XCTAssertFalse(try BitcoinTransactions.isPegout(canonical, vout: 0, network: .litecoin))
        XCTAssertFalse(try BitcoinTransactions.isPegout(canonical, vout: 1, network: .bitcoin))
        XCTAssertFalse(UTXONetwork.litecoin.permitsSpending(blockHeight: nil, tipHeight: 100, isCoinbase: false, isPegout: true))
        XCTAssertFalse(UTXONetwork.litecoin.permitsSpending(blockHeight: 100, tipHeight: 104, isCoinbase: false, isPegout: true))
        XCTAssertTrue(UTXONetwork.litecoin.permitsSpending(blockHeight: 100, tipHeight: 105, isCoinbase: false, isPegout: true))
        for suffix in ["", "0000", "0200000000", "000000000000", "0100000000"] {
            let invalid = try XCTUnwrap(Data(hex: "020000000008" + body + suffix))
            XCTAssertThrowsError(try BitcoinTransactions.txid(invalid, network: .litecoin))
        }
        let unknown = try XCTUnwrap(Data(hex: "02000000000a" + body + "0000000000"))
        XCTAssertThrowsError(try BitcoinTransactions.txid(unknown, network: .litecoin))
    }

    func testPublishedMWEBWithdrawalWithStrippedFlag() throws {
        let fixture = try Self.pegoutFixture()
        let raw = try XCTUnwrap(Data(hex: fixture.raw))
        XCTAssertEqual(try BitcoinTransactions.txid(raw, network: .litecoin), fixture.txid)
        XCTAssertFalse(try BitcoinTransactions.isCoinbase(raw, network: .litecoin))
        XCTAssertTrue(try BitcoinTransactions.isPegout(raw, vout: 1, network: .litecoin))
        XCTAssertFalse(try BitcoinTransactions.isPegout(raw, vout: 0, network: .litecoin))
        // The serialized MWEB flag is not part of the txid. Both forms must
        // identify the same public withdrawal and enforce the same maturity.
        let full = raw.prefix(4) + Data([0, 8]) + raw.dropFirst(4).dropLast(4) + Data([0]) + raw.suffix(4)
        XCTAssertEqual(try BitcoinTransactions.txid(full, network: .litecoin), fixture.txid)
        XCTAssertTrue(try BitcoinTransactions.isPegout(full, vout: 1, network: .litecoin))
    }

    func testLiveLitecoinBatchesEveryPeerAndPublicHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LITECOIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public-network check") }
        let fixture = try LitecoinVectors.load()
        let withdrawal = try Self.pegoutFixture()
        let wallet = try LitecoinKeys.wallet(seed: XCTUnwrap(Data(hex: fixture.seed)))
        let addresses = try wallet.branches.flatMap { try BitcoinKeys.addresses(branch: $0, range: 1000..<1020) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for server in UTXONetwork.litecoin.servers {
                group.addTask {
                    let pool = ElectrumPool(servers: [server], network: .litecoin)
                    let tip = try await pool.chainTip(); XCTAssertGreaterThan(tip.height, 3_000_000)
                    let states = try await pool.query(scriptHashes: addresses.map(\.scriptHash))
                    XCTAssertEqual(states.count, 160)
                    XCTAssertTrue(states.allSatisfy { $0.history.isEmpty && $0.unspent.isEmpty && $0.confirmed == 0 && $0.unconfirmed == 0 })
                    let funding = try await pool.transactions(txids: [withdrawal.txid])
                    let raw = try XCTUnwrap(funding[withdrawal.txid])
                    XCTAssertTrue(try BitcoinTransactions.isPegout(raw, vout: 1, network: .litecoin))
                    let attempts = await pool.diagnostics()
                    XCTAssertTrue(attempts.contains { $0.requestCount == 300 && $0.error == nil })
                    await pool.close()
                }
            }
            try await group.waitForAll()
        }
        let pool = ElectrumPool(servers: [.init("localhost", port: 1), UTXONetwork.litecoin.servers[1]], maximumConnections: 1, network: .litecoin)
        let first = try wallet.branches.filter { $0.change == 0 }.map { try BitcoinKeys.addresses(branch: $0, range: 0..<1)[0] }
        let states = try await pool.query(scriptHashes: first.map(\.scriptHash))
        XCTAssertTrue(states.contains { !$0.history.isEmpty }, "Public BIP39 fixture has historical Litecoin use")
        let txids = Array(Set(states.flatMap { $0.history.prefix(2).map(\.txid) + $0.unspent.map(\.txid) }))
        let raw = try await pool.transactions(txids: txids)
        XCTAssertEqual(raw.count, txids.count)
        for (address, state) in zip(first, states) {
            for output in state.unspent {
                XCTAssertTrue(try BitcoinTransactions.validates(XCTUnwrap(raw[output.txid]), txid: output.txid,
                    vout: output.vout, value: output.value, script: address.script, network: .litecoin))
            }
        }
        let attempts = await pool.diagnostics()
        XCTAssertTrue(attempts.contains { $0.server == "localhost" && $0.error != nil })
        await pool.close()
    }
}
