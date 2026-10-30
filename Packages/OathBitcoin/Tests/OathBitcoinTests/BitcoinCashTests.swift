import Foundation
import CryptoKit
import XCTest
@testable import OathBitcoin

struct BitcoinCashVectors: Decodable {
    let seed, root: String
    struct Address: Decodable { let change, index: UInt32; let address, legacy, script, scriptHash: String }
    struct Scope: Decodable { let depth: Int; let `private`: String; let `public`: String? }
    let addresses: [Address]
    let scopes: [Scope]
    let wifs: [DogecoinVectors.WIF]
    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "bitcoincash-vectors", withExtension: "json")!))
    }
}

final class BitcoinCashTests: XCTestCase, @unchecked Sendable {
    func testBIP44HDReceiveChangeAndAllExtendedScopesMatchIndependentReference() throws {
        let fixture = try BitcoinCashVectors.load()
        let root = try BitcoinCashKeys.wallet(seed: XCTUnwrap(Data(hex: fixture.seed)))
        for wallet in [root, try BitcoinCashKeys.extended(fixture.root)] {
            XCTAssertEqual(wallet.network, .bitcoincash)
            XCTAssertEqual(wallet.types, [.legacy]); XCTAssertEqual(wallet.branches.count, 2)
            for branch in wallet.branches {
                let actual = try BitcoinKeys.addresses(branch: branch, range: 0..<40)
                let expected = fixture.addresses.filter { $0.change == branch.change }
                XCTAssertEqual(actual.map(\.address), expected.map(\.address))
                XCTAssertEqual(actual.map(\.script), expected.map(\.script))
                XCTAssertEqual(actual.map(\.scriptHash), expected.map(\.scriptHash))
                XCTAssertTrue(branch.path.hasPrefix("m/44'/145'/0'/"))
                XCTAssertFalse(branch.descriptor.contains("prv"))
            }
        }
        for scope in fixture.scopes {
            for encoded in [scope.private, scope.public].compactMap({ $0 }) {
                let wallet = try BitcoinCashKeys.extended(encoded)
                XCTAssertTrue(wallet.scopedImport)
                XCTAssertEqual(wallet.branches.count, scope.depth < 4 ? 2 : 1)
                for branch in wallet.branches {
                    let count: UInt32 = scope.depth == 5 ? 1 : 40
                    let actual = try BitcoinKeys.addresses(branch: branch, range: 0..<count)
                    let expected = fixture.addresses.filter { $0.change == branch.change && $0.index < count }
                    XCTAssertEqual(actual.map(\.address), expected.map(\.address))
                }
                if encoded == scope.private { XCTAssertEqual(try BitcoinCashKeys.decodeImport(encoded).extended, encoded) }
                else { XCTAssertThrowsError(try BitcoinCashKeys.decodeImport(encoded)) }
            }
        }
        XCTAssertThrowsError(try BitcoinKeys.wallet(seed: Data(0..<32), network: .bitcoincash))
        XCTAssertThrowsError(try BitcoinCashKeys.extended(Base58Check.encode(Data([4,136,178,30]) + Base58Check.decode(fixture.root).dropFirst(4))))
        var wrong = try Base58Check.decode(fixture.scopes[1].private)
        wrong.replaceSubrange(9..<13, with: [0x80,0,0,0])
        XCTAssertThrowsError(try BitcoinCashKeys.extended(Base58Check.encode(wrong))) { XCTAssertEqual($0 as? BitcoinError, .wrongNetwork) }
        let second = try BitcoinCashKeys.wallet(seed: XCTUnwrap(Data(hex: fixture.seed)), account: 1)
        XCTAssertNotEqual(second.branches, root.branches)
    }

