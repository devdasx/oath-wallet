import Foundation
import XCTest
import GRDB
import OathBitcoin
@testable import OathDatabase

private struct MempoolQuery: BitcoinAddressQuerying {
    let states: [String: BitcoinAddressState]
    func query(scriptHashes: [String]) async throws -> [BitcoinAddressState] {
        scriptHashes.map { states[$0] ?? .init(confirmed: 0, unconfirmed: 0, history: [], unspent: []) }
    }
}
private actor PostSendScanCount {
    var value = 0
    func next() -> Int { value += 1; return value }
}

/// Public deterministic fixtures only; no installed wallet or network. The
/// tests exercise discovery, signing, durable SQL and atomic reservations.
@MainActor final class UTXOMempoolTests: XCTestCase {
    private struct Fixture: Sendable {
        let db: OathDatabase
        let url: URL
        let wallet: BitcoinWalletDescriptor
        let network: UTXONetwork
        var asset: String { network.rawValue + ":native" }
    }
    private struct Funding {
        let raw: Data
        let txid: String
        func output(_ index: Int, value: Int64, height: Int64 = 0) -> BitcoinUnspent {
            .init(txid: txid, vout: index, value: value, height: height)
        }
        func history(_ height: Int64 = 0) -> BitcoinHistoryItem { .init(txid: txid, height: height) }
    }

