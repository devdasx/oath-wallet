import Foundation
import GRDB
import XCTest
@testable import OathAnkr
@testable import OathDatabase

private actor InventoryReadGate {
    private var entered = false
    private var released = false
    private var ready: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        ready.forEach { $0.resume() }; ready.removeAll()
        if !released { await withCheckedContinuation { pending = $0 } }
    }
    func waitUntilRead() async {
        if !entered { await withCheckedContinuation { ready.append($0) } }
    }
    func release() { released = true; pending?.resume(); pending = nil }
}
private struct InventoryReadTransport: AnkrTransport {
    let owner: String
    let gate: InventoryReadGate
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = try XCTUnwrap(request.url)
        let body = try request.httpBody.map { try JSONSerialization.jsonObject(with: $0) }
        let result: Any
        if let calls = body as? [[String: Any]] {
            guard calls.count == 1, calls[0]["method"] as? String == "eth_chainId" else { throw TronError.malformed }
            result = [["jsonrpc":"2.0", "id":try XCTUnwrap(calls[0]["id"]), "result":"0x2b6653dc"]]
        } else if url.path.hasSuffix("/getaccount") {
            // The node read has already selected this old balance before it waits.
            let snapshot: [String: Any] = ["address":owner, "balance":1000]
            await gate.hold(); result = snapshot
        } else if let call = body as? [String: Any], let method = call["method"] as? String {
            let value: [String: Any]
            switch method {
            case "getMasterchainInfo": value = ["init":["root_hash":TonIdentity.genesis]]
            case "getAddressInformation":
                let snapshot: [String: Any] = ["state":"active", "balance":"1000"]
                await gate.hold(); value = snapshot
            default: throw TonError.malformed
            }
            result = ["jsonrpc":"2.0", "id":try XCTUnwrap(call["id"]), "result":value]
        } else if url.host == "api.trongrid.io" { result = ["success":true, "data":[]] }
        else if url.host == "tonapi.io", url.path.hasSuffix("/jettons") { result = ["balances":[]] }
        else { throw URLError(.unsupportedURL) }
        return (try JSONSerialization.data(withJSONObject: result), 200)
    }
}

