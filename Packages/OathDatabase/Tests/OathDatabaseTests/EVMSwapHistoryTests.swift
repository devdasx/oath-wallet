import Foundation
import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class EVMSwapHistoryTests: XCTestCase {
    private func evidence(_ name: String = "bnb-usdt-usdc") throws -> EVMHistoryEvidence {
        // Shared public regression fixture; never use a user's wallet database.
        let packages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(EVMHistoryEvidence.self, from: Data(contentsOf: packages.appendingPathComponent("OathAnkr/Tests/OathAnkrTests/Fixtures/HistorySwaps/\(name).json")))
    }
    private func fixture(evidenceName: String = "bnb-usdt-usdc", outputReference: String = "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d", outputSymbol: String = "USDC") async throws -> (OathDatabase, URL, EVMHistoryEvidence) {
        let e = try evidence(evidenceName), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await db.seed(networks: [.init(id:"bnb",name:"BNB",family:"evm",symbol:"BNB",decimals:18,derivationPath:"",logo:"",sortOrder:0)], assets: [
            .init(id:"in",networkID:"bnb",reference:"0x55d398326f99059ff775485246999027b3197955",name:"Tether",symbol:"USDT",decimals:18),
            .init(id:"out",networkID:"bnb",reference:outputReference,name:outputSymbol == "DAI" ? "Dai" : "USD Coin",symbol:outputSymbol,decimals:18),
            .init(id:"native",networkID:"bnb",reference:"native",name:"BNB",symbol:"BNB",decimals:18)])
        try await db.importWalletIfNeeded(.init(id:"w",name:"Fixture",kind:"hd",vaultReference:"fixture",createdAt:1),accounts:[
            .init(id:"a",walletID:"w",networkID:"bnb",address:e.transaction["from"].string!,derivationPath:"")])
        try await db.pool.write { db in
            try TransactionRecord(id:"tx",networkID:"bnb",hash:e.transaction["hash"].string!,state:"confirmed",blockHeight:Int64(try AnkrQuantity.decimal(e.receipt["blockNumber"].string!)),blockHash:e.receipt["blockHash"].string,timestamp:100,updatedAt:100).insert(db)
        }
        return (db,folder,e)
    }
    private func add(_ db: OathDatabase, _ asset: String) async throws {
        try await db.pool.write { db in
            try ActivityRecord(id:asset,walletID:"w",accountID:"a",networkID:"bnb",transactionID:"tx",assetID:asset,
                direction:asset == "out" ? "incoming":"outgoing",amountAtomic:asset == "native" ? "0":"100000000000000000000",counterparty:"router",timestamp:100).insert(db)
        }
    }
    private func project(_ db: OathDatabase, _ e: EVMHistoryEvidence) async throws {
        let list = try await db.swapHistoryCandidates(walletID:"w")
        try await db.saveSwapHistoryEvidence(e,candidate:XCTUnwrap(list.first))
    }
    func testZeroDestinationHistoryPersistsWithoutRepeatedEnrichmentFailure() async throws {
        let (db, folder, original) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await add(db, "native")
        func replacing(_ json: SolanaJSON, _ key: String, _ value: SolanaJSON) -> SolanaJSON {
            guard case .object(var fields) = json else { return json }
            fields[key] = value; return .object(fields)
        }
        var tx = replacing(original.transaction, "to", .string(EVMPermissionRemoval.zero))
        tx = replacing(tx, "value", .string("0x0"))
        tx = replacing(tx, "input", .string("0x"))
        let receipt = replacing(replacing(original.receipt, "to", .string(EVMPermissionRemoval.zero)), "logs", .array([]))
        try await project(db, .init(transaction: tx, receipt: receipt))
        let next = try await db.swapHistoryCandidates(walletID: "w")
        XCTAssertTrue(next.isEmpty, "Successful negative classification must stop the immediate retry loop")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let rows = try await reopened.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.entry.direction, "outgoing", "Retain the original transaction")
        let remaining = try await reopened.swapHistoryCandidates(walletID: "w")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testReportedV3SwapReclassifiesCachedNegativeAndSurvivesReopen() async throws {
        let (db, folder, evidence) = try await fixture(evidenceName: "bnb-usdt-dai-v3-exact-in",
            outputReference: "0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3", outputSymbol: "DAI")
        defer { try? FileManager.default.removeItem(at: folder) }
        for asset in ["in", "out", "native"] { try await add(db, asset) }
        let raw = try JSONEncoder().encode(evidence)
        // Reproduce the old decoder's cached rejection in an installed database.
        try await db.pool.write { sql in
            try sql.execute(sql: """
                INSERT INTO evmHistorySwaps(accountID,transactionID,version,generation,blockHash,evidence,checkedAt)
                SELECT 'a','tx',4,syncGeneration,?,?,? FROM accounts WHERE id='a'
                """, arguments: [evidence.receipt["blockHash"].string, raw, Date().timeIntervalSince1970])
            for name in ["validHistorySwaps", "validHistoryBridges"] {
                let source = try XCTUnwrap(String.fetchOne(sql, sql: "SELECT sql FROM sqlite_master WHERE name=?", arguments: [name]))
                try sql.execute(sql: "DROP VIEW \(name)")
                try sql.execute(sql: source.replacingOccurrences(of: "c.version IN (4,5,6)", with: "c.version=4"))
            }
            try sql.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v79_universal_router_history','v80_native_history_execution')")
        }
        try db.pool.close()
        let upgraded = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let candidates = try await upgraded.swapHistoryCandidates(walletID: "w")
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.cachedEvidence, raw, "Reclassify immediately without refetching the public receipt")
        try await upgraded.saveSwapHistoryEvidence(JSONDecoder().decode(EVMHistoryEvidence.self, from: XCTUnwrap(candidate.cachedEvidence)), candidate: candidate)
        let rows = try await upgraded.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.entry.direction, "swap")
        XCTAssertEqual(row.entry.amountAtomic, "50000000000000000000")
        XCTAssertEqual(row.receivedAtomic, "49951794824533164250")
        XCTAssertEqual(row.outputHolding?.symbol, "DAI")
        for asset in ["in", "out"] {
            let filtered = try await upgraded.chainHistory(walletID: "w", assetID: asset, currency: "USD", limit: 1)
            XCTAssertEqual(filtered.map(\.id), rows.map(\.id))
        }
        let details = try await upgraded.transactionDetails(accountID: "a", transactionID: "tx")
        XCTAssertEqual(details?.swap?.id, row.id)
        let transfers = try await upgraded.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activity") }
        XCTAssertEqual(transfers, 3, "Keep original evidence while projecting one row")
        try upgraded.pool.close()
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let restored = try await reopened.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(restored.map(\.id), rows.map(\.id))
        XCTAssertEqual(restored.first?.receivedAtomic, row.receivedAtomic)
        try reopened.pool.close()
    }

    func testPreviouslyRecognizedSwapsRemainGroupedDuringVersionUpgrade() async throws {
        let (db, folder, evidence) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await add(db, "in"); try await add(db, "out")
        try await project(db, evidence)
        try await db.pool.write { try $0.execute(sql: "UPDATE evmHistorySwaps SET version=4") }
        let rows = try await db.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(rows.map(\.entry.direction), ["swap"])
        let pending = try await db.swapHistoryCandidates(walletID: "w")
        XCTAssertNotNil(pending.first?.cachedEvidence)
    }

    func testLargeAcceptedRPCPairPersistsWithoutRepeatedEnrichment() async throws {
        let (db,folder,e) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await add(db,"in"); try await add(db,"out")
        func extended(_ value: SolanaJSON) throws -> SolanaJSON {
            guard case .object(var object) = value else { throw SolanaError.malformed }
            // Exercise both replies near the client's existing 8 MiB ceiling.
            object["providerExtension"] = .string(String(repeating:"x",count:EVMSendClient.maximumRPCResponseBytes - 65_536))
            return .object(object)
        }
        let large = try EVMHistoryEvidence(transaction:extended(e.transaction),receipt:extended(e.receipt))
        let client = try EVMSendClient(network:.bnb,endpoints:[URL(string:"https://example.invalid")!],
                                      transport:LargeHistoryEvidenceTransport(evidence:large))
        let accepted = try await client.historyEvidence(hash:XCTUnwrap(e.transaction["hash"].string))
        XCTAssertGreaterThan(try JSONEncoder().encode(accepted).count,2_000_000)
        try await project(db,accepted)
        let candidates = try await db.swapHistoryCandidates(walletID:"w")
        XCTAssertTrue(candidates.isEmpty,"A saved result must leave the immediate retry queue")
        let history = try await db.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(history.map(\.entry.direction),["swap"])
        XCTAssertEqual(history.first?.entry.amountAtomic,"100121422443709744075")
        XCTAssertEqual(history.first?.receivedAtomic,"100000000000000000000")
        try db.pool.close()
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        try await reopened.pool.write { try $0.execute(sql:"UPDATE evmHistorySwaps SET version=0") }
        let upgrades = try await reopened.swapHistoryCandidates(walletID:"w")
        let candidate = try XCTUnwrap(upgrades.first)
        let restored = try JSONDecoder().decode(EVMHistoryEvidence.self,from:XCTUnwrap(candidate.cachedEvidence))
        XCTAssertEqual(restored.transaction,large.transaction)
        XCTAssertEqual(restored.receipt,large.receipt)
        try await reopened.saveSwapHistoryEvidence(restored,candidate:candidate)
        try await reopened.pool.write { try $0.execute(sql:"UPDATE transactions SET blockHash='changed'") }
        let reorganized = try await reopened.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(reorganized.count,2)
        XCTAssertFalse(reorganized.contains { $0.entry.direction == "swap" })
    }

    func testEvidenceBeyondCombinedRPCBudgetIsRejectedWithoutChangingHistory() async throws {
        let (db,folder,e) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await add(db,"in"); try await add(db,"out")
        guard case .object(var receipt) = e.receipt else { return XCTFail("Fixture receipt") }
        receipt["providerExtension"] = .string(String(repeating:"x",count:EVMHistoryEvidence.maximumEncodedBytes))
        do {
            try await project(db,.init(transaction:e.transaction,receipt:.object(receipt)))
            XCTFail("Unbounded evidence must not be persisted")
        } catch let error as StoreError {
            XCTAssertEqual(error,.invalidValue("swap evidence size"))
        }
        let history = try await db.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(history.count,2)
        XCTAssertFalse(history.contains { $0.entry.direction == "swap" })
        let saved = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM evmHistorySwaps") }
        XCTAssertEqual(saved,0)
    }
    func testSparseAnkrPageRetainsPersistedSwapAcrossReopen() async throws {
        let (db,folder,e) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        // ANKR uses the canonical chain/hash identity.
        let id = "bnb:" + e.transaction["hash"].string!.lowercased()
        try await db.pool.write { database in
            try database.execute(sql:"UPDATE transactions SET id=? WHERE id='tx'",arguments:[id])
            for asset in ["in","out"] {
                try ActivityRecord(id:asset,walletID:"w",accountID:"a",networkID:"bnb",transactionID:id,assetID:asset,
                    direction:asset == "out" ? "incoming":"outgoing",amountAtomic:"100000000000000000000",counterparty:"router",timestamp:100).insert(database)
            }
        }
        try await project(db,e)
        try db.pool.close()
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let restored = try await reopened.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(restored.map(\.entry.direction),["swap"])
        let raw = try JSONSerialization.data(withJSONObject:["transactions":[[
            "blockchain":"bsc","hash":e.transaction["hash"].string!,"from":e.transaction["from"].string!,
            "to":e.transaction["to"].string!,"input":e.transaction["input"].string!,"value":"0x0",
            "blockNumber":e.receipt["blockNumber"].string!,"timestamp":"100","status":"0x1"
        ]]])
        let page = try JSONDecoder().decode(AnkrTransactionResult.self,from:raw)
        let ticket = try await reopened.beginAnkrSync(accountID:"a",stream:"transactions")
        try await reopened.commitAnkrTransactions(.init(value:page,raw:raw,fetchedAt:.now),ticket:ticket,cursor:nil)
        let replayed = try await reopened.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(replayed.map(\.entry.direction),["swap"])
        XCTAssertEqual(replayed.map(\.id),restored.map(\.id))
        try reopened.pool.close()
        let second = try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let offline = try await second.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(offline.map(\.id),restored.map(\.id))
    }
    func testUpgradeRepairsMissingReceiptReferenceOfflineButRejectsChangedEvidence() async throws {
        for change in ["none", "height", "generation", "state", "hash", "corrupt"] {
            let (db,folder,e) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
            try await add(db,"in"); try await add(db,"out"); try await project(db,e)
            try await db.pool.write { database in
                try database.execute(sql:"UPDATE transactions SET blockHash=NULL")
                switch change {
                case "height": try database.execute(sql:"UPDATE transactions SET blockHeight=blockHeight+1")
                case "generation": try database.execute(sql:"UPDATE accounts SET syncGeneration=syncGeneration+1")
                case "state": try database.execute(sql:"UPDATE transactions SET state='failed'")
                case "hash": try database.execute(sql:"UPDATE transactions SET hash='changed'")
                case "corrupt": try database.execute(sql:"UPDATE evmHistorySwaps SET evidence=?",arguments:[Data("invalid".utf8)])
                default: break
                }
                // Reproduce an installed v76 database, then run the real migration at open.
                try database.execute(sql:"DELETE FROM grdb_migrations WHERE identifier='v77_preserve_evm_history_receipts'")
            }
            try db.pool.close()
            let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
            let history = try await reopened.chainHistory(walletID:"w",currency:"USD")
            XCTAssertEqual(history.contains { $0.entry.direction == "swap" }, change == "none",change)
            try reopened.pool.close()
        }
    }

    func testGroupsBeforeFilteringAndPaginationWithBothAssetsAndDetails() async throws {
        let (db,folder,e) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        for asset in ["native","out","in"] { try await add(db,asset) }
        try await project(db,e)
        let rows = try await db.chainHistory(walletID:"w",currency:"USD",limit:1)
        XCTAssertEqual(rows.count,1); let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.entry.direction,"swap"); XCTAssertEqual(row.outputHolding?.symbol,"USDC")
        XCTAssertEqual(row.entry.amountAtomic,"100121422443709744075")
        XCTAssertEqual(row.receivedAtomic,"100000000000000000000")
        for asset in ["in","out"] {
            let scoped = try await db.chainHistory(walletID:"w",assetID:asset,currency:"USD")
            XCTAssertEqual(scoped.map(\.id),rows.map(\.id))
            var filter = HistoryFilter(); filter.assetIDs=[asset]; filter.directions=[.swap]
            let filtered = try await db.chainHistory(walletID:"w",currency:"USD",filter:filter)
            XCTAssertEqual(filtered.map(\.id),rows.map(\.id))
        }
        for term in ["USDT","USDC","USD Coin","swap"] {
            let found = try await db.chainHistory(walletID:"w",currency:"USD",search:term)
            XCTAssertEqual(found.map(\.id),rows.map(\.id))
        }
        for amount in ["100", "100.121422443709744075"] {
            var filter = HistoryFilter(); filter.minimumAmount=amount; filter.maximumAmount=amount
            let found = try await db.chainHistory(walletID:"w",currency:"USD",filter:filter)
            XCTAssertEqual(found.map(\.id),rows.map(\.id))
        }
        let otherWallet = try await db.chainHistory(walletID:"other",currency:"USD")
        XCTAssertTrue(otherWallet.isEmpty)
        let next = try await db.chainHistory(walletID:"w",currency:"USD",before:.init(timestamp:row.entry.timestamp,id:row.id),limit:1)
        XCTAssertTrue(next.isEmpty)
        let details = try await db.transactionDetails(accountID:"a",transactionID:"tx")
        XCTAssertEqual(details?.swap?.id,row.id)
        let rawCount = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM activity") }
        XCTAssertEqual(rawCount,3)
    }
    func testPartialPagesCacheUpgradeAndStatusChanges() async throws {
        for order in [["in","out"],["out","in"]] {
            let (db,folder,e) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
            try await add(db,order[0]); let partial = try await db.swapHistoryCandidates(walletID:"w"); XCTAssertEqual(partial.count,1)
            try await add(db,order[1]); try await project(db,e)
            let initial = try await db.chainHistory(walletID:"w",currency:"USD")
            try await db.pool.write { try $0.execute(sql:"UPDATE evmHistorySwaps SET version=0") }
            let upgrades = try await db.swapHistoryCandidates(walletID:"w")
            XCTAssertNotNil(upgrades.first?.cachedEvidence)
            let cached = try JSONDecoder().decode(EVMHistoryEvidence.self,from:XCTUnwrap(upgrades.first?.cachedEvidence))
            try await db.saveSwapHistoryEvidence(cached,candidate:XCTUnwrap(upgrades.first))
            let upgraded = try await db.chainHistory(walletID:"w",currency:"USD")
            XCTAssertEqual(upgraded.map(\.id),initial.map(\.id))
            for state in ["failed","pending"] {
                try await db.pool.write { try $0.execute(sql:"UPDATE transactions SET state=?",arguments:[state]) }
                let fallback = try await db.chainHistory(walletID:"w",currency:"USD")
                XCTAssertEqual(fallback.count,2); XCTAssertFalse(fallback.contains { $0.entry.direction == "swap" })
            }
            try await db.pool.write { try $0.execute(sql:"UPDATE transactions SET state='confirmed',blockHash='changed'") }
            let reorganized = try await db.chainHistory(walletID:"w",currency:"USD")
            XCTAssertEqual(reorganized.count,2)
        }
    }
    func testZeroNativeContractCallIsClassifiedAndInvalidatedAfterReorg() async throws {
        let (db,folder,e) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await add(db,"native")
        func replacing(_ json: SolanaJSON, _ key: String, _ value: SolanaJSON) -> SolanaJSON {
            guard case .object(var object) = json else { return json }
            object[key] = value; return .object(object)
        }
        let token = "0x55d398326f99059ff775485246999027b3197955"
        let input = "0x095ea7b3" + String(repeating:"0",count:24) + String(repeating:"3",count:40) + String(repeating:"f",count:64)
        let tx = replacing(replacing(e.transaction,"to",.string(token)),"input",.string(input))
        let receipt = replacing(replacing(e.receipt,"to",.string(token)),"logs",.array([]))
        let changed = EVMHistoryEvidence(transaction:tx,receipt:receipt)
        try await project(db,changed)
        let rows = try await db.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(rows.count,1)
        XCTAssertEqual(rows.first?.entry.contractKind,"approval")
        XCTAssertEqual(rows.first?.entry.amountAtomic,"0")
        try db.pool.close()
        let reopened = try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        var sparse = try await reopened.pool.read { try XCTUnwrap(TransactionRecord.fetchOne($0,key:"tx")) }
        sparse.blockHash = nil; sparse.updatedAt += 1
        var batch = SyncBatch(cursor:.init(accountID:"a",stream:"reopen",cursor:"one",updatedAt:101),expectedCursor:nil)
        batch.transactions = [sparse]
        _ = try await reopened.apply(batch)
        let restored = try await reopened.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(restored.first?.entry.contractKind,"approval")
        try reopened.pool.close()
        let restoredDB = try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        try await restoredDB.pool.write { try $0.execute(sql:"UPDATE evmHistorySwaps SET version=0") }
        let upgrades = try await restoredDB.swapHistoryCandidates(walletID:"w")
        XCTAssertNotNil(upgrades.first?.cachedEvidence)
        try await project(restoredDB,changed)
        try await restoredDB.pool.write { try $0.execute(sql:"UPDATE transactions SET blockHash='changed'") }
        let reorganized = try await restoredDB.chainHistory(walletID:"w",currency:"USD")
        XCTAssertNil(reorganized.first?.entry.contractKind)
    }
    func testDisappearedReceiptInvalidatesOldProjection() async throws {
        let (db,folder,e) = try await fixture(); defer { try? FileManager.default.removeItem(at:folder) }
        try await add(db,"in"); try await add(db,"out")
        let candidates = try await db.swapHistoryCandidates(walletID:"w")
        let candidate = try XCTUnwrap(candidates.first)
        try await db.saveSwapHistoryEvidence(e,candidate:candidate)
        try await db.saveSwapHistoryEvidence(.init(transaction:.null,receipt:.null),candidate:candidate)
        let fallback = try await db.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(fallback.count,2)
    }
}

private struct LargeHistoryEvidenceTransport: AnkrTransport {
    let evidence: EVMHistoryEvidence
    func send(_ request: URLRequest) async throws -> (Data,Int) {
        let calls = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self,from:XCTUnwrap(request.httpBody)).array)
        let replies = calls.map { call -> SolanaJSON in
            let result: SolanaJSON
            switch call["method"].string {
            case "eth_chainId": result = .string("0x38")
            case "eth_getTransactionByHash": result = evidence.transaction
            case "eth_getTransactionReceipt": result = evidence.receipt
            default: result = .null
            }
            return .object(["jsonrpc":.string("2.0"),"id":call["id"],"result":result])
        }
        let data = try JSONEncoder().encode(SolanaJSON.array(replies))
        XCTAssertLessThanOrEqual(data.count,EVMSendClient.maximumRPCResponseBytes)
        return (data,200)
    }
}
