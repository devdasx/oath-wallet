import Foundation
import GRDB
import XCTest
@testable import OathBitcoin
@testable import OathDatabase

private struct StatusFundingQuery: BitcoinAddressQuerying {
    let source: String, hash: String
    func query(scriptHashes: [String]) async throws -> [BitcoinAddressState] {
        scriptHashes.map { $0 == source ? .init(confirmed: 100_000_000, unconfirmed: 0,
            history: [.init(txid: hash, height: 100)], unspent: [.init(txid: hash, vout: 0, value: 100_000_000, height: 100)])
            : .init(confirmed: 0, unconfirmed: 0, history: [], unspent: []) }
    }
}

private struct StatusHistoryQuery: BitcoinSendStatusReading {
    let rows: [BitcoinHistoryItem]
    let bodies: [String:Data]
    func query(scriptHashes: [String]) async throws -> [BitcoinAddressState] {
        scriptHashes.map { _ in .init(confirmed:0,unconfirmed:0,history:rows,unspent:[]) }
    }
    func transactions(txids: [String]) async throws -> [String:Data] { bodies.filter { txids.contains($0.key) } }
    func blockTimes(heights: [Int64]) async throws -> [Int64:Double] { Dictionary(uniqueKeysWithValues:heights.map { ($0,1000) }) }
}

