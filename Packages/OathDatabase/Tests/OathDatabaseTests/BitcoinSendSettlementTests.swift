import Foundation
import GRDB
import XCTest
@testable import OathBitcoin
@testable import OathDatabase

private struct StatusFundingQuery: BitcoinAddressQuerying {
    let funding: [String: String]
    func query(scriptHashes: [String]) async throws -> [BitcoinAddressState] {
        scriptHashes.map {
            guard let hash = funding[$0] else { return .init(confirmed: 0, unconfirmed: 0, history: [], unspent: []) }
            return .init(confirmed: 100_000_000, unconfirmed: 0,
                history: [.init(txid: hash, height: 100)], unspent: [.init(txid: hash, vout: 0, value: 100_000_000, height: 100)])
        }
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
    private func fixture(_ chain: UTXONetwork, selfTransfer: Bool = false, inputCount: UInt32 = 1,
                         addressType: BitcoinAddressType? = nil, options: BitcoinSendOptions = .init()) async throws -> (OathDatabase, BitcoinSendPlan, BitcoinSignedSend) {
        let db = try await OathDatabase.open(at: FileManager.default.temporaryDirectory.appendingPathComponent("StatusUTXO-" + UUID().uuidString).appendingPathComponent("db.sqlite"))
        try await db.seed(networks: [.init(id: chain.rawValue, name: "Test", family: "utxo", symbol: "TEST", decimals: 8, derivationPath: "fixture", logo: "", sortOrder: 0)],
            assets: [.init(id: chain.rawValue + ":native", networkID: chain.rawValue, reference: "native", name: "Test", symbol: "TEST", decimals: 8)])
        let descriptor = try chain.wallet(seed: seed)
        let sources = try BitcoinKeys.addresses(branch: descriptor.branches.first { $0.type == (addressType ?? descriptor.defaultType) && $0.change == 0 }!, range: 0..<inputCount)
        let source = sources[0]
        let other = try chain.wallet(seed: Data(1...32))
        let recipient = try BitcoinKeys.addresses(branch: other.branches[0], range: 0..<1)[0]
        try await db.importWalletIfNeeded(.init(id: "w", name: "Test", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "a", walletID: "w", networkID: chain.rawValue, address: source.address, derivationPath: source.path)])
        try await db.prepareBitcoin(accountID: "a", descriptor: descriptor)
        let change = try await db.bitcoinChangeAddress(accountID: "a")
        var coins: [BitcoinSendCoin] = []
        for address in sources {
            var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 17, count: 32)
            raw += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
            raw += BitcoinWire.little(UInt64(100_000_000)) + BitcoinWire.vector(Data(hex: address.script)!) + BitcoinWire.little(UInt32(0))
            let hash = try BitcoinTransactions.txid(raw, network: chain)
            coins.append(BitcoinSendCoin(accountID: "a", txid: hash, vout: 0, value: 100_000_000, address: address, previousTransaction: raw))
        }
        let scan = try await BitcoinDiscovery(query: StatusFundingQuery(funding: Dictionary(uniqueKeysWithValues: coins.map { ($0.address.scriptHash, $0.txid) }))).scan(descriptor)
        let scanID = try await db.beginBitcoinScan(accountID: "a")
        try await db.commitBitcoinScan(accountID: "a", scanID: scanID, scan: scan, transactions: Dictionary(uniqueKeysWithValues: coins.map { ($0.txid, $0.previousTransaction) }), tipHeight: 150)
        let plan = try BitcoinSendPlan.make(coins: coins, recipient: selfTransfer ? source.address : recipient.address, amount: 10_000_000 + Int64(inputCount - 1) * 100_000_000, change: change,
            ratePerKVByte: chain == .dogecoin ? 1_000_000 : 2000, chain: chain, options: options)
        try await db.saveDraft(.init(id: "send", walletID: "w", accountID: "a", networkID: chain.rawValue, assetID: chain.rawValue + ":native",
            idempotencyKey: "send", recipient: plan.recipient, amountAtomic: String(plan.recipientAmount), state: "draft", createdAt: 1, updatedAt: 1))
        try await db.saveBitcoinSendPlan(sendID: "send", plan: plan)
        _ = try await db.queueSend("send", outputs: plan.coins.map { .init(hash: $0.txid, index: $0.vout) })
        let signed = try sign(plan)
        try await db.journalBitcoinSignature(sendID: "send", signed: signed)
        _ = try await db.transitionSend("send", from: "signed", to: "broadcast")
        return (db, plan, signed)
    }
    func testSelfSendShowsOnlyFeeBeforeAndAfterConfirmationOnEveryUTXOChain() async throws {
        for chain in UTXONetwork.allCases {
            let (db, plan, signed) = try await fixture(chain, selfTransfer: true)
            var history = try await db.history(walletID: "w")
            var entry = try XCTUnwrap(history.first { $0.hash == signed.txid })
            XCTAssertEqual(entry.direction, "self", chain.rawValue)
            XCTAssertEqual(entry.displayAmountAtomic, String(plan.fee), chain.rawValue)
            XCTAssertEqual(entry.displayDirection, "outgoing")
            try await db.settleBitcoinSend("send", confirmation: .init(raw: signed.raw, height: 200, timestamp: 1000))
            history = try await db.history(walletID: "w")
            entry = try XCTUnwrap(history.first { $0.hash == signed.txid })
            XCTAssertEqual(entry.state, "confirmed")
            XCTAssertEqual(entry.displayAmountAtomic, String(plan.fee), chain.rawValue)
        }
    }
    func testBroadcastAcknowledgementKeepsExactBytesAndReservations() async throws {
        for chain in UTXONetwork.allCases {
            let (db, _, signed) = try await fixture(chain)
            let before = try await db.sendSubmission(walletID: "w", networkID: chain.rawValue, hash: signed.txid)
            XCTAssertEqual(before?.accepted, false)
            try await db.acknowledgeBitcoinSend("send", hash: signed.txid)
            let after = try await db.sendSubmission(walletID: "w", networkID: chain.rawValue, hash: signed.txid)
            XCTAssertEqual(after?.accepted, true)
            let stored = try await db.send("send")
            XCTAssertEqual(stored?.state, "broadcast")
            XCTAssertEqual(stored?.signedPayload, signed.raw)
            let reserved = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM utxos WHERE reservedBy='send'") }
            XCTAssertEqual(reserved, 1, "Acceptance must not release funds before settlement")
        }
    }

    private func sign(_ plan: BitcoinSendPlan) throws -> BitcoinSignedSend {
        if plan.chain == .bitcoincash { return try BitcoinCashSendSigner.sign(plan) { _ in .seed(seed, account: 0) } }
        return try BitcoinSendSigner.sign(plan) { _ in .seed(seed, account: 0) }
    }
    func testImmediateReceiptHasActualAddressesWithoutIndexerOnEveryUTXOChain() async throws {
        for chain in UTXONetwork.allCases {
            let (db, plan, signed) = try await fixture(chain)
            // The signed journal is durable before an indexer sees this hash.
            let indexed = try await db.pool.read { try Int.fetchOne($0,
                sql: "SELECT COUNT(*) FROM bitcoinTransactions WHERE txid=?", arguments: [signed.txid]) }
            XCTAssertEqual(indexed, 0)
            let fetched = try await db.transactionDetails(accountID: "a", transactionID: chain.rawValue + ":" + signed.txid)
            let receipt = try XCTUnwrap(fetched)
            XCTAssertEqual(receipt.fromAddresses, plan.coins.map { $0.address.address }.sorted(), chain.rawValue)
            XCTAssertEqual(Set(receipt.toAddresses), Set([plan.recipient, plan.change.address]), chain.rawValue)
            XCTAssertEqual(receipt.inputs?.map(\.amountAtomic), ["100000000"], chain.rawValue)
            XCTAssertEqual(receipt.outputs?.count, 2, chain.rawValue)
            XCTAssertEqual(receipt.transaction.feeAtomic, String(plan.fee))
            XCTAssertEqual(receipt.historyEntries.first?.amountAtomic, String(plan.recipientAmount))
        }
    }
    func testReceiptKeepsMultipleInputsAndChangeAfterReopenWithoutIndexedParents() async throws {
        for chain in UTXONetwork.allCases {
            let (db, plan, signed) = try await fixture(chain, inputCount: 2)
            try await db.pool.write { try $0.execute(sql: "DELETE FROM bitcoinTransactions") }
            let reopened = try await OathDatabase.open(at: URL(fileURLWithPath: db.pool.path))
            let value = try await reopened.transactionDetails(accountID: "a", transactionID: chain.rawValue + ":" + signed.txid)
            let receipt = try XCTUnwrap(value)
            XCTAssertEqual(receipt.fromAddresses, plan.coins.map { $0.address.address }.sorted(), chain.rawValue)
            XCTAssertEqual(receipt.inputs?.map(\.id), plan.coins.map(\.id), chain.rawValue)
            XCTAssertEqual(receipt.inputs?.map(\.amountAtomic), ["100000000", "100000000"], chain.rawValue)
            XCTAssertEqual(Set(receipt.toAddresses), Set([plan.recipient, plan.change.address]), chain.rawValue)
            try await reopened.settleBitcoinSend("send", confirmation: .init(raw: signed.raw, height: 200, timestamp: 1000))
            let confirmed = try await reopened.transactionDetails(accountID: "a", transactionID: chain.rawValue + ":" + signed.txid)
            XCTAssertEqual(confirmed?.inputs, receipt.inputs)
            XCTAssertEqual(confirmed?.outputs, receipt.outputs)
            XCTAssertEqual(confirmed?.state, "confirmed")
        }
    }

    func testMessageOutputSurvivesJournalReopenAndIndexingForEveryAddressType() async throws {
        let message = "Payment note 💙\nرسالة"
        for chain in UTXONetwork.allCases {
            let types = Set(try chain.wallet(seed: seed).branches.map(\.type))
            for type in types {
                let (db, plan, signed) = try await fixture(chain, addressType: type,
                    options: .init(message: Data(message.utf8)))
                let id = chain.rawValue + ":" + signed.txid
                let fetched = try await db.transactionDetails(accountID: "a", transactionID: id)
                let receipt = try XCTUnwrap(fetched)
                let outputs = try XCTUnwrap(receipt.outputs)
                XCTAssertEqual(outputs.count, 3)
                XCTAssertEqual(Set(receipt.toAddresses), Set([plan.recipient, plan.change.address]))
                XCTAssertTrue(outputs.prefix(2).allSatisfy { $0.address != nil && $0.dataOutput == nil })
                let dataOutput = try XCTUnwrap(outputs.last)
                XCTAssertEqual(dataOutput.id, "2")
                XCTAssertNil(dataOutput.address)
                XCTAssertEqual(dataOutput.amountAtomic, "0")
                XCTAssertEqual(dataOutput.dataOutput?.message, message)

                // Old receipts must reconstruct the message offline from durable bytes.
                let reopened = try await OathDatabase.open(at: URL(fileURLWithPath: db.pool.path))
                let restored = try await reopened.transactionDetails(accountID: "a", transactionID: id)
                XCTAssertEqual(restored?.outputs, outputs)
                try await reopened.pool.write { sql in
                    try sql.execute(sql: "INSERT INTO bitcoinTransactions(accountID,txid,raw) VALUES(?,?,?)",
                        arguments: ["a", signed.txid, signed.raw])
                }
                let indexed = try await reopened.transactionDetails(accountID: "a", transactionID: id)
                XCTAssertEqual(indexed?.outputs, outputs)
                try await reopened.settleBitcoinSend("send", confirmation: .init(raw: signed.raw, height: 200, timestamp: 1000))
                let confirmed = try await reopened.transactionDetails(accountID: "a", transactionID: id)
                XCTAssertEqual(confirmed?.outputs, outputs)
                XCTAssertEqual(confirmed?.state, "confirmed")
            }
        }
    }
    func testReceiptDoesNotReadAnotherWalletsSignedJournal() async throws {
        let (db, plan, signed) = try await fixture(.bitcoin)
        try await db.importWalletIfNeeded(.init(id: "other", name: "Other", kind: "hd", vaultReference: "fixture-other", createdAt: 1),
            accounts: [.init(id: "other", walletID: "other", networkID: "bitcoin", address: plan.recipient, derivationPath: "fixture")])
        let id = "bitcoin:" + signed.txid
        try await db.pool.write { db in
            try ActivityRecord(id: "other-receipt", walletID: "other", accountID: "other", networkID: "bitcoin", transactionID: id,
                assetID: "bitcoin:native", direction: "incoming", amountAtomic: "10000000", counterparty: "", timestamp: 1).insert(db)
        }
        let fetched = try await db.transactionDetails(accountID: "other", transactionID: id)
        let receipt = try XCTUnwrap(fetched)
        XCTAssertEqual(receipt.fromAddresses, [])
        XCTAssertEqual(receipt.toAddresses, [])
        XCTAssertNil(receipt.inputs)
    }
    func testReceiptRejectsMismatchedSignedBytesAndParentHashes() async throws {
        let (db, plan, signed) = try await fixture(.bitcoin)
        let id = "bitcoin:" + signed.txid
        try await db.pool.write { db in
            try db.execute(sql: "DELETE FROM bitcoinTransactions")
            try db.execute(sql: "UPDATE sends SET signedPayload=? WHERE id='send'", arguments: [plan.coins[0].previousTransaction])
        }
        do { _ = try await db.transactionDetails(accountID: "a", transactionID: id); XCTFail("Mislinked signed transaction accepted") }
        catch { XCTAssertEqual(error as? StoreError, .conflictingIdentity) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var coins = try XCTUnwrap(object["coins"] as? [[String: Any]])
        coins[0]["previousTransaction"] = signed.raw.base64EncodedString()
        object["coins"] = coins
        let alteredPlan = try JSONSerialization.data(withJSONObject: object)
        try await db.pool.write { db in
            try db.execute(sql: "UPDATE sends SET signedPayload=? WHERE id='send'", arguments: [signed.raw])
            try db.execute(sql: "UPDATE bitcoinSendPlans SET plan=? WHERE sendID='send'", arguments: [alteredPlan])
        }
        do { _ = try await db.transactionDetails(accountID: "a", transactionID: id); XCTFail("Mismatched funding transaction accepted") }
        catch { XCTAssertEqual(error as? StoreError, .conflictingIdentity) }
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
