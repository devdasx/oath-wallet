import Foundation
import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

private struct CapturedSafetyTransport: AnkrTransport {
    let bytes: Data
    func send(_ request: URLRequest) async throws -> (Data, Int) { (bytes, 200) }
}

/// Optional read-only integration replay. Generate public responses using
/// Tools/CheckHistorySafetyLive.py; no credential is included in these fixtures.
@MainActor final class HistorySafetyLiveTests: XCTestCase {
    private let evmOwner = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    private let tronOwner = "TJmmqjb1DK9TTZbQXzRQ2AuA94z4gKAPFh"
    private func directory() throws -> URL {
        guard let value = ProcessInfo.processInfo.environment["OATH_HISTORY_SAFETY_RESPONSES"] else {
            throw XCTSkip("Opt-in captured public history safety check")
        }
        return URL(fileURLWithPath: value)
    }
    private func database(_ networks: [String]) async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("safety-live-"+UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await db.seed(networks: networks.enumerated().map { .init(id:$1,name:$1,family:$1 == "tron" ? "account":"evm",symbol:"NATIVE",decimals:$1 == "tron" ? 6:18,derivationPath:"",logo:"",sortOrder:$0) }, assets: networks.map { .init(id:$0+":native",networkID:$0,reference:"native",name:"Native",symbol:"NATIVE",decimals:$0 == "tron" ? 6:18) })
        try await db.importWalletIfNeeded(.init(id:"public",name:"Public fixture",kind:"watchOnly",vaultReference:"none",createdAt:1), accounts:networks.map { .init(id:$0,walletID:"public",networkID:$0,address:$0 == "tron" ? tronOwner:evmOwner,derivationPath:"") })
        return (db,folder)
    }
    func testCapturedAll17AnkrChainsThroughProductionDecoderAndDatabase() async throws {
        let source = try directory()
        let (db,folder) = try await database(AnkrChain.allCases.map(\.networkID))
        defer { try? FileManager.default.removeItem(at:folder) }
        var received = 0, shown = 0
        for chain in AnkrChain.allCases {
            let bytes = try Data(contentsOf:source.appendingPathComponent(chain.rawValue+"-catalog.json"))
            let catalog = try chain == .taiko ? VerifiedEVMTokenCatalog.decodeCoinList(bytes,chain:chain) : VerifiedEVMTokenCatalog.decode(bytes,chain:chain)
            try await db.saveMarketCache(.init(key:"evm.verified."+chain.networkID,source:"CoinGecko",payload:JSONEncoder().encode(catalog),fetchedAt:Date().timeIntervalSince1970))
            let raw = try Data(contentsOf:source.appendingPathComponent(chain.rawValue+"-transfers.json"))
            let page = try await AnkrClient(apiKey:"fixture",transport:CapturedSafetyTransport(bytes:raw)).transfers(chain:chain,address:evmOwner)
            let ticket = try await db.beginAnkrSync(accountID:chain.networkID,stream:"transfers")
            try await db.commitAnkrTransfers(page,ticket:ticket,cursor:nil)
            let rows = try await db.chainHistory(walletID:"public",networkID:chain.networkID,currency:"USD",limit:200)
            let expected = Set(page.value.transfers.filter { value in
                let ref = value.contractAddress.lowercased()
                return (catalog.decimalsByReference[ref] == value.tokenDecimals || catalog.referencesWithoutDecimals?.contains(ref) == true)
                    && value.valueRawInteger != "0" && !HistorySafety.suspiciousMetadata(name:value.tokenName,symbol:value.tokenSymbol)
            }.map { $0.transactionHash.lowercased()+":"+String($0.logIndex)+":"+$0.contractAddress.lowercased() })
            XCTAssertEqual(rows.count,expected.count,chain.rawValue)
            let rawCount = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM activity WHERE networkID=?",arguments:[chain.networkID]) }
            XCTAssertEqual(rawCount,page.value.transfers.count,chain.rawValue)
            let archives = try await db.ankrResponsePages(accountID:chain.networkID,stream:"transfers")
            let pageKey = try XCTUnwrap(archives.first?.pageKey)
            let archived = try await db.ankrResponse(accountID:chain.networkID,stream:"transfers",pageKey:pageKey)
            XCTAssertEqual(archived,raw)
            received += page.value.transfers.count; shown += rows.count
        }
        XCTAssertGreaterThan(received-shown,100)
        XCTAssertGreaterThan(shown,10)
        print("HISTORY_SAFETY_ANKR networks=17 raw=\(received) visible=\(shown) hidden=\(received-shown)")
    }
    func testCapturedTronReceiptsThroughProductionDecoderAndDatabase() async throws {
        let source = try directory()
        let (db,folder) = try await database(["tron"])
        defer { try? FileManager.default.removeItem(at:folder) }
        let list = try Data(contentsOf:source.appendingPathComponent("tron-catalog.json"))
        let catalog = try TronMarkets.decodeCatalog(list)
        try await db.saveMarketCache(.init(key:"tron.coingecko.catalog.v1",source:"CoinGecko",payload:list,fetchedAt:Date().timeIntervalSince1970))
        let transfers = try JSONDecoder().decode([TronJSON].self,from:Data(contentsOf:source.appendingPathComponent("tron-transfers.json")))
        var tokens: [String:TronToken] = ["native":.init(reference:"native",name:"TRON",symbol:"TRX",decimals:6)]
        for value in transfers {
            let token = value["token_info"]
            let ref = try XCTUnwrap(token["address"].string)
            tokens[ref] = .init(reference:ref,name:try XCTUnwrap(token["name"].string),symbol:try XCTUnwrap(token["symbol"].string),decimals:Int(try XCTUnwrap(token["decimals"].integer)))
        }
        let raw = try Data(contentsOf:source.appendingPathComponent("tron-receipts.json"))
        let receipts = try JSONDecoder().decode([String:TronJSON].self,from:raw)
        let transactions = try receipts.map { try TronDecoding.transaction(hash:$0.key,body:$0.value["body"],receipt:$0.value["receipt"]) }
        let ticket = try await db.beginTronSync(accountID:"tron")
        let work = try await db.tronHistoryWork(ticket)
        let cursor = try XCTUnwrap(work.first { $0.stream == "trc20" })
        try await db.commitTronPage(.init(hashes:transactions.map(\.hash),cursor:nil,raw:raw),transactions:transactions,tokens:tokens,catalog:catalog,cursor:cursor,ticket:ticket)
        let visible = try await db.chainHistory(walletID:"public",networkID:"tron",currency:"USD",limit:200)
        let rawTokens = try await db.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM activity a JOIN assets s ON s.id=a.assetID WHERE s.reference<>'native'")! }
        let tokenRows = visible.filter { $0.holding.reference != "native" }
        XCTAssertGreaterThan(rawTokens,tokenRows.count)
        XCTAssertFalse(tokenRows.isEmpty)
        for row in tokenRows { XCTAssertEqual(catalog[row.holding.reference]?.decimals,row.holding.decimals) }
        print("HISTORY_SAFETY_TRON receipts=\(transactions.count) tokenEvents=\(rawTokens) visibleTokens=\(tokenRows.count)")
    }
}
