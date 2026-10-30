import Foundation
import XCTest
import GRDB
import OathAnkr
@testable import OathDatabase

@MainActor final class HistorySafetyTests: XCTestCase {
    private let networks = AnkrChain.allCases.map(\.networkID) + ["bitcoin","dogecoin","litecoin","bitcoincash","solana","tron","ton","aptos","sui","near","xrpl","stellar","arc","robinhood"]

    private func fixture(_ networks: [String]) async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-safety-" + UUID().uuidString)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await db.seed(networks: networks.enumerated().map {
            .init(id: $1, name: $1, family: "fixture", symbol: "COIN", decimals: 6, derivationPath: "", logo: "", sortOrder: $0)
        }, assets: networks.map { .init(id: $0+":native", networkID: $0, reference: "native", name: "Coin", symbol: "COIN", decimals: 6) })
        try await db.importWalletIfNeeded(.init(id: "w", name: "Wallet", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: networks.map {
            .init(id: $0, walletID: "w", networkID: $0, address: "public-owner", derivationPath: "")
        })
        return (db, folder)
    }

    nonisolated private static func activity(_ db: Database, network: String, key: String, reference: String,
                                 name: String = "Token", symbol: String = "USDT", amount: String = "1000000",
                                 direction: String = "incoming", state: String = "confirmed", time: Double = 100) throws -> String {
        let assetID = network+":"+reference, id = network+":"+key
        try AssetRecord(id: assetID, networkID: network, reference: reference, name: name, symbol: symbol, decimals: 6).insert(db, onConflict: .ignore)
        try TransactionRecord(id: id, networkID: network, hash: id, state: state, timestamp: time, updatedAt: time).insert(db)
        try ActivityRecord(id: id, walletID: "w", accountID: network, networkID: network, transactionID: id,
            assetID: assetID, direction: direction, amountAtomic: amount, counterparty: "public-peer", timestamp: time).insert(db)
        if network == "solana" {
            try db.execute(sql: "INSERT INTO solanaActivity(activityID,owner) VALUES(?,'public-owner')", arguments: [id])
        }
        return id
    }

    func testAll31NetworksHideUnverifiedPhishingAndZeroTransfersBeforeEveryRead() async throws {
        let networks = networks
        XCTAssertEqual(networks.count, 31)
        let (store, folder) = try await fixture(networks); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.pool.write { db in
            for network in networks {
                _ = try Self.activity(db, network: network, key: "native", reference: "native", amount: "1")
                _ = try Self.activity(db, network: network, key: "unknown", reference: "unknown", name: "SUNGAME", symbol: "SUNGAME", time: 200)
                _ = try Self.activity(db, network: network, key: "good", reference: "listed", time: 150)
                _ = try Self.activity(db, network: network, key: "impostor", reference: "impostor", time: 300)
                _ = try Self.activity(db, network: network, key: "zero", reference: "listed", amount: "0", time: 400)
                _ = try Self.activity(db, network: network, key: "zero-out", reference: "listed", amount: "0", direction: "outgoing", time: 410)
                _ = try Self.activity(db, network: network, key: "native-zero", reference: "native", amount: "0", time: 420)
                _ = try Self.activity(db, network: network, key: "bait", reference: "bait", name: "www.lamperio.top ✅ claim", time: 500)
                for reference in ["listed","bait"] {
                    try HistorySafety.trust(networkID: network, reference: reference, decimals: 6, source: "fixture", observedAt: 1, db: db)
                }
            }
        }
        for network in networks {
            let visible = try await store.chainHistory(walletID: "w", networkID: network, currency: "USD", limit: 2)
            XCTAssertEqual(visible.map(\.id), [network+":good",network+":native"], network)
            let asset = try await store.assetHistory(walletID: "w", accountID: network, assetID: network+":listed")
            XCTAssertEqual(asset.map(\.id), [network+":good"], network)
            let hiddenSearch = try await store.chainHistory(walletID: "w", networkID: network, currency: "USD", search: "SUNGAME")
            XCTAssertTrue(hiddenSearch.isEmpty, network)
            let options = try await store.historyFilterAssets(walletID: "w", networkID: network)
            XCTAssertEqual(Set(options.map(\.reference)), ["listed","native"], network)
            let details = try await store.transactionDetails(accountID: network, transactionID: network+":bait")
            XCTAssertNil(details, network)
        }
        let history = try await store.history(walletID: "w", limit: 200)
        XCTAssertEqual(history.count, networks.count*2)
        let raw = try await store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activity") }
        XCTAssertEqual(raw, networks.count*8, "Never delete ledger evidence or alter cursors to hide spam")
    }

    func testWalletOptInRevealsUnlistedHistoryWithoutBypassingPhishingOrZeroTransferChecks() async throws {
        let (store, folder) = try await fixture(["ethereum"])
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.pool.write { db in
            _ = try Self.activity(db, network: "ethereum", key: "unknown", reference: "unknown")
            _ = try Self.activity(db, network: "ethereum", key: "bait", reference: "bait", name: "https://example.invalid claim")
            _ = try Self.activity(db, network: "ethereum", key: "zero", reference: "zero", amount: "0")
            _ = try Self.activity(db, network: "ethereum", key: "blocked", reference: "blocked")
            try db.execute(sql: "INSERT INTO tokenHistoryBlocks(networkID,reference,source) VALUES('ethereum','blocked','fixture')")
        }
        let hidden = try await store.history(walletID: "w")
        XCTAssertTrue(hidden.isEmpty)
        var filter = PortfolioFilter(); filter.hidesUnverifiedTokens = false
        try await store.savePortfolioFilter(filter, walletID: "w")
        let visible = try await store.history(walletID: "w")
        XCTAssertEqual(visible.map(\.id), ["ethereum:unknown"])
        let searched = try await store.chainHistory(walletID: "w", networkID: "ethereum", currency: "USD", search: "USDT")
        XCTAssertEqual(searched.map(\.id), ["ethereum:unknown"])
        try await store.savePortfolioFilter(.init(), walletID: "w")
        let rehidden = try await store.history(walletID: "w")
        XCTAssertTrue(rehidden.isEmpty)
    }

    func testManualTrackingIsWalletScopedAndCannotBypassBaitOrZeroFilter() async throws {
        let (store, folder) = try await fixture(["tron"]); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.pool.write { db in
            _ = try Self.activity(db, network: "tron", key: "custom", reference: "custom")
            _ = try Self.activity(db, network: "tron", key: "bait", reference: "bait", symbol: "https://claim.example")
            _ = try Self.activity(db, network: "tron", key: "zero", reference: "custom", amount: "0")
            for reference in ["custom","bait"] {
                try db.execute(sql: "INSERT INTO trackedAssets(accountID,assetID,networkID,addedAt) VALUES('tron',?,'tron',1)",arguments:["tron:"+reference])
            }
        }
        try await store.importWalletIfNeeded(.init(id:"other",name:"Other",kind:"hd",vaultReference:"other",createdAt:1), accounts:[.init(id:"other-tron",walletID:"other",networkID:"tron",address:"public-owner",derivationPath:"")])
        try await store.pool.write { db in
            try ActivityRecord(id:"other-row",walletID:"other",accountID:"other-tron",networkID:"tron",transactionID:"tron:custom",assetID:"tron:custom",direction:"incoming",amountAtomic:"1000000",counterparty:"peer",timestamp:100).insert(db)
        }
        let other = try await store.chainHistory(walletID:"other",currency:"USD"); XCTAssertTrue(other.isEmpty)
        let rows = try await store.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(rows.map(\.id), ["tron:custom"])
    }

    func testKeepOutgoingNativeInteractionsAndFailuresWithoutUsingPriceAsTrust() async throws {
        let (store, folder) = try await fixture(["ethereum"]); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.pool.write { db in
            _ = try Self.activity(db, network: "ethereum", key: "approval", reference: "native", amount: "0", direction: "outgoing")
            _ = try Self.activity(db, network: "ethereum", key: "failed", reference: "listed", amount: "0", direction: "outgoing", state: "failed")
            _ = try Self.activity(db, network: "ethereum", key: "priced-spam", reference: "unknown")
            _ = try Self.activity(db, network: "ethereum", key: "replaced", reference: "listed", amount: "0", direction: "outgoing", state: "pending")
            try db.execute(sql: "INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet,outcome) VALUES('ethereum','ethereum:replaced',?,0,'replaced')",arguments:[Data("[]".utf8)])
            try HistorySafety.trust(networkID: "ethereum", reference: "listed", decimals: 6, source: "fixture", observedAt: 1, db: db)
        }
        try await store.savePrices([.init(assetID: "ethereum:unknown", currency: "USD", value: "999999", observedAt: 1, source: "DEX")])
        let rows = try await store.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(Set(rows.map(\.id)), ["ethereum:approval","ethereum:failed","ethereum:replaced"])
    }

    func testCatalogTrustMatchesNetworkReferenceAndDecimalsAndUpdatesObservers() async throws {
        let (store, folder) = try await fixture(["ethereum","polygon"]); defer { try? FileManager.default.removeItem(at: folder) }
        let address = "0x"+String(repeating: "1", count: 40)
        try await store.pool.write { db in
            for network in ["ethereum","polygon"] { _ = try Self.activity(db, network: network, key: "receipt", reference: address) }
        }
        var history = store.observeChainHistory(walletID: "w", currency: "USD").makeAsyncIterator()
        let before = try await history.next(); XCTAssertEqual(before?.count, 0)
        let data = Data("{\"tokens\":[{\"address\":\"\(address)\",\"chainId\":1,\"decimals\":6}]}".utf8)
        let list = try VerifiedEVMTokenCatalog.decode(data, chain: .eth)
        try await store.saveMarketCache(.init(key: "evm.verified.ethereum", source: "CoinGecko", payload: JSONEncoder().encode(list), fetchedAt: 1))
        let after = try await history.next(); XCTAssertEqual(after?.map(\.id), ["ethereum:receipt"])
        try await store.pool.write { db in try db.execute(sql: "UPDATE assets SET decimals=18 WHERE networkID='ethereum' AND reference=?",arguments:[address]) }
        let mismatch = try await history.next(); XCTAssertEqual(mismatch?.count, 0)
    }

    func testIdentityOnlyCatalogKeepsKnownPrecisionAndExactNetworkScope() async throws {
        let (store, folder) = try await fixture(["story", "telos"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let address = "0x" + String(repeating: "a", count: 40)
        try await store.pool.write { db in
            for network in ["story", "telos"] {
                _ = try Self.activity(db, network: network, key: "receipt", reference: address)
            }
        }
        let precise = try VerifiedEVMTokenCatalog.decode(Data("{\"tokens\":[{\"address\":\"\(address)\",\"chainId\":1514,\"decimals\":6}]}".utf8), chain: .story)
        try await store.saveMarketCache(.init(key: "evm.verified.story", source: "CoinGecko", payload: JSONEncoder().encode(precise), fetchedAt: 1))
        try await store.pool.write { db in
            try db.execute(sql: "UPDATE assets SET decimals=18 WHERE networkID='story' AND reference=?", arguments: [address])
        }
        let before = try await store.chainHistory(walletID: "w", currency: "USD")
        XCTAssertTrue(before.isEmpty)
        let identityOnly = try VerifiedEVMTokenCatalog.decodeCoinList(Data("[{\"platforms\":{\"story\":\"\(address)\"}}]".utf8), chain: .story)
        try await store.saveMarketCache(.init(key: "evm.verified.story", source: "CoinGecko", payload: JSONEncoder().encode(identityOnly), fetchedAt: 2))
        let after = try await store.chainHistory(walletID: "w", currency: "USD")
        XCTAssertTrue(after.isEmpty, "Missing precision cannot erase the previously verified precision")
        try await store.pool.write { db in
            try db.execute(sql: "UPDATE assets SET decimals=6 WHERE networkID='story' AND reference=?", arguments: [address])
        }
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let valid = try await reopened.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(valid.map(\.id), ["story:receipt"], "Another network cannot inherit this contract's trust")
    }

    func testVerifiedBalanceEvidenceSurvivesZeroBalanceAndRestart() async throws {
        let (store, folder) = try await fixture(["tron"]); defer { try? FileManager.default.removeItem(at: folder) }
        try await store.pool.write { db in
            _ = try Self.activity(db, network: "tron", key: "receipt", reference: "known")
            try db.execute(sql: "INSERT INTO tronHoldings(accountID,assetID,amountAtomic,observedAt,verified) VALUES('tron','tron:known','1',1,1)")
            try db.execute(sql: "DELETE FROM tronHoldings WHERE accountID='tron'")
        }
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let history = try await reopened.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(history.map(\.id), ["tron:receipt"])
    }

    func testPhishingMetadataNormalizesInvisibleAndWideCharactersWithoutBanningProjectDomains() {
        for name in ["www.lamperio.top ✅ claim", "HTTPS://claim.example", "w\u{200B}ww.scam.example", "ｗｗｗ.scam.example", "reward.example claim", "t.me/scam"] {
            XCTAssertTrue(HistorySafety.suspiciousMetadata(name: name, symbol: "TOKEN"), name)
        }
        for name in ["yearn.finance", "Aave", "SUNGAME", "Claim Governance", "USD Coin"] {
            XCTAssertFalse(HistorySafety.suspiciousMetadata(name: name, symbol: "TOKEN"), name)
        }
    }
    func testUpgradeFiltersExistingRowsUsingCachedCatalogWithoutNetwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-upgrade-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("db.sqlite"), old = try DatabaseQueue(path: folder.appendingPathComponent("db.sqlite").path)
        try Schema.migrator.migrate(old, upTo: "v27_history_participants")
        let reference = "0x"+String(repeating:"a",count:40)
        let catalog = try VerifiedEVMTokenCatalog.decode(Data("{\"tokens\":[{\"address\":\"\(reference)\",\"chainId\":1,\"decimals\":6}]}".utf8), chain: .eth)
        try await old.write { db in
            try NetworkRecord(id:"ethereum",name:"Ethereum",family:"evm",symbol:"ETH",decimals:18,derivationPath:"",logo:"",sortOrder:0).insert(db)
            // Use the historical schema, not today's record encoder.
            try db.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('w','Wallet','hd','fixture',1,0)")
            try AccountRecord(id:"ethereum",walletID:"w",networkID:"ethereum",address:"public-owner",derivationPath:"").insert(db)
            _ = try Self.activity(db,network:"ethereum",key:"listed",reference:reference)
            _ = try Self.activity(db,network:"ethereum",key:"spam",reference:"unlisted",name:"SUNGAME",symbol:"SUNGAME")
            _ = try Self.activity(db,network:"ethereum",key:"holding",reference:"held")
            try db.execute(sql:"INSERT INTO ankrAssets(accountID,assetID,detail,balanceUsd,fetchedAt,onlyWhitelisted) VALUES('ethereum','ethereum:held',?,'',1,1)",arguments:[Data("{}".utf8)])
            try MarketCacheEntry(key:"evm.verified.ethereum",source:"CoinGecko",payload:JSONEncoder().encode(catalog),fetchedAt:1).upsert(db)
        }
        try old.close()
        let upgraded = try await OathDatabase.open(at:url)
        let rows = try await upgraded.chainHistory(walletID:"w",currency:"USD")
        XCTAssertEqual(Set(rows.map(\.id)),["ethereum:listed","ethereum:holding"])
        let count = try await upgraded.pool.read { try Int.fetchOne($0,sql:"SELECT COUNT(*) FROM activity") }
        XCTAssertEqual(count,3)
    }

    func testProviderBlacklistOverridesPreviousVerificationAndManualTracking() async throws {
        let (store,folder) = try await fixture(["ton"]); defer { try? FileManager.default.removeItem(at:folder) }
        let reference = "0:"+String(repeating:"a",count:64)
        try await store.pool.write { db in
            _ = try Self.activity(db,network:"ton",key:"receipt",reference:reference)
            try HistorySafety.trust(networkID:"ton",reference:reference,decimals:6,source:"old",observedAt:1,db:db)
            try db.execute(sql:"INSERT INTO trackedAssets(accountID,assetID,networkID,addedAt) VALUES('ton',?,'ton',1)",arguments:["ton:"+reference])
        }
        let allowed = try await store.history(walletID:"w"); XCTAssertEqual(allowed.count,1)
        let token = TonToken(reference:reference,name:"Token",symbol:"TKN",decimals:6,isBlacklisted:true)
        try await store.saveMarketCache(.init(key:"ton.token."+reference,source:"TonAPI",payload:JSONEncoder().encode(token),fetchedAt:2))
        let hidden = try await store.history(walletID:"w"); XCTAssertTrue(hidden.isEmpty)
    }

}