    private func fixture(_ network: UTXONetwork, compressed: Bool? = nil) async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathMempool-" + UUID().uuidString).appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        let wallet: BitcoinWalletDescriptor
        if let compressed {
            let key = Data(repeating: 0, count: 31) + Data([1])
            wallet = try network.singleKey(bytes: key, compressed: compressed)
        } else {
            wallet = try network.wallet(seed: Data(0..<32))
        }
        let first = try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<1)[0]
        try await db.seed(networks: [.init(id: network.rawValue, name: network.rawValue, family: "utxo", symbol: "TEST", decimals: 8, derivationPath: first.path, logo: "", sortOrder: 0)],
                          assets: [.init(id: network.rawValue + ":native", networkID: network.rawValue, reference: "native", name: network.rawValue, symbol: "TEST", decimals: 8)])
        for n in 1...2 {
            try await db.importWalletIfNeeded(.init(id: "w\(n)", name: "Fixture", kind: "hd", vaultReference: "test-\(n)", createdAt: 1),
                accounts: [.init(id: "a\(n)", walletID: "w\(n)", networkID: network.rawValue, address: first.address, derivationPath: first.path)])
            try await db.prepareBitcoin(accountID: "a\(n)", descriptor: wallet)
        }
        try await db.savePrices([.init(assetID: network.rawValue + ":native", currency: "USD", value: "100", observedAt: 1, source: "fixture")])
        return Fixture(db: db, url: url, wallet: wallet, network: network)
    }

    private func funding(_ outputs: [(BitcoinDerivedAddress, Int64)], nonce: UInt8 = 17, parent: Funding? = nil, coinbase: Bool = false) throws -> Funding {
        var raw = Data([2, 0, 0, 0, 1])
        raw += parent.map { Data(hex($0.txid).reversed()) } ?? Data(repeating: coinbase ? 0 : nonce, count: 32)
        raw += coinbase ? Data([255, 255, 255, 255, 2, 1, 1]) : Data([0, 0, 0, 0, 0])
        raw += Data([255, 255, 255, 255, UInt8(outputs.count)])
        for (address, amount) in outputs {
            var value = UInt64(amount).littleEndian
            raw += withUnsafeBytes(of: &value) { Data($0) }
            let script = hex(address.script)
            raw.append(UInt8(script.count)); raw += script
        }
        raw += Data(repeating: 0, count: 4)
        return Funding(raw: raw, txid: try BitcoinTransactions.txid(raw))
    }
    private func hex(_ string: String) -> Data {
        Data(stride(from: 0, to: string.count, by: 2).map { offset in
            let index = string.index(string.startIndex, offsetBy: offset)
            return UInt8(string[index..<string.index(index, offsetBy: 2)], radix: 16)!
        })
    }

    func testBitcoinSignedJournalSurvivesRestartAndKeepsReservations() async throws {
        let f = try await fixture(.bitcoin)
        let receive = try BitcoinKeys.addresses(branch: f.wallet.branches.first { $0.type == .nativeSegwit && $0.change == 0 }!, range: 0..<1)[0]
        let funding = try funding([(receive,100_000)])
        try await commit(f, states: [receive.scriptHash:.init(confirmed: 100_000, unconfirmed: 0,
            history: [funding.history(800_000)], unspent: [funding.output(0,value:100_000,height:800_000)])], raw: [funding])
        let change = try await f.db.bitcoinChangeAddress(accountID: "a1")
        let second = try await f.db.bitcoinChangeAddress(accountID: "a1")
        XCTAssertEqual(change.address,second.address, "Opening review must not exhaust the change gap")
        XCTAssertEqual(change.change,1)
        let inputs = try await coins(f).map { BitcoinSendCoin(accountID:$0.output.accountID, txid:$0.output.transactionHash,
            vout:$0.output.outputIndex,value:$0.output.value,address:$0.derivation,previousTransaction:$0.previousTransaction) }
        let recipient = try BitcoinKeys.addresses(branch:f.wallet.branches.first { $0.type == .taproot && $0.change == 0 }!,range:5..<6)[0]
        let plan = try BitcoinSendPlan.make(coins: inputs, recipient:recipient.address,amount:50_000,change:change,ratePerKVByte:2000)
        let sendID = UUID().uuidString
        try await f.db.saveDraft(.init(id:sendID,walletID:"w1",accountID:"a1",networkID:"bitcoin",assetID:"bitcoin:native",
            idempotencyKey:sendID,recipient:recipient.address,amountAtomic:String(plan.recipientAmount),state:"draft",createdAt:1,updatedAt:1))
        try await f.db.saveBitcoinSendPlan(sendID:sendID,plan:plan)
        _ = try await f.db.queueSend(sendID,outputs:inputs.map { .init(hash:$0.txid,index:$0.vout) })
        let signed = try BitcoinSendSigner.sign(plan) { _ in .seed(Data(0..<32),account:0) }
        try await f.db.journalBitcoinSignature(sendID:sendID,signed:signed)
        let afterSigning = try await f.db.bitcoinChangeAddress(accountID: "a1")
        XCTAssertNotEqual(afterSigning.address, change.address, "A signed transfer's change is committed")
        let reopened = try await OathDatabase.open(at:f.url)
        let stored = try await reopened.send(sendID)
        XCTAssertEqual(stored?.signedPayload,signed.raw)
        XCTAssertEqual(stored?.state,"signed")
        XCTAssertEqual(stored?.transactionID,"bitcoin:"+signed.txid)
        let restoredPlan = try await reopened.bitcoinSendPlan(sendID:sendID)
        XCTAssertEqual(restoredPlan,plan)
        let reserved = try await reopened.reservedOutputs(sendID:sendID)
        XCTAssertEqual(reserved.count,1)
        _ = try await reopened.transitionSend(sendID,from:"signed",to:"broadcast")
        do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed"); XCTFail("Unknown submission must not release inputs") } catch { }
        do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"cancelled"); XCTFail("Cannot cancel signed submission") } catch { }
        let stillReserved = try await reopened.reservedOutputs(sendID:sendID)
        XCTAssertEqual(stillReserved.count,1)
        for state in ["pending", "confirmed"] {
            try await reopened.pool.write { db in
                let winner = TransactionRecord(id:"bitcoin:competitor",networkID:"bitcoin",hash:"competitor",state:state,
                    blockHeight:state == "confirmed" ? 800_001 : nil,timestamp:2,feeAtomic:"1000",updatedAt:2)
                try winner.save(db)
                try OathDatabase.saveTransactionEvidence(accountID:"a1",tx:winner,keys:Set(inputs.map(\.id)),returnsToWallet:true,db:db)
            }
            if state == "pending" {
                do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed"); XCTFail("Unmined competitor must not release inputs") } catch { }
            } else {
                _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed")
                let settled = try await reopened.reservedOutputs(sendID:sendID)
                XCTAssertTrue(settled.isEmpty)
            }
        }
    }

    func testBitcoinCashSignedJournalSurvivesRestartAndKeepsReservations() async throws {
        let f = try await fixture(.bitcoincash)
        let receive = try BitcoinKeys.addresses(branch: f.wallet.branches.first { $0.type == .legacy && $0.change == 0 }!, range: 0..<1)[0]
        let funding = try funding([(receive,100_000)])
        try await commit(f, states: [receive.scriptHash:.init(confirmed: 100_000, unconfirmed: 0,
            history: [funding.history(800_000)], unspent: [funding.output(0,value:100_000,height:800_000)])], raw: [funding])
        let change = try await f.db.bitcoinChangeAddress(accountID: "a1")
        let second = try await f.db.bitcoinChangeAddress(accountID: "a1")
        XCTAssertEqual(change.address,second.address, "Opening review must not exhaust the change gap")
        XCTAssertEqual(change.change,1)
        let inputs = try await coins(f).map { BitcoinSendCoin(accountID:$0.output.accountID, txid:$0.output.transactionHash,
            vout:$0.output.outputIndex,value:$0.output.value,address:$0.derivation,previousTransaction:$0.previousTransaction) }
        let recipient = try BitcoinKeys.addresses(branch:f.wallet.branches.first { $0.type == .legacy && $0.change == 0 }!,range:5..<6)[0]
        let plan = try BitcoinSendPlan.make(coins: inputs, recipient:recipient.address,amount:50_000,change:change,ratePerKVByte:2000,chain:.bitcoincash)
        let sendID = UUID().uuidString
        try await f.db.saveDraft(.init(id:sendID,walletID:"w1",accountID:"a1",networkID:"bitcoincash",assetID:"bitcoincash:native",
            idempotencyKey:sendID,recipient:recipient.address,amountAtomic:String(plan.recipientAmount),state:"draft",createdAt:1,updatedAt:1))
        try await f.db.saveBitcoinSendPlan(sendID:sendID,plan:plan)
        _ = try await f.db.queueSend(sendID,outputs:inputs.map { .init(hash:$0.txid,index:$0.vout) })
        let signed = try BitcoinCashSendSigner.sign(plan) { _ in .seed(Data(0..<32),account:0) }
        try await f.db.journalBitcoinSignature(sendID:sendID,signed:signed)
        let afterSigning = try await f.db.bitcoinChangeAddress(accountID: "a1")
        XCTAssertNotEqual(afterSigning.address, change.address, "A signed transfer's change is committed")
        let reopened = try await OathDatabase.open(at:f.url)
        let stored = try await reopened.send(sendID)
        XCTAssertEqual(stored?.signedPayload,signed.raw)
        XCTAssertEqual(stored?.state,"signed")
        XCTAssertEqual(stored?.transactionID,"bitcoincash:"+signed.txid)
        let restoredPlan = try await reopened.bitcoinSendPlan(sendID:sendID)
        XCTAssertEqual(restoredPlan,plan)
        let reserved = try await reopened.reservedOutputs(sendID:sendID)
        XCTAssertEqual(reserved.count,1)
        _ = try await reopened.transitionSend(sendID,from:"signed",to:"broadcast")
        do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed"); XCTFail("Unknown submission must not release inputs") } catch { }
        do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"cancelled"); XCTFail("Cannot cancel signed submission") } catch { }
        let stillReserved = try await reopened.reservedOutputs(sendID:sendID)
        XCTAssertEqual(stillReserved.count,1)
        for state in ["pending", "confirmed"] {
            try await reopened.pool.write { db in
                let winner = TransactionRecord(id:"bitcoincash:competitor",networkID:"bitcoincash",hash:"competitor",state:state,
                    blockHeight:state == "confirmed" ? 800_001 : nil,timestamp:2,feeAtomic:"1000",updatedAt:2)
                try winner.save(db)
                try OathDatabase.saveTransactionEvidence(accountID:"a1",tx:winner,keys:Set(inputs.map(\.id)),returnsToWallet:true,db:db)
            }
            if state == "pending" {
                do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed"); XCTFail("Unmined competitor must not release inputs") } catch { }
            } else {
                _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed")
                let settled = try await reopened.reservedOutputs(sendID:sendID)
                XCTAssertTrue(settled.isEmpty)
            }
        }
    }

    func testLitecoinSignedJournalSurvivesRestartAndKeepsReservations() async throws {
        let f = try await fixture(.litecoin)
        let receive = try BitcoinKeys.addresses(branch: f.wallet.branches.first { $0.type == .nativeSegwit && $0.change == 0 }!, range: 0..<1)[0]
        let funding = try funding([(receive,100_000)])
        try await commit(f, states: [receive.scriptHash:.init(confirmed: 100_000, unconfirmed: 0,
            history: [funding.history(800_000)], unspent: [funding.output(0,value:100_000,height:800_000)])], raw: [funding])
        let change = try await f.db.bitcoinChangeAddress(accountID: "a1")
        let second = try await f.db.bitcoinChangeAddress(accountID: "a1")
        XCTAssertEqual(change.address,second.address, "Opening review must not exhaust the change gap")
        XCTAssertEqual(change.change,1)
        let inputs = try await coins(f).map { BitcoinSendCoin(accountID:$0.output.accountID, txid:$0.output.transactionHash,
            vout:$0.output.outputIndex,value:$0.output.value,address:$0.derivation,previousTransaction:$0.previousTransaction) }
        let recipient = try BitcoinKeys.addresses(branch:f.wallet.branches.first { $0.type == .nativeSegwit && $0.change == 0 }!,range:5..<6)[0]
        let plan = try BitcoinSendPlan.make(coins: inputs, recipient:recipient.address,amount:50_000,change:change,ratePerKVByte:2000,chain:.litecoin)
        let sendID = UUID().uuidString
        try await f.db.saveDraft(.init(id:sendID,walletID:"w1",accountID:"a1",networkID:"litecoin",assetID:"litecoin:native",
            idempotencyKey:sendID,recipient:recipient.address,amountAtomic:String(plan.recipientAmount),state:"draft",createdAt:1,updatedAt:1))
        try await f.db.saveBitcoinSendPlan(sendID:sendID,plan:plan)
        _ = try await f.db.queueSend(sendID,outputs:inputs.map { .init(hash:$0.txid,index:$0.vout) })
        let signed = try BitcoinSendSigner.sign(plan) { _ in .seed(Data(0..<32),account:0) }
        try await f.db.journalBitcoinSignature(sendID:sendID,signed:signed)
        let afterSigning = try await f.db.bitcoinChangeAddress(accountID: "a1")
        XCTAssertNotEqual(afterSigning.address, change.address, "A signed transfer's change is committed")
        let reopened = try await OathDatabase.open(at:f.url)
        let stored = try await reopened.send(sendID)
        XCTAssertEqual(stored?.signedPayload,signed.raw)
        XCTAssertEqual(stored?.state,"signed")
        XCTAssertEqual(stored?.transactionID,"litecoin:"+signed.txid)
        let restoredPlan = try await reopened.bitcoinSendPlan(sendID:sendID)
        XCTAssertEqual(restoredPlan,plan)
        let reserved = try await reopened.reservedOutputs(sendID:sendID)
        XCTAssertEqual(reserved.count,1)
        _ = try await reopened.transitionSend(sendID,from:"signed",to:"broadcast")
        do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed"); XCTFail("Unknown submission must not release inputs") } catch { }
        do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"cancelled"); XCTFail("Cannot cancel signed submission") } catch { }
        let stillReserved = try await reopened.reservedOutputs(sendID:sendID)
        XCTAssertEqual(stillReserved.count,1)
        for state in ["pending", "confirmed"] {
            try await reopened.pool.write { db in
                let winner = TransactionRecord(id:"litecoin:competitor",networkID:"litecoin",hash:"competitor",state:state,
                    blockHeight:state == "confirmed" ? 800_001 : nil,timestamp:2,feeAtomic:"1000",updatedAt:2)
                try winner.save(db)
                try OathDatabase.saveTransactionEvidence(accountID:"a1",tx:winner,keys:Set(inputs.map(\.id)),returnsToWallet:true,db:db)
            }
            if state == "pending" {
                do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed"); XCTFail("Unmined competitor must not release inputs") } catch { }
            } else {
                _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed")
                let settled = try await reopened.reservedOutputs(sendID:sendID)
                XCTAssertTrue(settled.isEmpty)
            }
        }
    }

    func testDogecoinSignedJournalSurvivesRestartAndKeepsReservations() async throws {
        let f = try await fixture(.dogecoin)
        let receive = try BitcoinKeys.addresses(branch: f.wallet.branches.first { $0.type == .legacy && $0.change == 0 }!, range: 0..<1)[0]
        let funding = try funding([(receive,100_000_000)])
        try await commit(f, states: [receive.scriptHash:.init(confirmed: 100_000_000, unconfirmed: 0,
            history: [funding.history(800_000)], unspent: [funding.output(0,value:100_000_000,height:800_000)])], raw: [funding])
        let change = try await f.db.bitcoinChangeAddress(accountID: "a1")
        let second = try await f.db.bitcoinChangeAddress(accountID: "a1")
        XCTAssertEqual(change.address,second.address, "Opening review must not exhaust the change gap")
        XCTAssertEqual(change.change,1)
        let inputs = try await coins(f).map { BitcoinSendCoin(accountID:$0.output.accountID, txid:$0.output.transactionHash,
            vout:$0.output.outputIndex,value:$0.output.value,address:$0.derivation,previousTransaction:$0.previousTransaction) }
        let recipient = try BitcoinKeys.addresses(branch:f.wallet.branches.first { $0.type == .legacy && $0.change == 0 }!,range:5..<6)[0]
        let plan = try BitcoinSendPlan.make(coins: inputs, recipient:recipient.address,amount:50_000_000,change:change,ratePerKVByte:1_000_000,chain:.dogecoin)
        let sendID = UUID().uuidString
        try await f.db.saveDraft(.init(id:sendID,walletID:"w1",accountID:"a1",networkID:"dogecoin",assetID:"dogecoin:native",
            idempotencyKey:sendID,recipient:recipient.address,amountAtomic:String(plan.recipientAmount),state:"draft",createdAt:1,updatedAt:1))
        try await f.db.saveBitcoinSendPlan(sendID:sendID,plan:plan)
        _ = try await f.db.queueSend(sendID,outputs:inputs.map { .init(hash:$0.txid,index:$0.vout) })
        let signed = try BitcoinSendSigner.sign(plan) { _ in .seed(Data(0..<32),account:0) }
        try await f.db.journalBitcoinSignature(sendID:sendID,signed:signed)
        let afterSigning = try await f.db.bitcoinChangeAddress(accountID: "a1")
        XCTAssertNotEqual(afterSigning.address, change.address, "A signed transfer's change is committed")
        let reopened = try await OathDatabase.open(at:f.url)
        let stored = try await reopened.send(sendID)
        XCTAssertEqual(stored?.signedPayload,signed.raw)
        XCTAssertEqual(stored?.state,"signed")
        XCTAssertEqual(stored?.transactionID,"dogecoin:"+signed.txid)
        let restoredPlan = try await reopened.bitcoinSendPlan(sendID:sendID)
        XCTAssertEqual(restoredPlan,plan)
        let reserved = try await reopened.reservedOutputs(sendID:sendID)
        XCTAssertEqual(reserved.count,1)
        _ = try await reopened.transitionSend(sendID,from:"signed",to:"broadcast")
        do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed"); XCTFail("Unknown submission must not release inputs") } catch { }
        do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"cancelled"); XCTFail("Cannot cancel signed submission") } catch { }
        let stillReserved = try await reopened.reservedOutputs(sendID:sendID)
        XCTAssertEqual(stillReserved.count,1)
        for state in ["pending", "confirmed"] {
            try await reopened.pool.write { db in
                let winner = TransactionRecord(id:"dogecoin:competitor",networkID:"dogecoin",hash:"competitor",state:state,
                    blockHeight:state == "confirmed" ? 800_001 : nil,timestamp:2,feeAtomic:"1000",updatedAt:2)
                try winner.save(db)
                try OathDatabase.saveTransactionEvidence(accountID:"a1",tx:winner,keys:Set(inputs.map(\.id)),returnsToWallet:true,db:db)
            }
            if state == "pending" {
                do { _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed"); XCTFail("Unmined competitor must not release inputs") } catch { }
            } else {
                _ = try await reopened.transitionSend(sendID,from:"broadcast",to:"failed")
                let settled = try await reopened.reservedOutputs(sendID:sendID)
                XCTAssertTrue(settled.isEmpty)
            }
        }
    }

    func testLitecoinDiagnosticMigrationPreservesQueuedBitcoinAndCashEvents() async throws {
        let f = try await fixture(.litecoin)
        let bitcoin = SendDiagnostic(stage:"quote",code:"network",inputCount:0,appBuild:1)
        let cash = SendDiagnostic(stage:"sign",code:"signing",inputCount:1,appBuild:1,network:"bitcoincash")
        try await f.db.enqueueSendDiagnostic(bitcoin); try await f.db.enqueueSendDiagnostic(cash)
        // Reproduce the shipped v30 outbox, then let the actual migrator run.
        try await f.db.pool.write { db in
            try db.execute(sql: """
                ALTER TABLE sendDiagnostics RENAME TO newDiagnostics;
                CREATE TABLE sendDiagnostics (
                    id TEXT PRIMARY KEY NOT NULL, stage TEXT NOT NULL, code TEXT NOT NULL,
                    inputCount INTEGER NOT NULL, appBuild INTEGER NOT NULL, createdAt DOUBLE NOT NULL,
                    network TEXT NOT NULL DEFAULT 'bitcoin' CHECK(network IN ('bitcoin','bitcoincash'))
                );
                INSERT INTO sendDiagnostics SELECT * FROM newDiagnostics;
                DROP TABLE newDiagnostics;
                DELETE FROM grdb_migrations WHERE identifier IN ('v31_litecoin_send','v32_dogecoin_send');
                """)
        }
        let reopened = try await OathDatabase.open(at:f.url)
        let event = SendDiagnostic(stage:"broadcast",code:"submissionUnknown",inputCount:2,appBuild:1,network:"litecoin")
        try await reopened.enqueueSendDiagnostic(event)
        let all = try await reopened.sendDiagnostics()
        XCTAssertEqual(Set(all.map(\.id)),Set([bitcoin.id,cash.id,event.id]))
        XCTAssertEqual(Set(all.map(\.network)),Set(["bitcoin","bitcoincash","litecoin"]))
    }

    func testDogecoinDiagnosticMigrationPreservesAllQueuedChains() async throws {
        let f = try await fixture(.dogecoin)
        let bitcoin = SendDiagnostic(stage:"quote",code:"network",inputCount:0,appBuild:1)
        let litecoin = SendDiagnostic(stage:"quote",code:"network",inputCount:0,appBuild:1,network:"litecoin")
        let cash = SendDiagnostic(stage:"sign",code:"signing",inputCount:1,appBuild:1,network:"bitcoincash")
        try await f.db.enqueueSendDiagnostic(bitcoin); try await f.db.enqueueSendDiagnostic(cash); try await f.db.enqueueSendDiagnostic(litecoin)
        // Reproduce the shipped v31 outbox, then let the actual migrator run.
        try await f.db.pool.write { db in
            try db.execute(sql: """
                ALTER TABLE sendDiagnostics RENAME TO newDiagnostics;
                CREATE TABLE sendDiagnostics (
                    id TEXT PRIMARY KEY NOT NULL, stage TEXT NOT NULL, code TEXT NOT NULL,
                    inputCount INTEGER NOT NULL, appBuild INTEGER NOT NULL, createdAt DOUBLE NOT NULL,
                    network TEXT NOT NULL DEFAULT 'bitcoin' CHECK(network IN ('bitcoin','bitcoincash','litecoin'))
                );
                INSERT INTO sendDiagnostics SELECT * FROM newDiagnostics;
                DROP TABLE newDiagnostics;
                DELETE FROM grdb_migrations WHERE identifier='v32_dogecoin_send';
                """)
        }
        let reopened = try await OathDatabase.open(at:f.url)
        let event = SendDiagnostic(stage:"broadcast",code:"submissionUnknown",inputCount:2,appBuild:1,network:"dogecoin")
        try await reopened.enqueueSendDiagnostic(event)
        let all = try await reopened.sendDiagnostics()
        XCTAssertEqual(Set(all.map(\.id)),Set([bitcoin.id,cash.id,litecoin.id,event.id]))
        XCTAssertEqual(Set(all.map(\.network)),Set(["bitcoin","bitcoincash","litecoin","dogecoin"]))
    }

    func testSendDiagnosticsAreDurableAndRejectFreeformPayloads() async throws {
        let f = try await fixture(.bitcoin)
        let event = SendDiagnostic(stage:"sign",code:"signing",inputCount:2,appBuild:56,network:"bitcoincash")
        try await f.db.enqueueSendDiagnostic(event)
        let reopened = try await OathDatabase.open(at:f.url)
        let rows = try await reopened.sendDiagnostics()
        XCTAssertEqual(rows.map(\.id),[event.id])
        XCTAssertEqual(rows.first?.network,"bitcoincash")
        do {
            try await reopened.enqueueSendDiagnostic(.init(stage:"sign",code:"arbitrary text",inputCount:0,appBuild:0))
            XCTFail("Freeform error text must never enter telemetry")
        } catch { }
        try await reopened.removeSendDiagnostic(id:event.id)
        let remaining = try await reopened.sendDiagnostics()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testBitcoinCashTokensCountInBalanceButCannotEnterOrdinarySpendingPool() async throws {
        let f = try await fixture(.bitcoincash)
        let receive = try BitcoinKeys.addresses(branch: f.wallet.branches[0], range: 0..<1)[0]
        let change = try BitcoinKeys.addresses(branch: f.wallet.branches[1], range: 0..<1)[0]
        let plain = try funding([(receive, 70_000), (change, 30_000)])
        // First output carries one fungible CashToken; its locking script and
        // BCH satoshis are still the same. Second output is ordinary change.
        let tokenPrefix = Data([0xef]) + Data(repeating: 34, count: 32) + Data([0x10,1])
        let tokenRaw = plain.raw.prefix(55) + Data([UInt8(25 + tokenPrefix.count)]) + tokenPrefix + plain.raw.dropFirst(56)
        let token = Funding(raw: tokenRaw, txid: try BitcoinTransactions.txid(tokenRaw, network: .bitcoincash))
        let states = [receive.scriptHash: BitcoinAddressState(confirmed: 0, unconfirmed: 70_000,
                        history: [token.history()], unspent: [token.output(0, value: 70_000)]),
                      change.scriptHash: BitcoinAddressState(confirmed: 0, unconfirmed: 30_000,
                        history: [token.history()], unspent: [token.output(1, value: 30_000)])]
        try await commit(f, states: states, raw: [token])
        try await assertDisplay(f, total: 100_000, confirmed: 0, unconfirmed: 100_000)
        let reopened = try await OathDatabase.open(at: f.url)
        let pool = try await coins(f, database: reopened)
        XCTAssertEqual(pool.map(\.output.outputIndex), [1])
        XCTAssertEqual(pool.first?.output.value, 30_000)
        XCTAssertEqual(pool.first?.previousTransaction, tokenRaw)
        let paged = try await reopened.spendableOutputs(accountID: "a1")
        XCTAssertEqual(paged.map(\.outputIndex), [1], "The legacy paging API must also protect CashTokens")
        let after = try await reopened.spendableOutputs(accountID: "a1", after: .init(value: 30_000, hash: token.txid, index: 1))
        XCTAssertTrue(after.isEmpty)
        try await draft(f, id: "token-burn-attempt")
        do {
            _ = try await f.db.queueSend("token-burn-attempt", outputs: [.init(hash: token.txid, index: 0)])
            XCTFail("Token-bearing output was reserved for an ordinary BCH send")
        } catch { }
        try await draft(f, id: "plain-change")
        _ = try await f.db.queueSend("plain-change", outputs: [.init(hash: token.txid, index: 1)])
        let reserved = try await f.db.reservedOutputs(sendID: "plain-change")
        XCTAssertEqual(reserved.map(\.outputIndex), [1])
    }

    func testLitecoinHogExFundingPersistsAndRemainsSpendable() async throws {
        let f = try await fixture(.litecoin, compressed: true)
        let address = try BitcoinKeys.addresses(branch: f.wallet.branches[0], range: 0..<1)[0]
        let ordinary = try funding([(address, 75_000)])
        let hogOutput = Data(repeating: 0, count: 8) + Data([34, 0x58, 32]) + Data(repeating: 34, count: 32)
        let canonical = ordinary.raw.prefix(46) + Data([2]) + hogOutput + ordinary.raw.dropFirst(47)
        let original = Funding(raw: canonical, txid: try BitcoinTransactions.txid(canonical, network: .litecoin))
        // Same public txid with Litecoin's MWEB flag and null extension (HogEx).
        let raw = original.raw.prefix(4) + Data([0, 8]) + original.raw.dropFirst(4).dropLast(4)
            + Data([0]) + original.raw.suffix(4)
        XCTAssertEqual(try BitcoinTransactions.txid(raw, network: .litecoin), original.txid)
        let funding = Funding(raw: raw, txid: original.txid)
        let states = [address.scriptHash: BitcoinAddressState(confirmed: 75_000, unconfirmed: 0,
            history: [funding.history(800_296)], unspent: [funding.output(1, value: 75_000, height: 800_296)])]
        try await commit(f, states: states, raw: [funding])
        let immature = try await coins(f)
        XCTAssertTrue(immature.isEmpty, "A five-confirmation MWEB withdrawal cannot be reserved")
        try await assertDisplay(f, total: 75_000, confirmed: 75_000, unconfirmed: 0)
        try await commit(f, states: states, raw: [], tip: 800_301)
        let reopened = try await OathDatabase.open(at: f.url)
        let available = try await coins(f, database: reopened)
        XCTAssertEqual(available.count, 1)
        XCTAssertEqual(available.first?.previousTransaction, raw)
        XCTAssertEqual(available.first?.output.value, 75_000)
        try await assertDisplay(f, total: 75_000, confirmed: 75_000, unconfirmed: 0, database: reopened)
    }
    func testMessageAndRBFArePreservedInAllChainJournals() async throws {
        for network in UTXONetwork.allCases {
            let f = try await fixture(network)
            let a = try BitcoinKeys.addresses(branch: f.wallet.branches[0], range: 0..<1)[0]
            let parent = try funding([(a, 100_000_000)])
            try await commit(f, states: [a.scriptHash: .init(confirmed: 100_000_000, unconfirmed: 0,
                history: [parent.history(1)], unspent: [parent.output(0, value: 100_000_000, height: 1)])], raw: [parent])
            let available = try await coins(f)
            let inputs = available.map { BitcoinSendCoin(accountID: $0.output.accountID, txid: $0.output.transactionHash,
                vout: $0.output.outputIndex, value: $0.output.value, address: $0.derivation, previousTransaction: $0.previousTransaction) }
            let change = try await f.db.bitcoinChangeAddress(accountID: "a1")
            let options = BitcoinSendOptions(replaceable: BitcoinSendOptions.supportsRBF(network), message: Data("Journal 💙".utf8))
            let plan = try BitcoinSendPlan.make(coins: inputs, recipient: a.address, amount: 50_000_000, change: change,
                ratePerKVByte: network == .dogecoin ? 1_000_000 : 1000, chain: network, options: options)
            _ = try await signAndJournal(f, plan: plan, source: .seed(Data(0..<32), account: 0))
        }
    }

    private func commit(_ f: Fixture, states: [String: BitcoinAddressState], raw: [Funding], account: String = "a1", database: OathDatabase? = nil, tip: Int64 = 800_300) async throws {
        let db = database ?? f.db
        let previous = try await db.bitcoinState(accountID: account)
        let scan = try await BitcoinDiscovery(query: MempoolQuery(states: states)).scan(f.wallet, requiredThrough: previous?.requiredThrough ?? [:])
        let id = try await db.beginBitcoinScan(accountID: account)
        try await db.commitBitcoinScan(accountID: account, scanID: id, scan: scan,
            transactions: Dictionary(uniqueKeysWithValues: raw.map { ($0.txid, $0.raw) }), tipHeight: tip)
    }
    private func coins(_ f: Fixture, database: OathDatabase? = nil) async throws -> [BitcoinSpendableOutput] {
        try await (database ?? f.db).bitcoinSpendableOutputs(walletID: "w1", network: f.network)
    }
    private func draft(_ f: Fixture, id: String, wallet: Int = 1) async throws {
        try await f.db.saveDraft(.init(id: id, walletID: "w\(wallet)", accountID: "a\(wallet)", networkID: f.network.rawValue,
            assetID: f.asset, idempotencyKey: id, recipient: "fixture", amountAtomic: "1", state: "draft", createdAt: 1, updatedAt: 1))
    }

    func testReviewReusesOnlyRecentlyVerifiedCompleteSnapshotsForEveryChain() async throws {
        for network in UTXONetwork.allCases {
            let f = try await fixture(network, compressed: true)
            let unscanned = try await f.db.bitcoinSnapshotIsRecentForSend(accountID: "a1")
            let missing = try await f.db.bitcoinSnapshotIsRecentForSend(accountID: "missing")
            XCTAssertFalse(unscanned); XCTAssertFalse(missing)

            try await commit(f, states: [:], raw: [])
            let committed = try await f.db.bitcoinState(accountID: "a1")
            let state = try XCTUnwrap(committed)
            let success = try XCTUnwrap(state.lastSuccess)
            for age in [0.0, 1.0, 29.0, 30.0] {
                let reusable = try await f.db.bitcoinSnapshotIsRecentForSend(accountID: "a1", now: success.addingTimeInterval(age))
                XCTAssertTrue(reusable, "A complete fresh snapshot should avoid duplicate discovery")
            }
            for age in [-1.0, 30.001, 120.0] {
                let reusable = try await f.db.bitcoinSnapshotIsRecentForSend(accountID: "a1", now: success.addingTimeInterval(age))
                XCTAssertFalse(reusable, "Expired/future snapshots must perform discovery")
            }
            let otherAccount = try await f.db.bitcoinSnapshotIsRecentForSend(accountID: "a2")
            XCTAssertFalse(otherAccount, "An account cannot reuse another account's successful scan")
            let afterReads = try await f.db.bitcoinState(accountID: "a1")
            XCTAssertEqual(afterReads?.lastSuccess, success, "Reuse cannot renew freshness")

            let scanID = try await f.db.beginBitcoinScan(accountID: "a1")
            let running = try await f.db.bitcoinSnapshotIsRecentForSend(accountID: "a1")
            XCTAssertFalse(running, "Wait for a running scan instead of consuming its prior snapshot")
            try await f.db.failBitcoinScan(accountID: "a1", scanID: scanID, code: "timeout")
            let failed = try await f.db.bitcoinSnapshotIsRecentForSend(accountID: "a1")
            XCTAssertFalse(failed, "A failure invalidates reuse even inside the age window")
        }
    }
    private func signAndJournal(_ f: Fixture, plan: BitcoinSendPlan,
                                source: BitcoinPrivateKeySource, database: OathDatabase? = nil) async throws -> Funding {
        let db = database ?? f.db
        let id = UUID().uuidString
        try await db.saveDraft(.init(id: id, walletID: "w1", accountID: "a1", networkID: f.network.rawValue,
            assetID: f.asset, idempotencyKey: id, recipient: plan.recipient,
            amountAtomic: String(plan.recipientAmount), state: "draft", createdAt: 1, updatedAt: 1))
        try await db.saveBitcoinSendPlan(sendID: id, plan: plan)
        _ = try await db.queueSend(id, outputs: plan.coins.map { .init(hash: $0.txid, index: $0.vout) })
        let signed = try f.network == .bitcoincash
            ? BitcoinCashSendSigner.sign(plan) { _ in source }
            : BitcoinSendSigner.sign(plan) { _ in source }
        if !plan.options.message.isEmpty {
            let alteredOptions = BitcoinSendOptions(replaceable: plan.options.replaceable, message: Data(repeating: 97, count: plan.options.message.count))
            let altered = try BitcoinSendPlan.make(coins: plan.coins, recipient: plan.recipient, amount: plan.requestedAmount,
                change: plan.change, ratePerKVByte: plan.ratePerKVByte, chain: plan.chain, options: alteredOptions)
            let wrongSignature = try f.network == .bitcoincash
                ? BitcoinCashSendSigner.sign(altered) { _ in source }
                : BitcoinSendSigner.sign(altered) { _ in source }
            do {
                try await db.journalBitcoinSignature(sendID: id, signed: wrongSignature)
                XCTFail("Journal accepted a different on-chain message")
            } catch { XCTAssertEqual(error as? BitcoinSendError, .changed) }
            let unchanged = try await db.send(id)
            XCTAssertEqual(unchanged?.state, "queued")
            XCTAssertNil(unchanged?.signedPayload)
        }
        try await db.journalBitcoinSignature(sendID: id, signed: signed)
        // Production persists this state before submitting. No network is used here.
        _ = try await db.transitionSend(id, from: "signed", to: "broadcast")
        let reopened = try await OathDatabase.open(at: f.url)
        let stored = try await reopened.send(id)
        let savedPlan = try await reopened.bitcoinSendPlan(sendID: id)
        XCTAssertEqual(savedPlan, plan)
        XCTAssertEqual(stored?.signedPayload, signed.raw)
        XCTAssertEqual(stored?.transactionID, f.network.rawValue + ":" + signed.txid)
        XCTAssertEqual(stored?.state, "broadcast")
        let reserved = try await reopened.reservedOutputs(sendID: id)
        XCTAssertEqual(Set(reserved.map { "\($0.transactionHash):\($0.outputIndex)" }), Set(plan.coins.map(\.id)))
        let details = try BitcoinTransactions.details(signed.raw, network: f.network)
        XCTAssertEqual(details.outputs[0].value, plan.recipientAmount)
        XCTAssertEqual(plan.coins.reduce(0) { $0 + $1.value } - details.outputs.reduce(0) { $0 + $1.value }, plan.fee)
        return Funding(raw: signed.raw, txid: signed.txid)
    }
    private func assertDisplay(_ f: Fixture, total: Int64, confirmed: Int64, unconfirmed: Int64, database: OathDatabase? = nil) async throws {
        let db = database ?? f.db
        let state = try await db.bitcoinState(accountID: "a1")
        XCTAssertEqual(state?.confirmed, confirmed); XCTAssertEqual(state?.unconfirmed, unconfirmed)
        let snapshot = try await db.snapshot(walletID: "w1", currency: "USD")
        let holding = try XCTUnwrap(snapshot.holdings.first { $0.assetID == f.asset })
        XCTAssertTrue(holding.usesUTXOLedger)
        XCTAssertEqual(holding.amountAtomic, String(total))
        XCTAssertEqual(holding.nativeDisplayValue, Decimal(total) / 100_000_000)
        XCTAssertEqual(holding.fiatDisplayValue, Decimal(total) / 1_000_000)
        XCTAssertEqual(snapshot.totalFiat, Decimal(total) / 1_000_000)
        XCTAssertTrue(snapshot.valuationComplete)
    }

    func testConfirmedAndIncomingPendingAcrossEveryBranchDisplayAndReserveTogether() async throws {
        for network in UTXONetwork.allCases {
            let f = try await fixture(network)
            let addresses = try f.wallet.branches.map { try BitcoinKeys.addresses(branch: $0, range: 0..<1)[0] }
            let confirmed = try funding(addresses.map { ($0, 50_000) })
            let pending = try funding(addresses.map { ($0, 20_000) }, nonce: 18)
            let states = Dictionary(uniqueKeysWithValues: addresses.enumerated().map { index, address in
                (address.scriptHash, BitcoinAddressState(confirmed: 50_000, unconfirmed: 20_000,
                    history: [confirmed.history(800_000), pending.history(index % 2 == 0 ? 0 : -1)],
                    unspent: [confirmed.output(index, value: 50_000, height: 800_000), pending.output(index, value: 20_000)]))
            })
            for account in ["a1", "a2"] { try await commit(f, states: states, raw: [confirmed, pending], account: account) }
            let count = Int64(addresses.count)
            try await assertDisplay(f, total: 70_000 * count, confirmed: 50_000 * count, unconfirmed: 20_000 * count)
            let pool = try await coins(f)
            XCTAssertEqual(pool.count, addresses.count * 2)
            XCTAssertEqual(pool.filter { $0.output.blockHeight == nil }.count, addresses.count)
            XCTAssertEqual(Set(pool.map { $0.derivation.type }), Set(f.wallet.types))
            XCTAssertEqual(Set(pool.map { $0.derivation.change }), [0, 1])
            try await draft(f, id: "first"); try await draft(f, id: "competing", wallet: 2)
            let points = pool.map { Outpoint(hash: $0.output.transactionHash, index: $0.output.outputIndex) }
            _ = try await f.db.queueSend("first", outputs: points)
            let reserved = try await f.db.reservedOutputs(sendID: "first")
            XCTAssertEqual(reserved.count, pool.count)
            XCTAssertEqual(reserved.filter { $0.blockHeight == nil }.count, addresses.count)
            do { _ = try await f.db.queueSend("competing", outputs: points); XCTFail("Pending inputs reserved twice") }
            catch { XCTAssertEqual(error as? StoreError, .reservationConflict) }
            let remaining = try await coins(f); XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testPendingSpendSubtractsConfirmedInputsAndPendingChangeCanBeSpentAgain() async throws {
        for network in UTXONetwork.allCases {
            let f = try await fixture(network)
            let branch = f.wallet.branches.first { $0.change == 1 }!
            let receive = try BitcoinKeys.addresses(branch: f.wallet.branches[0], range: 0..<1)[0]
            let change = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0]
            let nextChange = try BitcoinKeys.addresses(branch: branch, range: 1..<2)[0]
            let original = try funding([(receive, 50_000), (change, 20_000)])
            let parent = try funding([(nextChange, 12_000)], parent: original)
            let child = try funding([(nextChange, 5_000)], parent: parent)
            let spentReceive = BitcoinAddressState(confirmed: 50_000, unconfirmed: -50_000,
                history: [original.history(800_000), parent.history()], unspent: [])
            let untouchedChange = BitcoinAddressState(confirmed: 20_000, unconfirmed: 0,
                history: [original.history(800_000)], unspent: [original.output(1, value: 20_000, height: 800_000)])
            try await commit(f, states: [receive.scriptHash: spentReceive, change.scriptHash: untouchedChange,
                nextChange.scriptHash: .init(confirmed: 0, unconfirmed: 12_000, history: [parent.history()], unspent: [parent.output(0, value: 12_000)])], raw: [original, parent])
            try await assertDisplay(f, total: 32_000, confirmed: 70_000, unconfirmed: -38_000)
            let before = try await coins(f)
            XCTAssertEqual(Set(before.map { $0.output.transactionHash }), [original.txid, parent.txid])
            XCTAssertFalse(before.contains { $0.output.transactionHash == original.txid && $0.output.outputIndex == 0 })

            try await commit(f, states: [receive.scriptHash: spentReceive, change.scriptHash: untouchedChange,
                nextChange.scriptHash: .init(confirmed: 0, unconfirmed: 5_000, history: [parent.history(), child.history(-1)], unspent: [child.output(0, value: 5_000)])], raw: [child])
            try await assertDisplay(f, total: 25_000, confirmed: 70_000, unconfirmed: -45_000)
            let after = try await coins(f)
            XCTAssertEqual(Set(after.map { $0.output.transactionHash }), [original.txid, child.txid])
            try await draft(f, id: "child")
            _ = try await f.db.queueSend("child", outputs: [.init(hash: child.txid, index: 0)])
            let reserved = try await f.db.reservedOutputs(sendID: "child")
            XCTAssertEqual(reserved.first?.value, 5_000); XCTAssertNil(reserved.first?.blockHeight)
        }
    }

    func testPostSendWorkerRefreshesRealSignedBalancesAcrossAllFourChains() async throws {
        for network in UTXONetwork.allCases {
            for mode in ["external", "self", "send-all"] {
                let f = try await fixture(network)
                let addresses = try f.wallet.branches.map { try BitcoinKeys.addresses(branch: $0, range: 0..<1)[0] }
                let value: Int64 = 100_000_000
                let funding = try funding(addresses.map { ($0, value) })
                let before = Dictionary(uniqueKeysWithValues: addresses.enumerated().map { index, address in
                    (address.scriptHash, BitcoinAddressState(confirmed: value, unconfirmed: 0,
                        history: [funding.history(800_000)], unspent: [funding.output(index, value: value, height: 800_000)]))
                })
                try await commit(f, states: before, raw: [funding])
                let available = try await coins(f)
                let inputs = available.map { BitcoinSendCoin(accountID: $0.output.accountID, txid: $0.output.transactionHash,
                    vout: $0.output.outputIndex, value: $0.output.value, address: $0.derivation, previousTransaction: $0.previousTransaction) }
                let change = try await f.db.bitcoinChangeAddress(accountID: "a1")
                let destination = try network.wallet(seed: Data(32..<64))
                let recipient = try mode == "self" ? addresses[0] : BitcoinKeys.addresses(branch: destination.branches[0], range: 0..<1)[0]
                let plan = try BitcoinSendPlan.make(coins: inputs, recipient: recipient.address,
                    amount: inputs.reduce(0) { $0 + $1.value } - (mode == "send-all" ? 0 : 50_000_000), change: change,
                    ratePerKVByte: network == .dogecoin ? 1_000_000 : 2_000, chain: network)
                XCTAssertEqual(plan.coins.count, addresses.count)
                let sent = try await signAndJournal(f, plan: plan, source: .seed(Data(0..<32), account: 0))
                var after = Dictionary(uniqueKeysWithValues: addresses.map { address in
                    (address.scriptHash, BitcoinAddressState(confirmed: value, unconfirmed: -value,
                        history: [funding.history(800_000), sent.history(0)], unspent: []))
                })
                if plan.changeAmount > 0 {
                    after[change.scriptHash] = .init(confirmed: 0, unconfirmed: plan.changeAmount,
                        history: [sent.history(0)], unspent: [sent.output(1, value: plan.changeAmount)])
                }
                if mode == "self" {
                    after[recipient.scriptHash] = .init(confirmed: value, unconfirmed: plan.recipientAmount - value,
                        history: [funding.history(800_000), sent.history(0)], unspent: [sent.output(0, value: plan.recipientAmount)])
                }
                let observedStates = after, counter = PostSendScanCount()
                let target = SendBalanceRefreshTarget(walletID: "w1", networkID: network.rawValue)
                let worker = PostSendBalanceRefresher(database: f.db, delays: [.zero, .zero, .zero], sleep: { _ in }) { target, sends in
                    XCTAssertEqual(target.walletID, "w1"); XCTAssertEqual(target.networkID, network.rawValue)
                    let attempt = await counter.next()
                    // The first completed provider scan is valid but predates the
                    // broadcast. Only the second contains consumed inputs/change.
                    let previous = try await f.db.bitcoinState(accountID: "a1")
                    let scan = try await BitcoinDiscovery(query: MempoolQuery(states: attempt == 1 ? before : observedStates))
                        .scan(f.wallet, requiredThrough: previous?.requiredThrough ?? [:])
                    let scanID = try await f.db.beginBitcoinScan(accountID: "a1")
                    let raw = attempt == 1 ? [funding] : [sent]
                    try await f.db.commitBitcoinScan(accountID: "a1", scanID: scanID, scan: scan,
                        transactions: Dictionary(uniqueKeysWithValues: raw.map { ($0.txid, $0.raw) }), tipHeight: 800_300)
                    var reflected: Set<String> = []
                    for send in sends where try await f.db.bitcoinSendBalanceIsCurrent(send) { reflected.insert(send.id) }
                    return reflected
                }
                await worker.resume()
                for _ in 0..<300 {
                    if try await f.db.pendingSendBalanceRefreshes(target).isEmpty { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let remaining = try await f.db.pendingSendBalanceRefreshes(target), count = await counter.value
                XCTAssertTrue(remaining.isEmpty); XCTAssertEqual(count, 2, "Stale success must retry on \(network)")
                let expectedTotal = plan.changeAmount + (mode == "self" ? plan.recipientAmount : 0)
                try await assertDisplay(f, total: expectedTotal,
                    confirmed: Int64(addresses.count) * value, unconfirmed: expectedTotal - Int64(addresses.count) * value)
                let other = try await f.db.balance(accountID: "a2", assetID: f.asset)
                XCTAssertNil(other, "Refresh must not write another wallet's balance")
                await worker.pause()
            }
        }
    }

    func testPendingAndMixedInputsSignAcrossAllBranchesThenSpendSignedPendingChange() async throws {
        for network in UTXONetwork.allCases {
            for includeConfirmed in [false, true] {
                let f = try await fixture(network)
                let addresses = try f.wallet.branches.map { try BitcoinKeys.addresses(branch: $0, range: 0..<1)[0] }
                let value: Int64 = 100_000_000
                let pending = try funding(addresses.map { ($0, value) })
                let confirmed = try funding(addresses.map { ($0, value) }, nonce: 18)
                var states = Dictionary(uniqueKeysWithValues: addresses.enumerated().map { index, address in
                    (address.scriptHash, BitcoinAddressState(confirmed: includeConfirmed ? value : 0, unconfirmed: value,
                        history: [pending.history(-1)] + (includeConfirmed ? [confirmed.history(800_000)] : []),
                        unspent: [pending.output(index, value: value)] +
                            (includeConfirmed ? [confirmed.output(index, value: value, height: 800_000)] : [])))
                })
                try await commit(f, states: states, raw: [pending] + (includeConfirmed ? [confirmed] : []))
                let pool = try await coins(f)
                XCTAssertEqual(pool.filter { $0.output.blockHeight == nil }.count, addresses.count)
                let inputs = pool.map { BitcoinSendCoin(accountID: $0.output.accountID, txid: $0.output.transactionHash,
                    vout: $0.output.outputIndex, value: $0.output.value, address: $0.derivation, previousTransaction: $0.previousTransaction) }
                let change = try await f.db.bitcoinChangeAddress(accountID: "a1")
                let destination = try network.wallet(seed: Data(32..<64))
                let recipient = try BitcoinKeys.addresses(branch: destination.branches[0], range: 0..<1)[0]
                let rate: Int64 = network == .dogecoin ? 1_000_000 : 2_000
                let amount = inputs.reduce(0) { $0 + $1.value } - 50_000_000
                let plan = try BitcoinSendPlan.make(coins: inputs, recipient: recipient.address, amount: amount,
                    change: change, ratePerKVByte: rate, chain: network)
                XCTAssertEqual(Set(plan.coins.map(\.id)), Set(inputs.map(\.id)), "Every pending input must participate in signing on \(network)")
                XCTAssertEqual(Set(plan.coins.map { $0.address.type }), Set(f.wallet.types))
                XCTAssertEqual(Set(plan.coins.map { $0.address.change }), [0, 1])
                XCTAssertEqual(plan.recipientAmount, amount)
                XCTAssertGreaterThan(plan.changeAmount, 25_000_000)
                let parent = try await signAndJournal(f, plan: plan, source: .seed(Data(0..<32), account: 0))

                // The server observes the signed parent in its mempool. Inputs
                // disappear; its real change output remains at zero confirmations.
                for address in addresses {
                    states[address.scriptHash] = .init(confirmed: includeConfirmed ? value : 0,
                        unconfirmed: includeConfirmed ? -value : 0,
                        history: states[address.scriptHash]!.history + [parent.history(-1)], unspent: [])
                }
                states[change.scriptHash] = .init(confirmed: 0, unconfirmed: plan.changeAmount,
                    history: [parent.history(-1)], unspent: [parent.output(1, value: plan.changeAmount)])
                let reopened = try await OathDatabase.open(at: f.url)
                try await commit(f, states: states, raw: [parent], database: reopened)
                let childPool = try await coins(f, database: reopened)
                XCTAssertEqual(childPool.count, 1)
                let childOutput = try XCTUnwrap(childPool.first)
                XCTAssertNil(childOutput.output.blockHeight)
                XCTAssertEqual(childOutput.output.transactionHash, parent.txid)
                XCTAssertEqual(childOutput.previousTransaction, parent.raw)
                let childChange = try await reopened.bitcoinChangeAddress(accountID: "a1")
                let child = try BitcoinSendPlan.make(coins: childPool.map {
                    BitcoinSendCoin(accountID: $0.output.accountID, txid: $0.output.transactionHash,
                        vout: $0.output.outputIndex, value: $0.output.value, address: $0.derivation, previousTransaction: $0.previousTransaction)
                }, recipient: recipient.address, amount: 25_000_000, change: childChange, ratePerKVByte: rate, chain: network)
                XCTAssertEqual(child.recipientAmount, 25_000_000)
                _ = try await signAndJournal(f, plan: child, source: .seed(Data(0..<32), account: 0), database: reopened)
                let remaining = try await coins(f, database: reopened)
                XCTAssertTrue(remaining.isEmpty, "Pending change cannot be spent twice")
            }
        }
    }

    func testPendingConfirmationReorgAndReopenKeepTotalAndReservation() async throws {
        for network in UTXONetwork.allCases {
            let f = try await fixture(network)
            let address = try BitcoinKeys.addresses(branch: f.wallet.branches[0], range: 0..<1)[0]
            let payment = try funding([(address, 20_000)])
            let pending = BitcoinAddressState(confirmed: 0, unconfirmed: 20_000, history: [payment.history(-1)], unspent: [payment.output(0, value: 20_000)])
            try await commit(f, states: [address.scriptHash: pending], raw: [payment])
            try await draft(f, id: "reserved")
            _ = try await f.db.queueSend("reserved", outputs: [.init(hash: payment.txid, index: 0)])
            let reopened = try await OathDatabase.open(at: f.url)
            try await assertDisplay(f, total: 20_000, confirmed: 0, unconfirmed: 20_000, database: reopened)
            let confirmed = BitcoinAddressState(confirmed: 20_000, unconfirmed: 0,
                history: [payment.history(800_300)], unspent: [payment.output(0, value: 20_000, height: 800_300)])
            try await commit(f, states: [address.scriptHash: confirmed], raw: [], database: reopened)
            try await assertDisplay(f, total: 20_000, confirmed: 20_000, unconfirmed: 0, database: reopened)
            var reserved = try await reopened.reservedOutputs(sendID: "reserved")
            XCTAssertEqual(reserved.count, 1); XCTAssertEqual(reserved.first?.blockHeight, 800_300)
            try await commit(f, states: [address.scriptHash: pending], raw: [], database: reopened)
            try await assertDisplay(f, total: 20_000, confirmed: 0, unconfirmed: 20_000, database: reopened)
            reserved = try await reopened.reservedOutputs(sendID: "reserved")
            XCTAssertEqual(reserved.count, 1); XCTAssertNil(reserved.first?.blockHeight)
            let unavailable = try await coins(f, database: reopened); XCTAssertTrue(unavailable.isEmpty)
            _ = try await reopened.transitionSend("reserved", from: "queued", to: "cancelled")
            let available = try await coins(f, database: reopened)
            XCTAssertEqual(available.count, 1); XCTAssertNil(available.first?.output.blockHeight)
        }
    }

    func testDroppedPendingSpendRestoresItsConfirmedInputWithoutKeepingChange() async throws {
        for network in UTXONetwork.allCases {
            let f = try await fixture(network)
            let receive = try BitcoinKeys.addresses(branch: f.wallet.branches[0], range: 0..<1)[0]
            let change = try BitcoinKeys.addresses(branch: f.wallet.branches.first { $0.change == 1 }!, range: 0..<1)[0]
            let incoming = try funding([(receive, 50_000)])
            let outgoing = try funding([(change, 12_000)], parent: incoming)
            let confirmed = [receive.scriptHash: BitcoinAddressState(confirmed: 50_000, unconfirmed: 0,
                history: [incoming.history(800_000)], unspent: [incoming.output(0, value: 50_000, height: 800_000)])]
            try await commit(f, states: confirmed, raw: [incoming])
            try await commit(f, states: [
                receive.scriptHash: .init(confirmed: 50_000, unconfirmed: -50_000,
                    history: [incoming.history(800_000), outgoing.history()], unspent: []),
                change.scriptHash: .init(confirmed: 0, unconfirmed: 12_000,
                    history: [outgoing.history()], unspent: [outgoing.output(0, value: 12_000)])
            ], raw: [outgoing])
            try await assertDisplay(f, total: 12_000, confirmed: 50_000, unconfirmed: -38_000)
            try await commit(f, states: confirmed, raw: [])
            try await assertDisplay(f, total: 50_000, confirmed: 50_000, unconfirmed: 0)
            let pool = try await coins(f)
            XCTAssertEqual(pool.count, 1); XCTAssertEqual(pool.first?.output.transactionHash, incoming.txid)
            let history = try await f.db.bitcoinHistory(accountID: "a1")
            XCTAssertEqual(history, [incoming.history(800_000)])
            try await draft(f, id: "restored")
            _ = try await f.db.queueSend("restored", outputs: [.init(hash: incoming.txid, index: 0)])
        }
    }

    func testReplacedAndDroppedPendingOutputsCannotBeReserved() async throws {
        for network in UTXONetwork.allCases {
            let f = try await fixture(network)
            let address = try BitcoinKeys.addresses(branch: f.wallet.branches[0], range: 0..<1)[0]
            let original = try funding([(address, 20_000)])
            let replacement = try funding([(address, 10_000)]) // Same input, lower-value replacement.
            for payment in [original, replacement] {
                let value: Int64 = payment.txid == original.txid ? 20_000 : 10_000
                try await commit(f, states: [address.scriptHash: .init(confirmed: 0, unconfirmed: value,
                    history: [payment.history()], unspent: [payment.output(0, value: value)])], raw: [payment])
            }
            try await assertDisplay(f, total: 10_000, confirmed: 0, unconfirmed: 10_000)
            let pool = try await coins(f); XCTAssertEqual(pool.map { $0.output.transactionHash }, [replacement.txid])
            let history = try await f.db.bitcoinHistory(accountID: "a1"); XCTAssertEqual(history.map(\.txid), [replacement.txid])
            try await draft(f, id: "replaced")
            do { _ = try await f.db.queueSend("replaced", outputs: [.init(hash: original.txid, index: 0)]); XCTFail("Replaced output reserved") }
            catch { XCTAssertEqual(error as? StoreError, .reservationConflict) }
            try await commit(f, states: [:], raw: [])
            try await assertDisplay(f, total: 0, confirmed: 0, unconfirmed: 0)
            let empty = try await coins(f); XCTAssertTrue(empty.isEmpty)
            do { _ = try await f.db.queueSend("replaced", outputs: [.init(hash: replacement.txid, index: 0)]); XCTFail("Dropped output reserved") }
            catch { XCTAssertEqual(error as? StoreError, .reservationConflict) }
        }
    }

    func testFailedScanPreservesPendingDisplayButRequiresFreshPoolBeforeSpending() async throws {
        for network in UTXONetwork.allCases {
            let f = try await fixture(network)
            let address = try BitcoinKeys.addresses(branch: f.wallet.branches[0], range: 0..<1)[0]
            let payment = try funding([(address, 20_000)])
            let states = [address.scriptHash: BitcoinAddressState(confirmed: 0, unconfirmed: 20_000,
                history: [payment.history()], unspent: [payment.output(0, value: 20_000)])]
            try await commit(f, states: states, raw: [payment])
            let id = try await f.db.beginBitcoinScan(accountID: "a1")
            try await f.db.failBitcoinScan(accountID: "a1", scanID: id, code: "timeout")
            try await assertDisplay(f, total: 20_000, confirmed: 0, unconfirmed: 20_000)
            try await draft(f, id: "stale")
            do { _ = try await f.db.queueSend("stale", outputs: [.init(hash: payment.txid, index: 0)]); XCTFail("Failed scan allowed spending") }
            catch { XCTAssertEqual(error as? StoreError, .staleSync) }
            try await commit(f, states: states, raw: [])
            _ = try await f.db.queueSend("stale", outputs: [.init(hash: payment.txid, index: 0)])
        }
    }

    func testCompressedAndUncompressedImportsCanSignPendingOutputs() async throws {
        for network in UTXONetwork.allCases {
            for compressed in [true, false] {
                let f = try await fixture(network, compressed: compressed)
                let addresses = try f.wallet.branches.map { try BitcoinKeys.addresses(branch: $0, range: 0..<1)[0] }
                let value: Int64 = 100_000_000
                let payment = try funding(addresses.map { ($0, value) })
                let states = Dictionary(uniqueKeysWithValues: addresses.enumerated().map { index, address in
                    (address.scriptHash, BitcoinAddressState(confirmed: 0, unconfirmed: value,
                        history: [payment.history()], unspent: [payment.output(index, value: value)]))
                })
                try await commit(f, states: states, raw: [payment])
                let pool = try await coins(f)
                XCTAssertEqual(pool.count, addresses.count); XCTAssertTrue(pool.allSatisfy { $0.output.blockHeight == nil })
                let total = Int64(addresses.count) * value
                try await assertDisplay(f, total: total, confirmed: 0, unconfirmed: total)
                let change = try await f.db.bitcoinChangeAddress(accountID: "a1")
                let recipient = try BitcoinKeys.addresses(branch: network.wallet(seed: Data(32..<64)).branches[0], range: 0..<1)[0]
                let plan = try BitcoinSendPlan.make(coins: pool.map {
                    BitcoinSendCoin(accountID: $0.output.accountID, txid: $0.output.transactionHash,
                        vout: $0.output.outputIndex, value: $0.output.value, address: $0.derivation,
                        previousTransaction: $0.previousTransaction, compressed: compressed)
                }, recipient: recipient.address, amount: total - 25_000_000, change: change,
                   ratePerKVByte: network == .dogecoin ? 1_000_000 : 2_000, chain: network)
                XCTAssertEqual(plan.coins.count, addresses.count)
                _ = try await signAndJournal(f, plan: plan,
                    source: .single(Data(repeating: 0, count: 31) + Data([1]), compressed: compressed))
            }
        }
    }

    func testUnconfirmedMiningRewardCountsInTotalButCannotBeSpent() async throws {
        for network in UTXONetwork.allCases {
            let f = try await fixture(network)
            let address = try BitcoinKeys.addresses(branch: f.wallet.branches[0], range: 0..<1)[0]
            let reward = try funding([(address, 20_000)], coinbase: true)
            try await commit(f, states: [address.scriptHash: .init(confirmed: 0, unconfirmed: 20_000,
                history: [reward.history()], unspent: [reward.output(0, value: 20_000)])], raw: [reward])
            let pool = try await coins(f); XCTAssertTrue(pool.isEmpty)
            try await assertDisplay(f, total: 20_000, confirmed: 0, unconfirmed: 20_000)
            try await draft(f, id: "immature")
            do { _ = try await f.db.queueSend("immature", outputs: [.init(hash: reward.txid, index: 0)]); XCTFail("Mining maturity bypassed") }
            catch { XCTAssertEqual(error as? StoreError, .reservationConflict) }
        }
    }
}
