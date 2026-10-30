import Foundation
import XCTest
import GRDB
import OathAnkr
@testable import OathDatabase

@MainActor final class EVMBridgeHistoryTests: XCTestCase {
    let owner = "0x20a1aafc179199ddbc8eaf73f5aec5a8adce6967"
    func evidence(_ name: String) throws -> EVMHistoryEvidence {
        let packages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(EVMHistoryEvidence.self, from: Data(contentsOf: packages.appendingPathComponent("OathAnkr/Tests/OathAnkrTests/Fixtures/HistoryBridges/\(name).json")))
    }
    func fixture(relay: Bool = false) async throws -> (OathDatabase, URL, [String:EVMHistoryEvidence]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let destination = relay ? "robinhood" : "optimism"
        let token = relay ? "usde" : "usdc"
        let amount = relay ? "98864689267516090857" : "99009481"
        let evidence = ["bnb":try evidence(relay ? "bsc" : "optimism-source"),destination:try evidence(relay ? "robinhood_mainnet" : "optimism")]
        try await db.seed(networks: [
            .init(id:"bnb",name:"BNB Smart Chain",family:"evm",symbol:"BNB",decimals:18,derivationPath:"",logo:"",sortOrder:0),
            .init(id:destination,name:relay ? "Robinhood" : "Optimism",family:"evm",symbol:"ETH",decimals:18,derivationPath:"",logo:"",sortOrder:1)],assets:[
                .init(id:"usdt",networkID:"bnb",reference:"0x55d398326f99059ff775485246999027b3197955",name:"Tether",symbol:"USDT",decimals:18),
                .init(id:token,networkID:destination,reference:relay ? "0x5d3a1ff2b6bab83b63cd9ad0787074081a52ef34" : "0x0b2c639c533813f4aa9d7837caf62653d097ff85",name:relay ? "USDe" : "USD Coin",symbol:relay ? "USDe" : "USDC",decimals:relay ? 18 : 6),
                .init(id:"bnb",networkID:"bnb",reference:"native",name:"BNB",symbol:"BNB",decimals:18)])
        try await db.importWalletIfNeeded(.init(id:"w",name:"Fixture",kind:"hd",vaultReference:"fixture",createdAt:1),accounts:[
            .init(id:"bnb",walletID:"w",networkID:"bnb",address:owner,derivationPath:""),
            .init(id:destination,walletID:"w",networkID:destination,address:owner,derivationPath:"")])
        try await db.pool.write { database in
            for (chain,e) in evidence {
                try TransactionRecord(id:chain,networkID:chain,hash:e.transaction["hash"].string!,state:"confirmed",blockHeight:Int64(try AnkrQuantity.decimal(e.receipt["blockNumber"].string!)),blockHash:e.receipt["blockHash"].string,timestamp:chain == "bnb" ? 100:200,updatedAt:200).insert(database)
                try ActivityRecord(id:chain,walletID:"w",accountID:chain,networkID:chain,transactionID:chain,assetID:chain == "bnb" ? "usdt":token,direction:chain == "bnb" ? "outgoing":"incoming",amountAtomic:chain == "bnb" ? "100000000000000000000":amount,counterparty:"router",timestamp:chain == "bnb" ? 100:200).insert(database)
            }
            try ActivityRecord(id:"zero",walletID:"w",accountID:"bnb",networkID:"bnb",transactionID:"bnb",assetID:"bnb",direction:"outgoing",amountAtomic:"0",counterparty:"router",timestamp:100).insert(database)
        }
        return (db,folder,evidence)
    }
    func testBridgesSurviveOfflineReopenAndSparseIndexReplay() async throws {
        for relay in [false,true] {
            let (db,folder,evidence) = try await fixture(relay:relay)
            defer { try? FileManager.default.removeItem(at:folder) }
            for candidate in try await db.swapHistoryCandidates(walletID:"w") {
                try await db.saveSwapHistoryEvidence(XCTUnwrap(evidence[candidate.networkID]),candidate:candidate)
            }
            let before = try await db.chainHistory(walletID:"w",currency:"USD")
            XCTAssertEqual(before.map(\.entry.direction),["bridge"])
            try db.pool.close()
            let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
            for chain in evidence.keys.sorted() {
                var sparse = try await reopened.pool.read { try XCTUnwrap(TransactionRecord.fetchOne($0,key:chain)) }
                sparse.blockHash = nil; sparse.updatedAt += 1
                var batch = SyncBatch(cursor:.init(accountID:chain,stream:"reopen",cursor:"one",updatedAt:201),expectedCursor:nil)
                batch.transactions = [sparse]
                _ = try await reopened.apply(batch)
                let replayed = try await reopened.chainHistory(walletID:"w",currency:"USD")
                XCTAssertEqual(replayed.map(\.id),before.map(\.id))
            }
            try reopened.pool.close()
            let offline = try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
            let restored = try await offline.chainHistory(walletID:"w",currency:"USD")
            XCTAssertEqual(restored.map(\.id),before.map(\.id))
            XCTAssertEqual(restored.first?.receivedAtomic,before.first?.receivedAtomic)
            try offline.pool.close()
        }
    }
    func testVersionTwoSchemaUpgradesProjectionViewsInPlace() throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in db.add(function: HistorySafety.metadataFunction) }
        let queue = try DatabaseQueue(configuration: configuration)
        try Schema.migrator.migrate(queue, upTo: "v74_evm_bridge_history")
        try queue.read { db in
            for name in ["validHistorySwaps", "validHistoryBridges"] {
                let sql = try XCTUnwrap(String.fetchOne(db,sql:"SELECT sql FROM sqlite_master WHERE name=?",arguments:[name]))
                XCTAssertTrue(sql.contains("c.version=2"))
            }
        }
        try Schema.migrator.migrate(queue)
        try queue.read { db in
            for name in ["validHistorySwaps", "validHistoryBridges"] {
                let sql = try XCTUnwrap(String.fetchOne(db,sql:"SELECT sql FROM sqlite_master WHERE name=?",arguments:[name]))
                XCTAssertTrue(sql.contains("c.version IN (4,5,6)"))
            }
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM projectedHistoryActivity"),0)
        }
    }
    func testRealRelayPairAndVersionTwoCachedUpgrade() async throws {
        for order in [["bnb","robinhood"],["robinhood","bnb"]] {
            let (db,folder,e) = try await fixture(relay:true)
            defer { try? FileManager.default.removeItem(at:folder) }
            let candidates = try await db.swapHistoryCandidates(walletID:"w")
            for chain in order {
                try await db.saveSwapHistoryEvidence(XCTUnwrap(e[chain]),candidate:XCTUnwrap(candidates.first { $0.networkID == chain }))
            }
            // Simulate the previous app's cached, unmatched internal execution ID.
            try await db.pool.write {
                try $0.execute(sql:"UPDATE evmHistorySwaps SET version=2")
                try $0.execute(sql:"UPDATE evmHistorySwaps SET bridgeKey='old-nested-id' WHERE accountID='robinhood'")
            }
            for candidate in try await db.swapHistoryCandidates(walletID:"w") {
                let cached = try JSONDecoder().decode(EVMHistoryEvidence.self,from:XCTUnwrap(candidate.cachedEvidence))
                try await db.saveSwapHistoryEvidence(cached,candidate:candidate)
            }
            let rows = try await db.chainHistory(walletID:"w",currency:"USD")
            XCTAssertEqual(rows.count,1)
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row.entry.direction,"bridge")
            XCTAssertEqual(row.outputHolding?.networkID,"robinhood")
            XCTAssertEqual(row.outputHolding?.symbol,"USDe")
            XCTAssertEqual(row.receivedAtomic,"98864689267516090857")
            for query in ["USDT","USDe","Robinhood"] {
                let found = try await db.chainHistory(walletID:"w",currency:"USD",search:query)
                XCTAssertEqual(found.map(\.id),rows.map(\.id))
            }
        }
    }
    func testBothArrivalOrdersOneRowAndEveryScopeFindsBothLegs() async throws {
        for order in [["bnb","optimism"],["optimism","bnb"]] {
            let (db,folder,e) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
            let candidates = try await db.swapHistoryCandidates(walletID:"w")
            XCTAssertEqual(candidates.count,2)
            for chain in order {
                try await db.saveSwapHistoryEvidence(XCTUnwrap(e[chain]),candidate:XCTUnwrap(candidates.first { $0.networkID == chain }))
                if chain == order[0] {
                    let partial = try await db.chainHistory(walletID:"w",currency:"USD")
                    let leg = try XCTUnwrap(partial.first { $0.entry.direction.hasPrefix("bridge") })
                    XCTAssertEqual(leg.entry.displayDirection,chain == "bnb" ? "outgoing":"incoming")
                    XCTAssertNil(leg.outputHolding)
                    XCTAssertEqual(leg.bridgeProtocol,"Across")
                }
            }
            let rows = try await db.chainHistory(walletID:"w",currency:"USD",limit:1)
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row.entry.direction,"bridge")
            XCTAssertEqual(row.entry.amountAtomic,"100000000000000000000")
            XCTAssertEqual(row.receivedAtomic,"99009481")
            XCTAssertEqual(row.holding.networkID,"bnb")
            XCTAssertEqual(row.outputHolding?.networkID,"optimism")
            XCTAssertEqual(row.outputHolding?.accountID,"optimism")
            for (chain,asset) in [("bnb","usdt"),("optimism","usdc")] {
                let scoped = try await db.chainHistory(walletID:"w",networkID:chain,accountID:chain,assetID:asset,currency:"USD")
                XCTAssertEqual(scoped.map(\.id),rows.map(\.id))
                var filter = HistoryFilter();filter.networkIDs=[chain];filter.assetIDs=[asset];filter.directions=[.swap]
                let filtered = try await db.chainHistory(walletID:"w",currency:"USD",filter:filter)
                XCTAssertEqual(filtered.map(\.id),rows.map(\.id))
                let detail = try await db.transactionDetails(accountID:chain,transactionID:chain)
                XCTAssertEqual(detail?.swap?.id,row.id)
                XCTAssertEqual(detail?.transaction.networkID,chain)
            }
            for query in ["USDT","USDC","Optimism","Bridge","Across"] {
                let found = try await db.chainHistory(walletID:"w",currency:"USD",search:query)
                XCTAssertEqual(found.map(\.id),rows.map(\.id))
            }
            let page = try await db.chainHistory(walletID:"w",currency:"USD",before:.init(timestamp:row.entry.timestamp,id:row.id),limit:1)
            XCTAssertTrue(page.isEmpty)
            let raw = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM activity") }
            XCTAssertEqual(raw,3)
        }
    }
    func testUpgradeReorgAndChangedOwnerNeverKeepIncorrectPair() async throws {
        let (db,folder,e) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        for candidate in try await db.swapHistoryCandidates(walletID:"w") {
            try await db.saveSwapHistoryEvidence(XCTUnwrap(e[candidate.networkID]),candidate:candidate)
        }
        try await db.pool.write { try $0.execute(sql:"UPDATE evmHistorySwaps SET version=1") }
        for candidate in try await db.swapHistoryCandidates(walletID:"w") {
            let cached = try JSONDecoder().decode(EVMHistoryEvidence.self,from:XCTUnwrap(candidate.cachedEvidence))
            try await db.saveSwapHistoryEvidence(cached,candidate:candidate)
        }
        let paired = try await db.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(paired.count,1)
        try await db.pool.write { try $0.execute(sql:"UPDATE transactions SET state='pending' WHERE id='optimism'") }
        let pending = try await db.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(Set(pending.map(\.entry.direction)),["bridgeOutgoing","incoming"])
        try await db.pool.write { try $0.execute(sql:"UPDATE transactions SET state='confirmed',blockHash='reorg' WHERE id='optimism'") }
        let reorg = try await db.chainHistory(walletID:"w",currency:"USD")
        XCTAssertFalse(reorg.contains { $0.entry.direction == "bridge" })
        try await db.pool.write { try $0.execute(sql:"UPDATE accounts SET syncGeneration=syncGeneration+1 WHERE id='bnb'") }
        let stale = try await db.chainHistory(walletID:"w",currency:"USD")
        XCTAssertFalse(stale.contains { $0.entry.direction.hasPrefix("bridge") })
    }
    func testLaterIndexedLegPairsFromCacheAndUnrelatedMovementIsPreserved() async throws {
        let (db,folder,e) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        for candidate in try await db.swapHistoryCandidates(walletID:"w") {
            try await db.saveSwapHistoryEvidence(XCTUnwrap(e[candidate.networkID]),candidate:candidate)
        }
        try await db.pool.write { try $0.execute(sql:"DELETE FROM activity WHERE id='optimism'") }
        let source = try await db.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(source.map(\.entry.direction),["bridgeOutgoing"])
        try await db.pool.write { db in
            try ActivityRecord(id:"optimism",walletID:"w",accountID:"optimism",networkID:"optimism",transactionID:"optimism",assetID:"usdc",direction:"incoming",amountAtomic:"99009481",counterparty:"router",timestamp:200).insert(db)
        }
        let paired = try await db.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(paired.map(\.id),source.map(\.id))
        XCTAssertEqual(paired.first?.entry.direction,"bridge")
        // A native payment not accounted for by the receipt decoder must never
        // disappear behind the token bridge projection.
        try await db.pool.write { try $0.execute(sql:"UPDATE activity SET amountAtomic='1' WHERE id='zero'") }
        let fallback = try await db.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(fallback.count,3)
        XCTAssertEqual(fallback.filter { $0.entry.direction == "bridgeIncoming" }.count,1)
        XCTAssertEqual(fallback.filter { $0.entry.direction == "outgoing" }.count,2)
    }

}
