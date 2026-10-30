import Foundation
import XCTest
@testable import OathBitcoin

struct DogecoinVectors: Decodable {
    let seed, root, rootXprv, accountPrivate, accountPublic, accountXprv, accountXpub: String
    struct Address: Decodable { let change, index: UInt32; let address: String }
    struct WIF: Decodable { let wif, hex, address: String; let compressed, testnet: Bool }
    struct Scope: Decodable { let depth: Int; let dogecoin, bitcoin: String }
    let scopes: [Scope]
    let addresses: [Address]
    let wifs: [WIF]
    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "dogecoin-vectors", withExtension: "json")!))
    }
}

final class DogecoinTests: XCTestCase, @unchecked Sendable {
    func testMnemonicSeedRootAndAccountExtendedKeysMatchIndependentVectors() throws {
        let fixture = try DogecoinVectors.load()
        let seedWallet = try DogecoinKeys.wallet(seed: XCTUnwrap(Data(hex: fixture.seed)))
        let wallets = try [fixture.root, fixture.rootXprv, fixture.accountPrivate, fixture.accountPublic,
                           fixture.accountXprv, fixture.accountXpub].map { try DogecoinKeys.extended($0) } + [seedWallet]
        for wallet in wallets {
            XCTAssertEqual(wallet.network, .dogecoin)
            XCTAssertEqual(wallet.types, [.legacy])
            XCTAssertEqual(wallet.branches.count, 2)
            for branch in wallet.branches {
                let actual = try BitcoinKeys.addresses(branch: branch, range: 0..<40)
                XCTAssertEqual(actual.map(\.address), fixture.addresses.filter { $0.change == branch.change }.map(\.address))
                XCTAssertFalse(branch.descriptor.contains("prv"))
                XCTAssertFalse(branch.descriptor.contains("dgpv"))
            }
        }
        XCTAssertEqual(try DogecoinKeys.decodeImport(fixture.root).extended, fixture.root)
        XCTAssertThrowsError(try DogecoinKeys.decodeImport(fixture.accountPublic))
    }