    func testBCHNWIFCompressedUncompressedHexBase64MiniAndInvalidImports() throws {
        let fixture = try BitcoinCashVectors.load()
        for vector in fixture.wifs {
            if vector.testnet { XCTAssertThrowsError(try BitcoinCashKeys.decodeImport(vector.wif)); continue }
            let parsed = try BitcoinCashKeys.decodeImport(vector.wif)
            XCTAssertEqual(parsed.bytes.hex, vector.hex); XCTAssertEqual(parsed.compressed, vector.compressed)
            XCTAssertNil(parsed.extended)
            XCTAssertEqual(try BitcoinCashKeys.wif(bytes: parsed.bytes, compressed: parsed.compressed), vector.wif)
            let wallet = try BitcoinCashKeys.singleKey(bytes: parsed.bytes, compressed: parsed.compressed)
            XCTAssertEqual(wallet.types, [.legacy]); XCTAssertEqual(wallet.branches.count, 1)
            XCTAssertFalse(wallet.branches[0].isHD)
            XCTAssertEqual(try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<1)[0].address, vector.address)
            XCTAssertThrowsError(try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<20))
            for input in [vector.hex, "0x" + vector.hex, "0X" + vector.hex, parsed.bytes.base64EncodedString(), "p2pkh:" + vector.wif] {
                XCTAssertEqual(try BitcoinCashKeys.decodeImport(input).bytes, parsed.bytes)
            }
        }
        let mini = "S6c56bnXQiBjk9mqSYE7ykVQ7NzrRy"
        let key = try BitcoinCashKeys.decodeImport(mini)
        XCTAssertFalse(key.compressed); XCTAssertEqual(key.bytes, Data(SHA256.hash(data: Data(mini.utf8))))
        let scalar = Data(repeating: 0, count: 31) + Data([1])
        for bad in ["", String(repeating: "0", count: 64), String(repeating: "f", count: 64),
                    "6P-encrypted-key", "S6c56bnXQiBjk9mqSYE7ykVQ7NzrRx", "xprv-invalid",
                    try DogecoinKeys.wif(bytes: scalar, compressed: true), try LitecoinKeys.wif(bytes: scalar, compressed: true),
                    "p2wpkh:" + (try BitcoinCashKeys.wif(bytes: scalar, compressed: true))] {
            XCTAssertThrowsError(try BitcoinCashKeys.decodeImport(bad))
        }
        let compressed = try BitcoinCashKeys.singleKey(bytes: scalar, compressed: true)
        let uncompressed = try BitcoinCashKeys.singleKey(bytes: scalar, compressed: false)
        XCTAssertNotEqual(try BitcoinKeys.addresses(branch: compressed.branches[0], range: 0..<1),
                          try BitcoinKeys.addresses(branch: uncompressed.branches[0], range: 0..<1))
    }

    func testPublishedCashAddrAndLegacyRepresentTheSameScript() throws {
        // CashAddr specification's published translations, no app-owned keys.
        let cases = [("1BpEi6DfDAUFd7GtittLSdBeYJvcoaVggu", "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"),
                     ("1KXrWXciRDZUpQwQmuM1DbwsKDLYAYsVLR", "bitcoincash:qr95sy3j9xwd2ap32xkykttr4cvcu7as4y0qverfuy"),
                     ("16w1D5WRVKJuZUsSRzdLp9w3YGcgoxDXb", "bitcoincash:qqq3728yw0y47sqn6l2na30mcw6zm78dzqre909m2r")]
        for (legacy, cash) in cases {
            let payload = try Base58Check.decode(legacy)
            let script = Data([0x76,0xa9,0x14]) + payload.dropFirst() + Data([0x88,0xac])
            XCTAssertEqual(try CashAddress.p2pkh(script: script), cash)
        }
        XCTAssertThrowsError(try CashAddress.p2pkh(script: Data([0,20]) + Data(repeating: 0, count: 20)))
    }

    func testCashTokenSpecificationVectorsAndFundingCommitment() throws {
        struct Vector: Decodable { let prefix: String }
        let script = Data([0x76,0xa9,0x14]) + Data(repeating: 17, count: 20) + Data([0x88,0xac])
        for kind in ["valid", "invalid"] {
            let url = Bundle.module.url(forResource: "bitcoincash-tokens-" + kind, withExtension: "json")!
            let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
            for vector in vectors {
                let prefix = try XCTUnwrap(Data(hex: vector.prefix))
                if kind == "valid" { XCTAssertEqual(try BitcoinCashTokens.lockingScript(prefix + script), script) }
                else { XCTAssertThrowsError(try BitcoinCashTokens.lockingScript(prefix)) }
            }
        }
        let prefix = Data([0xef]) + Data(repeating: 34, count: 32) + Data([0x10,1])
        let locking = prefix + script
        let body = "0200000001" + String(repeating: "11", count: 32) + "0000000000ffffffff01e803000000000000"
        let raw = try XCTUnwrap(Data(hex: body)) + Data([UInt8(locking.count)]) + locking + Data(repeating: 0, count: 4)
        let txid = Data(SHA256.hash(data: Data(SHA256.hash(data: raw))).reversed()).hex
        XCTAssertEqual(try BitcoinTransactions.txid(raw, network: .bitcoincash), txid)
        XCTAssertTrue(try BitcoinTransactions.validates(raw, txid: txid, vout: 0, value: 1000, script: script.hex, network: .bitcoincash))
        XCTAssertFalse(try BitcoinTransactions.validates(raw, txid: txid, vout: 0, value: 999, script: script.hex, network: .bitcoincash))
        XCTAssertTrue(try BitcoinTransactions.hasTokens(raw, vout: 0, network: .bitcoincash))
        XCTAssertFalse(try BitcoinTransactions.validates(raw, txid: txid, vout: 0, value: 1000, script: script.hex))
        let witness = raw.prefix(4) + Data([0,1]) + raw.dropFirst(4).dropLast(4) + Data([1,1,0]) + raw.suffix(4)
        XCTAssertThrowsError(try BitcoinTransactions.txid(witness, network: .bitcoincash))
    }

    func testBatchedGap20ContinuesAfterSpentReceiveAndChangeHistory() async throws {
        let wallet = try BitcoinCashKeys.wallet(seed: Data(0..<32))
        let query = QueryFixture()
        let replies = try Dictionary(uniqueKeysWithValues: wallet.branches.enumerated().map { i, branch in
            let address = try BitcoinKeys.addresses(branch: branch, range: 19..<20)[0]
            return (address.scriptHash, BitcoinAddressState(confirmed: 0, unconfirmed: 0,
                history: [.init(txid: String(repeating: String(i + 1), count: 64), height: 100)], unspent: []))
        })
        await query.configure(replies)
        let scan = try await BitcoinDiscovery(query: query).scan(wallet)
        XCTAssertEqual(scan.addresses.count, 80)
        XCTAssertEqual(scan.total, 0)
        try scan.validate(wallet: wallet, requiredThrough: [:])
        let batches = await query.batchSizes
        XCTAssertEqual(batches, [wallet.branches.count * 20, wallet.branches.count * 100],
            "Every receive/change branch shares full batches; network concurrency is checked at the pool")
        let scoped = try BitcoinCashKeys.singleKey(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: false)
        let finite = try await BitcoinDiscovery(query: query).scan(scoped)
        XCTAssertEqual(finite.addresses.count, 1)
    }

    func testRejectsBitcoinPeerDespiteSharedGenesisAndRecovers() async throws {
        XCTAssertEqual(UTXONetwork.bitcoin.genesis, UTXONetwork.bitcoincash.genesis)
        let pool = ElectrumPool(servers: [.init("bitcoin"), .init("old-cash"), .init("cash")], maximumConnections: 1, network: .bitcoincash) {
            StubTransport($0.host == "old-cash" ? .legacyProtocol : .empty, network: $0.host == "bitcoin" ? .bitcoin : .bitcoincash)
        }
        let states = try await pool.query(scriptHashes: [String(repeating: "1", count: 64)])
        XCTAssertEqual(states.count, 1)
        let attempts = await pool.diagnostics()
        XCTAssertEqual(attempts.map(\.error), [.wrongNetwork, .invalidResponse, nil])
        await pool.close()
    }

    func testLiveBitcoinCashPeersBatchesHistoryRawTransactionsAndFallback() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BITCOINCASH_LIVE"] == "1" else { throw XCTSkip("Opt-in public-network check") }
        let fixture = try BitcoinCashVectors.load()
        let wallet = try BitcoinCashKeys.wallet(seed: XCTUnwrap(Data(hex: fixture.seed)))
        let addresses = try wallet.branches.flatMap { try BitcoinKeys.addresses(branch: $0, range: 1000..<1060) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for server in UTXONetwork.bitcoincash.servers {
                group.addTask {
                    let pool = ElectrumPool(servers: [server], network: .bitcoincash)
                    let tip = try await pool.chainTip(); XCTAssertGreaterThan(tip.height, 950_000)
                    let states = try await pool.query(scriptHashes: addresses.map(\.scriptHash))
                    XCTAssertEqual(states.count, 120)
                    XCTAssertTrue(states.allSatisfy { $0.history.isEmpty && $0.unspent.isEmpty && $0.confirmed == 0 && $0.unconfirmed == 0 })
                    let attempts = await pool.diagnostics()
                    XCTAssertTrue(attempts.contains { $0.requestCount == 300 && $0.error == nil })
                    await pool.close()
                }
            }
            try await group.waitForAll()
        }
        let pool = ElectrumPool(servers: [.init("localhost", port: 1), UTXONetwork.bitcoincash.servers[0]], maximumConnections: 1, network: .bitcoincash)
        let first = try wallet.branches.map { try BitcoinKeys.addresses(branch: $0, range: 0..<1)[0] }
        let states = try await pool.query(scriptHashes: first.map(\.scriptHash))
        XCTAssertTrue(states.contains { !$0.history.isEmpty }, "Published BIP39 fixture has public BCH history")
        let txids = Array(Set(states.flatMap { $0.history.prefix(2).map(\.txid) + $0.unspent.map(\.txid) }))
        let raw = try await pool.transactions(txids: txids)
        XCTAssertEqual(raw.count, txids.count)
        for (address, state) in zip(first, states) {
            for output in state.unspent {
                XCTAssertTrue(try BitcoinTransactions.validates(XCTUnwrap(raw[output.txid]), txid: output.txid,
                    vout: output.vout, value: output.value, script: address.script, network: .bitcoincash))
            }
        }
        let attempts = await pool.diagnostics()
        XCTAssertTrue(attempts.contains { $0.server == "localhost" && $0.error != nil })
        await pool.close()
    }
}