@MainActor final class InventoryFlightTimeTests: XCTestCase {
    private let tronOwner = "TJmmqjb1DK9TTZbQXzRQ2AuA94z4gKAPFh"
    private let tonOwner = "0:23fa979918f1fe702db9100bf843e87c7015eccd39a4721e9b6bac170bc04ce3"
    private let transactionHash = String(repeating:"a", count:64)
    private func fixture(_ chain: String) async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InventoryFlight-"+UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let decimals = chain == "tron" ? 6 : 9
        try await db.seed(networks:[.init(id:chain,name:chain,family:"account",symbol:"TEST",decimals:decimals,derivationPath:"fixture",logo:"",sortOrder:0)],assets:[.init(id:chain+":native",networkID:chain,reference:"native",name:"Fixture",symbol:"TEST",decimals:decimals)])
        try await db.importWalletIfNeeded(.init(id:"w",name:"Fixture",kind:"hd",vaultReference:"synthetic",createdAt:1),accounts:[.init(id:"a",walletID:"w",networkID:chain,address:chain == "tron" ? tronOwner : tonOwner,derivationPath:"fixture")])
        try await db.saveDraft(.init(id:"s",walletID:"w",accountID:"a",networkID:chain,assetID:chain+":native",idempotencyKey:"s",recipient:"fixture",amountAtomic:"100",state:"draft",createdAt:1,updatedAt:1))
        return (db,folder)
    }
    // Fixture finality is installed directly, so this matrix does not claim to test signing.
    private func finalized(_ db: OathDatabase, chain: String, localTime: Double, chainTime: Double? = nil) async throws -> SendRecord {
        let hashValue = transactionHash
        let id = chain+":"+hashValue
        try await db.pool.write { sql in
            try TransactionRecord(id:id,networkID:chain,hash:hashValue,state:"confirmed",blockHeight:100,timestamp:chainTime ?? localTime,feeAtomic:"1",updatedAt:localTime).upsert(sql)
            try sql.execute(sql:"UPDATE sends SET state='confirmed',transactionID=?,updatedAt=? WHERE id='s'",arguments:[id,localTime])
            if chain == "tron" {
                try sql.execute(sql:"INSERT OR REPLACE INTO tronTransactions(accountID,hash,detail) VALUES('a',?,?)",arguments:[hashValue,Data("{}".utf8)])
            }
        }
        let stored = try await db.send("s")
        return try XCTUnwrap(stored)
    }
    private func tron(held: Bool) async throws {
        let (db,folder) = try await fixture("tron"); defer { try? FileManager.default.removeItem(at:folder) }
        let gate = InventoryReadGate(), ticket = try await db.beginTronSync(accountID:"a")
        let client = try TronClient(apiKey:"FixtureKey",transport:InventoryReadTransport(owner:tronOwner,gate:gate))
        let send: SendRecord
        let inventory: TronInventory
        if held {
            let read = Task { try await client.inventory(owner:tronOwner) }
            await gate.waitUntilRead()
            send = try await finalized(db,chain:"tron",localTime:Date.now.timeIntervalSince1970)
            await gate.release(); inventory = try await read.value
        } else {
            send = try await finalized(db,chain:"tron",localTime:Date.now.timeIntervalSince1970)
            await gate.release(); inventory = try await client.inventory(owner:tronOwner)
        }
        XCTAssertEqual(inventory.holdings.first?.amount,"1000")
        XCTAssertTrue(inventory.discoveryComplete); XCTAssertTrue(inventory.failedReferences.isEmpty)
        try await db.commitTronInventory(inventory,ticket:ticket,catalog:[:])
        let current = try await db.tronSendBalanceIsCurrent(send)
        XCTAssertEqual(current,!held,"Completing a read after finality cannot make its earlier snapshot current")
    }
    private func ton(held: Bool) async throws {
        let (db,folder) = try await fixture("ton"); defer { try? FileManager.default.removeItem(at:folder) }
        let gate = InventoryReadGate(), ticket = try await db.beginTonSync(accountID:"a")
        let client = TonClient(testTransport:InventoryReadTransport(owner:tonOwner,gate:gate))
        let send: SendRecord
        let inventory: TonInventory
        if held {
            let read = Task { try await client.inventory(owner:tonOwner) }
            await gate.waitUntilRead()
            send = try await finalized(db,chain:"ton",localTime:Date.now.timeIntervalSince1970)
            await gate.release(); inventory = try await read.value
        } else {
            send = try await finalized(db,chain:"ton",localTime:Date.now.timeIntervalSince1970)
            await gate.release(); inventory = try await client.inventory(owner:tonOwner)
        }
        XCTAssertEqual(inventory.holdings.first?.amount,"1000")
        XCTAssertNil(inventory.incompleteError)
        try await db.commitTonInventory(inventory,ticket:ticket)
        let current = try await db.tonSendBalanceIsCurrent(send)
        XCTAssertEqual(current,!held,"Completing a read after finality cannot make its earlier snapshot current")
    }
    func testTronPreFinalityReadCompletingLateIsNotCurrent() async throws { try await tron(held:true) }
    func testTronNewReadAfterFinalityCanBeCurrent() async throws { try await tron(held:false) }
    func testTonPreFinalityReadCompletingLateIsNotCurrent() async throws { try await ton(held:true) }
    func testTonNewReadAfterFinalityCanBeCurrent() async throws { try await ton(held:false) }
    func testTronRequiresLocalFinalityEvenWithOlderBlockTimestamp() async throws {
        let (db,folder) = try await fixture("tron"); defer { try? FileManager.default.removeItem(at:folder) }
        let ticket = try await db.beginTronSync(accountID:"a")
        let send = try await finalized(db,chain:"tron",localTime:150,chainTime:50)
        try await db.commitTronInventory(.init(owner:tronOwner,holdings:[.init(token:.init(reference:"native",name:"TRON",symbol:"TRX",decimals:6),amount:"1000")],failedReferences:[],excludedNFTs:[],discoveryComplete:true,observedAt:Date(timeIntervalSince1970:100),raw:Data()),ticket:ticket,catalog:[:])
        let current = try await db.tronSendBalanceIsCurrent(send)
        XCTAssertFalse(current,"A block timestamp cannot substitute for the newer local finality observation")
    }
}