    func testCoreWIFVectorsCompressionAndRawFormats() throws {
        let fixture = try DogecoinVectors.load()
        for vector in fixture.wifs {
            if vector.testnet || vector.address.isEmpty {
                XCTAssertThrowsError(try DogecoinKeys.decodeImport(vector.wif)); continue
            }
            let decoded = try DogecoinKeys.decodeImport(vector.wif)
            XCTAssertEqual(decoded.bytes.hex, vector.hex)
            XCTAssertEqual(decoded.compressed, vector.compressed)
            let wallet = try DogecoinKeys.singleKey(bytes: decoded.bytes, compressed: decoded.compressed)
            XCTAssertEqual(try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<1)[0].address, vector.address)
            XCTAssertEqual(try DogecoinKeys.wif(bytes: decoded.bytes, compressed: decoded.compressed), vector.wif)
            for raw in [vector.hex, "0x" + vector.hex, decoded.bytes.base64EncodedString()] {
                XCTAssertEqual(try DogecoinKeys.decodeImport(raw).bytes, decoded.bytes)
            }
            XCTAssertThrowsError(try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<20))
        }
        for invalid in ["", "dgpv-invalid", "6P-encrypted-key-needs-decryption", String(repeating: "0", count: 64), String(repeating: "f", count: 64)] {
            XCTAssertThrowsError(try DogecoinKeys.decodeImport(invalid))
        }
        let bitcoinWIF = try BitcoinKeys.wif(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: true)
        XCTAssertThrowsError(try DogecoinKeys.decodeImport(bitcoinWIF))
    }

    func testDogecoinGapSpentHistoryAndLargeAmountsOnBothBranches() async throws {
        let wallet = try DogecoinKeys.wallet(seed: Data(0..<32))
        let query = QueryFixture()
        var replies: [String: BitcoinAddressState] = [:]
        for branch in wallet.branches {
            let address = try BitcoinKeys.addresses(branch: branch, range: 19..<20)[0]
            let txid = String(repeating: branch.change == 0 ? "1" : "2", count: 64)
            // This exceeds Bitcoin's 21-million coin bound; DOGE has its own units/bounds.
            let value: Int64 = branch.change == 0 ? 3_000_000_000_000_000 : 0
            replies[address.scriptHash] = .init(confirmed: value, unconfirmed: 0,
                history: [.init(txid: txid, height: 500)], unspent: value == 0 ? [] : [.init(txid: txid, vout: 0, value: value, height: 500)])
        }
        await query.configure(replies)
        let scan = try await BitcoinDiscovery(query: query).scan(wallet)
        XCTAssertEqual(scan.addresses.count, 80)
        XCTAssertEqual(scan.total, 3_000_000_000_000_000)
        XCTAssertNoThrow(try scan.validate(wallet: wallet, requiredThrough: [:]))
        let batches = await query.batchSizes
        XCTAssertEqual(batches, [wallet.branches.count * 20, wallet.branches.count * 100],
            "Every receive/change branch shares full batches; network concurrency is checked at the pool")
    }

    func testLegacyBitcoinDescriptorDecodingStaysBitcoin() throws {
        let bitcoin = try BitcoinKeysTests.wallet()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bitcoin)) as? [String: Any])
        json["branches"] = (json["branches"] as! [[String: Any]]).map { row in var row = row; row.removeValue(forKey: "network"); return row }
        let decoded = try JSONDecoder().decode(BitcoinWalletDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, bitcoin)
    }

    func testDogecoinWalletTotalsCanExceedSingleTransactionLimitWithoutOverflow() async throws {
        let wallet = try DogecoinKeys.wallet(seed: Data(0..<32))
        let query = QueryFixture()
        var replies: [String: BitcoinAddressState] = [:]
        for branch in wallet.branches {
            let address = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0]
            let txid = String(repeating: branch.change == 0 ? "1" : "2", count: 64)
            let value: Int64 = 900_000_000_000_000_000
            replies[address.scriptHash] = .init(confirmed: value, unconfirmed: 0,
                history: [.init(txid: txid, height: 500)], unspent: [.init(txid: txid, vout: 0, value: value, height: 500)])
        }
        await query.configure(replies)
        let scan = try await BitcoinDiscovery(query: query).scan(wallet)
        XCTAssertEqual(scan.total, 1_800_000_000_000_000_000)
        XCTAssertNoThrow(try scan.validate(wallet: wallet, requiredThrough: [:]))
        let address = try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<1)[0]
        replies[address.scriptHash] = .init(confirmed: Int64.max, unconfirmed: 1, history: [], unspent: [])
        await query.configure(replies)
        do { _ = try await BitcoinDiscovery(query: query).scan(wallet); XCTFail("Overflow accepted") }
        catch { XCTAssertEqual(error as? BitcoinError, .invalidResponse) }
    }

    func testLiveDogecoinBatchPeersHeadersAndHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_DOGECOIN_LIVE"] == "1" else { throw XCTSkip("Opt-in public-network check") }
        let fixture = try DogecoinVectors.load()
        let wallet = try DogecoinKeys.extended(fixture.accountPublic)
        let addresses = try wallet.branches.flatMap { try BitcoinKeys.addresses(branch: $0, range: 1000..<1050) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for server in UTXONetwork.dogecoin.servers {
                group.addTask {
                    let pool = ElectrumPool(servers: [server], network: .dogecoin)
                    let tip = try await pool.chainTip()
                    XCTAssertGreaterThan(tip.height, 5_000_000)
                    let states = try await pool.query(scriptHashes: addresses.map(\.scriptHash))
                    XCTAssertEqual(states.count, 100)
                    XCTAssertTrue(states.allSatisfy { $0.history.isEmpty && $0.unspent.isEmpty && $0.confirmed == 0 })
                    let attempts = await pool.diagnostics()
                    XCTAssertTrue(attempts.contains { $0.requestCount == 300 && $0.error == nil })
                    await pool.close()
                }
            }
            try await group.waitForAll()
        }
        // Known public test-vector address: query historical use and validate
        // serialized funding outputs when present. No installed wallet is read.
        let pool = ElectrumPool(servers: [ElectrumServer("localhost", port: 1), UTXONetwork.dogecoin.servers[1]], network: .dogecoin)
        let first = try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<1)[0]
        let state = try await pool.query(scriptHashes: [first.scriptHash])[0]
        XCTAssertFalse(state.history.isEmpty)
        let txids = Array(Set(state.unspent.map(\.txid) + state.history.prefix(2).map(\.txid)))
        let raw = try await pool.transactions(txids: txids)
        XCTAssertEqual(raw.count, txids.count)
        for output in state.unspent {
            XCTAssertTrue(try BitcoinTransactions.validates(XCTUnwrap(raw[output.txid]), txid: output.txid, vout: output.vout, value: output.value, script: first.script))
        }
        let attempts = await pool.diagnostics()
        XCTAssertTrue(attempts.contains { $0.server == "localhost" && $0.error != nil })
        await pool.close()
    }
}