@MainActor final class BitcoinSendSettlementTests: XCTestCase {
    private let seed = Data(0..<32) // Published deterministic host-test material only.
    private func fixture(_ chain: UTXONetwork) async throws -> (OathDatabase, BitcoinSendPlan, BitcoinSignedSend) {
        let db = try await OathDatabase.open(at: FileManager.default.temporaryDirectory.appendingPathComponent("StatusUTXO-" + UUID().uuidString).appendingPathComponent("db.sqlite"))
        try await db.seed(networks: [.init(id: chain.rawValue, name: "Test", family: "utxo", symbol: "TEST", decimals: 8, derivationPath: "fixture", logo: "", sortOrder: 0)],
            assets: [.init(id: chain.rawValue + ":native", networkID: chain.rawValue, reference: "native", name: "Test", symbol: "TEST", decimals: 8)])
        let descriptor = try chain.wallet(seed: seed)
        let source = try BitcoinKeys.addresses(branch: descriptor.branches.first { $0.type == descriptor.defaultType && $0.change == 0 }!, range: 0..<1)[0]
        let other = try chain.wallet(seed: Data(1...32))
        let recipient = try BitcoinKeys.addresses(branch: other.branches[0], range: 0..<1)[0]
        try await db.importWalletIfNeeded(.init(id: "w", name: "Test", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "a", walletID: "w", networkID: chain.rawValue, address: source.address, derivationPath: source.path)])
        try await db.prepareBitcoin(accountID: "a", descriptor: descriptor)
        let change = try await db.bitcoinChangeAddress(accountID: "a")
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 17, count: 32)
        raw += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(100_000_000)) + BitcoinWire.vector(Data(hex: source.script)!) + BitcoinWire.little(UInt32(0))
        let hash = try BitcoinTransactions.txid(raw, network: chain)
        let coin = BitcoinSendCoin(accountID: "a", txid: hash, vout: 0, value: 100_000_000, address: source, previousTransaction: raw)
        let scan = try await BitcoinDiscovery(query: StatusFundingQuery(source: source.scriptHash, hash: hash)).scan(descriptor)
        let scanID = try await db.beginBitcoinScan(accountID: "a")
        try await db.commitBitcoinScan(accountID: "a", scanID: scanID, scan: scan, transactions: [hash: raw], tipHeight: 150)
        let plan = try BitcoinSendPlan.make(coins: [coin], recipient: recipient.address, amount: 10_000_000, change: change,
            ratePerKVByte: chain == .dogecoin ? 1_000_000 : 2000, chain: chain)
        try await db.saveDraft(.init(id: "send", walletID: "w", accountID: "a", networkID: chain.rawValue, assetID: chain.rawValue + ":native",
            idempotencyKey: "send", recipient: plan.recipient, amountAtomic: String(plan.recipientAmount), state: "draft", createdAt: 1, updatedAt: 1))
        try await db.saveBitcoinSendPlan(sendID: "send", plan: plan)
        _ = try await db.queueSend("send", outputs: [.init(hash: hash, index: 0)])
        let signed = try sign(plan)
        try await db.journalBitcoinSignature(sendID: "send", signed: signed)
        _ = try await db.transitionSend("send", from: "signed", to: "broadcast")
        return (db, plan, signed)
    }
    private func sign(_ plan: BitcoinSendPlan) throws -> BitcoinSignedSend {
        if plan.chain == .bitcoincash { return try BitcoinCashSendSigner.sign(plan) { _ in .seed(seed, account: 0) } }
        return try BitcoinSendSigner.sign(plan) { _ in .seed(seed, account: 0) }
    }
    func testAllFourStatusAdaptersRequireMinedBytesAndFindActualReplacement() async throws {
        for chain in UTXONetwork.allCases {
            let (db,plan,signed)=try await fixture(chain)
            for height:Int64 in [-1,0] {
                let pending=try await BitcoinSendStatus.read(raw:signed.raw,plan:plan,
                    client:StatusHistoryQuery(rows:[.init(txid:signed.txid,height:height)],bodies:[signed.txid:signed.raw]))
                XCTAssertNil(pending)
            }
            let missing=try await BitcoinSendStatus.read(raw:signed.raw,plan:plan,client:StatusHistoryQuery(rows:[],bodies:[:]))
            XCTAssertNil(missing,"Missing provider history cannot prove failure")
            let replacement=try BitcoinSendPlan.make(coins:plan.coins,recipient:plan.recipient,amount:20_000_000,
                change:plan.change,ratePerKVByte:plan.ratePerKVByte,chain:chain)
            let winner=try sign(replacement)
            let receipt=try await BitcoinSendStatus.read(raw:signed.raw,plan:plan,
                client:StatusHistoryQuery(rows:[.init(txid:winner.txid,height:200)],bodies:[winner.txid:winner.raw]))
            try await db.settleBitcoinSend("send",confirmation:XCTUnwrap(receipt))
            let send=try await db.send("send")
            XCTAssertEqual(send?.failureCode,"replaced")
            do {
                _ = try await BitcoinSendStatus.read(raw:signed.raw,plan:plan,
                    client:StatusHistoryQuery(rows:[.init(txid:signed.txid,height:200)],bodies:[signed.txid:winner.raw]))
                XCTFail("Wrong raw bytes accepted")
            } catch { XCTAssertEqual(error as? BitcoinError,.invalidResponse) }
        }
    }
    func testAllFourChainsConfirmAtomicallyAndRemoveTracking() async throws {
        for chain in UTXONetwork.allCases {
            let (db, _, signed) = try await fixture(chain)
            try await db.settleBitcoinSend("send", confirmation: .init(raw: signed.raw, height: 200, timestamp: 1000))
            let row = try await db.pool.read { sql in
                (try String.fetchOne(sql, sql: "SELECT state FROM sends WHERE id='send'"),
                 try String.fetchOne(sql, sql: "SELECT state FROM transactions WHERE hash=?", arguments: [signed.txid]),
                 try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM sendStatusChecks"),
                 try Bool.fetchOne(sql, sql: "SELECT spent FROM utxos LIMIT 1"))
            }
            XCTAssertEqual(row.0, "confirmed"); XCTAssertEqual(row.1, "confirmed"); XCTAssertEqual(row.2, 0); XCTAssertEqual(row.3, true)
        }
    }
    func testMinedReplacementAndCancellationForAllFourChains() async throws {
        for chain in UTXONetwork.allCases {
            for canceled in [false, true] {
                let (db, plan, signed) = try await fixture(chain)
                let replacement = try BitcoinSendPlan.make(coins: plan.coins, recipient: canceled ? plan.change.address : plan.recipient,
                    amount: 20_000_000, change: plan.change, ratePerKVByte: plan.ratePerKVByte, chain: chain)
                let winner = try sign(replacement)
                try await db.settleBitcoinSend("send", confirmation: .init(raw: winner.raw, height: 200, timestamp: 1000))
                let send = try await db.send("send")
                let evidence = try await db.pool.read { sql in
                    (try String.fetchOne(sql, sql: "SELECT outcome FROM transactionEvidence WHERE transactionID=? LIMIT 1", arguments: [chain.rawValue + ":" + signed.txid]),
                     try String.fetchOne(sql, sql: "SELECT replacementHash FROM transactionEvidence WHERE transactionID=? LIMIT 1", arguments: [chain.rawValue + ":" + signed.txid]),
                     try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM sendStatusChecks"))
                }
                XCTAssertEqual(send?.state, "failed"); XCTAssertEqual(send?.failureCode, canceled ? "canceled" : "replaced")
                XCTAssertEqual(evidence.0, canceled ? "canceled" : "replaced"); XCTAssertEqual(evidence.1, winner.txid); XCTAssertEqual(evidence.2, 0)
            }
        }
    }
    func testMempoolOrUnrelatedTransactionCannotSettleOrReleaseInputs() async throws {
        let (db, plan, signed) = try await fixture(.bitcoin)
        for receipt in [BitcoinSendConfirmation(raw: signed.raw, height: 0, timestamp: 1000),
                        .init(raw: plan.coins[0].previousTransaction, height: 200, timestamp: 1000)] {
            do { try await db.settleBitcoinSend("send", confirmation: receipt); XCTFail("Unproven settlement accepted") }
            catch { /* Expected identity/inclusion rejection. */ }
        }
        let send = try await db.send("send"), inputs = try await db.reservedOutputs(sendID: "send")
        XCTAssertEqual(send?.state, "broadcast"); XCTAssertEqual(inputs.count, 1)
    }
}
