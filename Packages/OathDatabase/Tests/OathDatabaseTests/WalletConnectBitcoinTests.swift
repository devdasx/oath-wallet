import Foundation
import XCTest
import GRDB
@testable import OathBitcoin
@testable import OathDatabase

private struct ConnectFunding: BitcoinAddressQuerying {
    let scriptHash: String, txid: String
    func query(scriptHashes: [String]) async throws -> [BitcoinAddressState] {
        scriptHashes.map { $0 == scriptHash
            ? .init(confirmed:50_000,unconfirmed:0,history:[.init(txid:txid,height:100)],unspent:[.init(txid:txid,vout:0,value:50_000,height:100)])
            : .init(confirmed:0,unconfirmed:0,history:[],unspent:[]) }
    }
}

@MainActor final class WalletConnectBitcoinTests: XCTestCase {
    private let seed = Data(0..<32)
    private func fixture() async throws -> (OathDatabase, URL, BitcoinConnectPlan, BitcoinConnectSigned, BitcoinSendPlan) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BitcoinConnect-" + UUID().uuidString)
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        try await db.seed(networks:[.init(id:"bitcoin",name:"Bitcoin",family:"utxo",symbol:"BTC",decimals:8,derivationPath:"fixture",logo:"",sortOrder:0)],
            assets:[.init(id:"bitcoin:native",networkID:"bitcoin",reference:"native",name:"Bitcoin",symbol:"BTC",decimals:8)])
        let descriptor = try BitcoinKeys.wallet(seed:seed)
        let branch = descriptor.branches.first { $0.type == .nativeSegwit && $0.change == 0 }!
        let source = try BitcoinKeys.addresses(branch:branch,range:0..<1)[0]
        let recipient = try BitcoinKeys.addresses(branch:branch,range:12..<13)[0]
        for (w,a) in [("w","a"),("other","other-account")] {
            try await db.importWalletIfNeeded(.init(id:w,name:"Test",kind:"hd",vaultReference:"fixture-" + w,createdAt:1),
                accounts:[.init(id:a,walletID:w,networkID:"bitcoin",address:source.address,derivationPath:source.path)])
            try await db.prepareBitcoin(accountID:a,descriptor:descriptor)
        }
        let change = try await db.bitcoinChangeAddress(accountID:"a")
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating:17,count:32)
        raw += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(50_000)) + BitcoinWire.vector(Data(hex:source.script)!) + BitcoinWire.little(UInt32(0))
        let txid = try BitcoinTransactions.txid(raw)
        let scan = try await BitcoinDiscovery(query:ConnectFunding(scriptHash:source.scriptHash,txid:txid)).scan(descriptor)
        let scanID = try await db.beginBitcoinScan(accountID:"a")
        try await db.commitBitcoinScan(accountID:"a",scanID:scanID,scan:scan,transactions:[txid:raw],tipHeight:150)
        let request = try BitcoinConnectRequest(method:"sendTransfer",chain:BitcoinConnectNetwork.mainnet.chain,account:source.address,
            params:JSONSerialization.data(withJSONObject:["account":source.address,"recipientAddress":recipient.address,"amount":"10000"]))
        let (psbt,inputs) = try BitcoinConnectClient.transfer(request,coins:[.init(txid:txid,vout:0,value:50_000,address:source)],change:change,rate:2)
        let plan = try BitcoinConnectSigning.review(request:request,psbt:psbt,inputs:inputs,addresses:[source,change],previous:[txid:raw])
        let signed = try BitcoinConnectSigning.sign(plan,source:.seed(seed,account:0))
        let ordinary = try BitcoinSendPlan.make(coins:[.init(accountID:"a",txid:txid,vout:0,value:50_000,address:source,previousTransaction:raw)],
            recipient:recipient.address,amount:10_000,change:change,ratePerKVByte:2000)
        return (db,folder,plan,signed,ordinary)
    }
    func testDurableRetryOwnershipAndMonotonicSettlement() async throws {
        let (db,folder,plan,signed,_) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        _ = try await db.journalWalletConnectBitcoin(id:"one",walletID:"w",accountID:"a",plan:plan,signed:signed)
        _ = try await db.journalWalletConnectBitcoin(id:"one",walletID:"w",accountID:"a",plan:plan,signed:signed)
        for (id,w,a) in [("two","other","other-account"),("one","other","other-account"),("three","other","a")] {
            do { _ = try await db.journalWalletConnectBitcoin(id:id,walletID:w,accountID:a,plan:plan,signed:signed); XCTFail("Conflicting ownership or input") } catch { }
        }
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let saved = try await reopened.walletConnectBitcoinSubmission("one")
        XCTAssertEqual(try saved?.decoded().1,signed)
        var pending = try await reopened.pendingWalletConnectBitcoinSubmissions(); XCTAssertEqual(pending.count,1)
        try await reopened.settleWalletConnectBitcoin("one",status:.accepted)
        try await reopened.settleWalletConnectBitcoin("one",status:.unknown)
        let accepted = try await reopened.walletConnectBitcoinSubmission("one"); XCTAssertEqual(accepted?.state,"accepted")
        try await reopened.settleWalletConnectBitcoin("one",status:.confirmed)
        try await reopened.settleWalletConnectBitcoin("one",status:.unknown)
        let confirmed = try await reopened.walletConnectBitcoinSubmission("one"); XCTAssertEqual(confirmed?.state,"confirmed")
        pending = try await reopened.pendingWalletConnectBitcoinSubmissions(); XCTAssertTrue(pending.isEmpty)
        let spent = try await reopened.pool.read { try Int.fetchOne($0,sql:"SELECT spent FROM utxos LIMIT 1") }; XCTAssertEqual(spent,1)
    }
    func testOrdinarySendReservationBothDirections() async throws {
        for ordinaryFirst in [false,true] {
            let (db,folder,plan,signed,ordinary) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
            try await db.saveDraft(.init(id:"normal",walletID:"w",accountID:"a",networkID:"bitcoin",assetID:"bitcoin:native",idempotencyKey:"normal",
                recipient:ordinary.recipient,amountAtomic:String(ordinary.recipientAmount),state:"draft",createdAt:1,updatedAt:1))
            try await db.saveBitcoinSendPlan(sendID:"normal",plan:ordinary)
            let outputs = ordinary.coins.map { Outpoint(hash:$0.txid,index:$0.vout) }
            if ordinaryFirst {
                _ = try await db.queueSend("normal",outputs:outputs)
                do { _ = try await db.journalWalletConnectBitcoin(id:"wc",walletID:"w",accountID:"a",plan:plan,signed:signed); XCTFail("Input already reserved") } catch { }
            } else {
                _ = try await db.journalWalletConnectBitcoin(id:"wc",walletID:"w",accountID:"a",plan:plan,signed:signed)
                do { _ = try await db.queueSend("normal",outputs:outputs); XCTFail("Input already reserved") } catch { }
            }
        }
    }
    func testAddressOrderingAndResetGuard() async throws {
        let (db,folder,plan,signed,_) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let rows = try await db.walletConnectBitcoinAddresses(accountID:"a")
        XCTAssertEqual(rows.first?.type,.nativeSegwit); XCTAssertEqual(rows.first?.change,0); XCTAssertEqual(rows.first?.index,0)
        XCTAssertEqual(Set(rows.map(\.script)).count,rows.count)
        XCTAssertEqual(Set(rows.map(\.type)),Set(BitcoinAddressType.allCases))
        for type in BitcoinAddressType.allCases { for change: UInt32 in [0,1] {
            XCTAssertGreaterThanOrEqual(rows.filter { $0.type == type && $0.change == change }.count,2)
        } }
        try await db.pool.write { try $0.execute(sql:"INSERT INTO metadata(key,value) VALUES('walletReset','test')") }
        do { _ = try await db.journalWalletConnectBitcoin(id:"wc",walletID:"w",accountID:"a",plan:plan,signed:signed); XCTFail("Reset blocks submission") } catch { }
    }
    func testUTXORevisionChangesWithoutChangingAddresses() async throws {
        let (db,folder,_,_,_) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        let addresses = try await db.walletConnectBitcoinAddresses(accountID:"a")
        let original = try await db.walletConnectBitcoinUTXORevision(accountID:"a")
        let unchanged = try await db.walletConnectBitcoinUTXORevision(accountID:"a")
        XCTAssertEqual(original,unchanged)
        try await db.pool.write { try $0.execute(sql:"""
            INSERT INTO utxos(networkID,transactionHash,outputIndex,value,script,blockHeight,spent,reservedBy,updatedAt)
            SELECT networkID,?,outputIndex,value,script,blockHeight,spent,reservedBy,updatedAt FROM utxos LIMIT 1
            """,arguments:[String(repeating:"ab",count:32)]) }
        let replaced = try await db.walletConnectBitcoinUTXORevision(accountID:"a")
        let sameAddresses = try await db.walletConnectBitcoinAddresses(accountID:"a")
        XCTAssertNotEqual(original,replaced)
        XCTAssertEqual(addresses.map(\.script),sameAddresses.map(\.script))
        try await db.pool.write { try $0.execute(sql:"UPDATE utxos SET spent=1") }
        let spent = try await db.walletConnectBitcoinUTXORevision(accountID:"a")
        XCTAssertNotEqual(replaced,spent)
    }
}
