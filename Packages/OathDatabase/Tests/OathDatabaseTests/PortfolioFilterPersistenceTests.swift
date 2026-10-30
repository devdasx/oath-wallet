import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class PortfolioFilterPersistenceTests: XCTestCase {
    private let networks = ["ethereum", "solana", "tron", "ton", "aptos", "sui", "near", "xrpl", "stellar", "arc", "robinhood", "hyperevm", "monad", "unichain"]

    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portfolio-filters-" + UUID().uuidString).appendingPathComponent("db.sqlite")
        let store = try await OathDatabase.open(at: url)
        try await store.seed(networks: networks.enumerated().map { index, id in
            .init(id: id, name: id, family: "fixture", symbol: "COIN", decimals: 6, derivationPath: "", logo: "", sortOrder: index)
        }, assets: networks.map { .init(id: $0 + ":native", networkID: $0, reference: "native", name: "Coin", symbol: "COIN", decimals: 6) })
        for id in ["first", "second"] {
            try await store.importWalletIfNeeded(.init(id: id, name: id, kind: "hd", vaultReference: id, createdAt: 1), accounts: networks.map {
                .init(id: id + ":" + $0, walletID: id, networkID: $0, address: "public-owner", derivationPath: "")
            })
        }
        return (store, url)
    }

    func testEveryFilterSurvivesWalletSwitchCreationAndDatabaseReopen() async throws {
        let (store, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var selection = PortfolioFilter()
        selection.hidesZeroBalances = true; selection.hidesUnverifiedTokens = false
        selection.groupsTokensByChain = true
        selection.onlyWithActivity = true; selection.sort = .highestValue; selection.kind = .tokens
        selection.networkIDs = ["ethereum", "solana"]; selection.minimumValue = 1.25
        selection.maximumValue = 500; selection.rangeCurrency = "USD"
        try await store.savePortfolioFilter(selection, walletID: "first")
        try await store.setSetting("activeWalletID", value: "second")
        let second = try await store.snapshot(walletID: "second", currency: "USD")
        XCTAssertEqual(second.assetFilter, .init())
        try await store.importWalletIfNeeded(.init(id: "new", name: "new", kind: "hd", vaultReference: "new", createdAt: 2), accounts: [])
        let new = try await store.snapshot(walletID: "new", currency: "USD")
        XCTAssertTrue(new.assetFilter.hidesUnverifiedTokens)
        try await store.setSetting("activeWalletID", value: "first")
        let reopened = try await OathDatabase.open(at: url)
        let first = try await reopened.snapshot(walletID: "first", currency: "USD")
        XCTAssertEqual(first.assetFilter, selection)
        XCTAssertEqual(first.assetFilter.adjusted(for: "EUR").hidesZeroBalances, true)
        XCTAssertNil(first.assetFilter.adjusted(for: "EUR").minimumValue)
        try await reopened.savePortfolioFilter(.init(), walletID: "first")
        let reset = try await store.portfolioFilter(walletID: "first")
        XCTAssertEqual(reset, .init())
    }

    func testAllChainInventoriesRevealAndRehideWithoutChangingVerificationOrOtherWallet() async throws {
        let (store, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let chains = networks
        try await store.pool.write { db in
            for network in chains {
                let assetID = network + ":unlisted"
                try AssetRecord(id: assetID, networkID: network, reference: "unlisted", name: "Unlisted Token", symbol: "TEST", decimals: 6).insert(db)
                for wallet in ["first", "second"] {
                    let account = wallet + ":" + network
                    if network == "ethereum" {
                        try BalanceRecord(accountID: account, assetID: assetID, networkID: network, amountAtomic: "1234567", observedAt: 1, source: "ankr").insert(db)
                        try db.execute(sql: "INSERT INTO ankrAssets(accountID,assetID,detail,balanceUsd,fetchedAt,onlyWhitelisted) VALUES(?,?,?,'',1,0)", arguments: [account, assetID, Data()])
                    } else if network == "solana" {
                        try db.execute(sql: "INSERT INTO solanaHoldings(accountID,owner,assetID,amountAtomic,observedAt,slot,verified) VALUES(?,'public-owner',?,'1234567',1,1,0)", arguments: [account, assetID])
                        // A previous receive path must stay excluded even after opt-in.
                        try db.execute(sql: "INSERT INTO solanaHoldings(accountID,owner,assetID,amountAtomic,observedAt,slot,verified) VALUES(?,'old-owner',?,'999',1,1,0)", arguments: [account, assetID])
                    } else if ["tron", "ton", "aptos"].contains(network) {
                        try db.execute(sql: "INSERT INTO \(network)Holdings(accountID,assetID,amountAtomic,observedAt,verified) VALUES(?,?,'1234567',1,0)", arguments: [account, assetID])
                    } else if network == "sui" {
                        try db.execute(sql: "INSERT INTO suiHoldings(accountID,reference,assetID,amountAtomic,coinBalance,addressBalance,observedAt,checkpoint,verified) VALUES(?,'unlisted',?,'1234567','1234567','0',1,1,0)", arguments: [account, assetID])
                    } else if network == "near" {
                        try db.execute(sql: "INSERT INTO nearHoldings(accountID,reference,assetID,amountAtomic,observedAt,blockHeight,verified) VALUES(?,'unlisted',?,'1234567',1,1,0)", arguments: [account, assetID])
                    } else if network == "xrpl" {
                        try db.execute(sql: "INSERT INTO xrplHoldings(accountID,reference,assetID,amountAtomic,signedAmount,observedAt,checkpoint,verified) VALUES(?,'unlisted',?,'1234567','1234567',1,1,0)", arguments: [account, assetID])
                    } else if network == "stellar" {
                        try db.execute(sql: "INSERT INTO stellarHoldings(accountID,reference,assetID,amountAtomic,observedAt,checkpoint,verified) VALUES(?,'unlisted',?,'1234567',1,1,0)", arguments: [account, assetID])
                    } else {
                        let table = ["monad", "unichain"].contains(network) ? "indexedEVMHoldings" : network + "Holdings"
                        try db.execute(sql: "INSERT INTO \(table)(accountID,reference,assetID,detail,amountAtomic,observedAt,checkpoint,verified) VALUES(?,'unlisted',?,?,'1234567',1,1,0)", arguments: [account, assetID, Data()])
                    }
                }
            }
        }
        let hidden = try await store.snapshot(walletID: "first", currency: "USD")
        XCTAssertEqual(hidden.holdings.count, chains.count)
        var selection = PortfolioFilter(); selection.hidesUnverifiedTokens = false
        try await store.savePortfolioFilter(selection, walletID: "first")
        let visible = try await store.snapshot(walletID: "first", currency: "USD")
        XCTAssertEqual(visible.holdings.count, 2 * chains.count)
        let tokens = visible.holdings.filter { $0.reference != "native" }
        XCTAssertEqual(Set(tokens.map(\.networkID)), Set(chains))
        XCTAssertTrue(tokens.allSatisfy { $0.amountAtomic == "1234567" })
        let other = try await store.snapshot(walletID: "second", currency: "USD")
        XCTAssertEqual(other.holdings.count, chains.count)
        try await store.savePortfolioFilter(.init(), walletID: "first")
        let rehidden = try await store.snapshot(walletID: "first", currency: "USD")
        XCTAssertEqual(rehidden.holdings, hidden.holdings)
        let trust = try await store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tokenHistoryTrust WHERE reference='unlisted'") }
        XCTAssertEqual(trust, 0, "Visibility must never manufacture verification")
    }

    func testInvalidMissingDeletedAndResetWritesAreRejectedAndDeletionCascades() async throws {
        let (store, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var selection = PortfolioFilter(); selection.hidesZeroBalances = true
        try await store.savePortfolioFilter(selection, walletID: "first")
        var invalid = selection; invalid.minimumValue = -1
        do { try await store.savePortfolioFilter(invalid, walletID: "first"); XCTFail("Invalid range saved") } catch { }
        do { try await store.savePortfolioFilter(selection, walletID: "missing"); XCTFail("Missing wallet saved") } catch { }
        try await store.pool.write { try $0.execute(sql: "UPDATE wallets SET deletedAt=2 WHERE id='first'") }
        do { try await store.savePortfolioFilter(.init(), walletID: "first"); XCTFail("Deleted wallet saved") } catch { }
        try await store.pool.write { try $0.execute(sql: "UPDATE wallets SET deletedAt=NULL WHERE id='first'") }
        let restored = try await store.portfolioFilter(walletID: "first")
        XCTAssertEqual(restored, selection)
        try await store.deleteWalletMetadata("first")
        let orphanCount = try await store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM walletPortfolioFilters WHERE walletID='first'") }
        XCTAssertEqual(orphanCount, 0)
        try await store.pool.write { try $0.execute(sql: "INSERT INTO metadata(key,value) VALUES('walletReset','fixture')") }
        do { try await store.savePortfolioFilter(selection, walletID: "second"); XCTFail("Reset write accepted") } catch { }
    }
}
