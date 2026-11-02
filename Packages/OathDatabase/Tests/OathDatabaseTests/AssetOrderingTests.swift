import XCTest
import GRDB
import OathBitcoin
@testable import OathDatabase

@MainActor final class AssetOrderingTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AssetOrder-" + UUID().uuidString)
            .appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        // Deliberately reverse the catalog order; it must not decide portfolio order.
        try await db.seed(networks: [
            .init(id: "bitcoin", name: "Bitcoin", family: "utxo", symbol: "BTC", decimals: 8, derivationPath: "test", logo: "btc", sortOrder: 1),
            .init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "test", logo: "eth", sortOrder: 0)
        ], assets: [
            .init(id: "btc", networkID: "bitcoin", reference: "native", name: "Bitcoin", symbol: "BTC", decimals: 8),
            .init(id: "eth", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", decimals: 18)
        ])
        for wallet in ["w1", "w2"] {
            try await db.importWalletIfNeeded(.init(id: wallet, name: wallet, kind: "hd", vaultReference: "fixture-" + wallet, createdAt: 1),
                accounts: [
                    .init(id: wallet + "-btc", walletID: wallet, networkID: "bitcoin", address: "public-" + wallet, derivationPath: "test"),
                    .init(id: wallet + "-eth", walletID: wallet, networkID: "ethereum", address: "public-" + wallet, derivationPath: "test")
                ])
        }
        return (db, url)
    }

    private func token(_ id: String, name: String, decimals: Int = 6) -> AssetRecord {
        .init(id: id, networkID: "ethereum", reference: "contract-" + id, name: name, symbol: id.uppercased(), decimals: decimals)
    }

    private func balance(_ asset: String, amount: String, wallet: String = "w1", at: Double = 1) -> BalanceRecord {
        let bitcoin = asset == "btc"
        return .init(accountID: wallet + (bitcoin ? "-btc" : "-eth"), assetID: asset,
                     networkID: bitcoin ? "bitcoin" : "ethereum", amountAtomic: amount, observedAt: at, source: "fixture")
    }

    private func price(_ asset: String, _ value: String, at: Double = 1) -> PriceRecord {
        .init(assetID: asset, currency: "USD", value: value, observedAt: at, source: "fixture")
    }

    /// Several entries may belong to the same transaction (ERC-20 logs/self transfers).
    private func history(_ db: OathDatabase, network: String, wallet: String = "w1", account: String? = nil,
                         entries: [(asset: String, hash: String)]) async throws {
        let account = account ?? wallet + (network == "bitcoin" ? "-btc" : "-eth")
        let prefix = UUID().uuidString
        var batch = SyncBatch(cursor: .init(accountID: account, stream: prefix, cursor: "1", updatedAt: 1), expectedCursor: nil)
        for (index, entry) in entries.enumerated() {
            let id = network + ":" + entry.hash
            batch.transactions.append(.init(id: id, networkID: network, hash: entry.hash,
                state: index.isMultiple(of: 2) ? "pending" : "confirmed", timestamp: 1, updatedAt: 1))
            batch.activity.append(.init(id: prefix + "-\(index)", walletID: wallet, accountID: account,
                networkID: network, transactionID: id, assetID: entry.asset, direction: "incoming",
                amountAtomic: "1", counterparty: "public-fixture", timestamp: 1))
        }
        _ = try await db.apply(batch)
    }

    func testHoldingValueWinsAcrossCoinsAndTokensAndDoesNotDependOnDisplayCurrency() async throws {
        let (db, _) = try await fixture()
        try await db.trackAsset(token("cent", name: "Aardvark", decimals: 2), walletID: "w1")
        try await db.trackAsset(token("unknown", name: "Unpriced", decimals: 0), walletID: "w1")
        try await db.saveBalances([
            balance("btc", amount: "100000000"), balance("eth", amount: "1000000000000000000"),
            balance("cent", amount: "100000"), balance("unknown", amount: String(repeating: "9", count: 60))
        ])
        try await db.savePrices([price("btc", "10"), price("eth", "30"), price("cent", "0.02")])
        try await history(db, network: "bitcoin", entries: [("btc", "1"), ("btc", "2")])
        let usd = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(usd.holdings.map(\.assetID), ["eth", "cent", "btc", "unknown"])
        XCTAssertEqual(usd.holdings.map(\.usdDisplayValue), [30, 20, 10, nil])
        XCTAssertEqual(usd.totalFiat, 60)
        XCTAssertFalse(usd.valuationComplete)

        let missingFX = try await db.snapshot(walletID: "w1", currency: "JOD")
        XCTAssertEqual(missingFX.holdings.map(\.id), usd.holdings.map(\.id))
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "JOD": "0.709"], observedAt: 1, fetchedAt: 1, source: "fixture"))
        try await db.selectDisplayCurrency("JOD")
        let jod = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(jod.holdings.map(\.id), usd.holdings.map(\.id))
        XCTAssertEqual(jod.totalFiat, Decimal(string: "42.54"))
    }

    func testTransactionCountIsDistinctPerAssetAndIsolatedByWalletAndAccount() async throws {
        let (db, _) = try await fixture()
        try await db.trackAsset(token("alpha", name: "Alpha"), walletID: "w1")
        try await db.saveBalances([balance("btc", amount: "0"), balance("eth", amount: "0"), balance("alpha", amount: "0")])
        try await history(db, network: "ethereum", entries: Array(repeating: ("eth", "shared"), count: 12)
                          + Array(repeating: ("alpha", "shared"), count: 7))
        try await history(db, network: "bitcoin", entries: [("btc", "first"), ("btc", "second")])
        try await history(db, network: "ethereum", wallet: "w2", entries: [("eth", "1"), ("eth", "2"), ("eth", "3")])
        try await db.pool.write { sql in
            try AccountRecord(id: "w1-other", walletID: "w1", networkID: "ethereum", address: "another-public-account", derivationPath: "test", accountIndex: 1).insert(sql)
        }
        try await history(db, network: "ethereum", account: "w1-other", entries: [("eth", "4"), ("eth", "5"), ("eth", "6")])
        let snapshot = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(snapshot.holdings.map(\.transactionCount), [3, 2, 1, 1])
        XCTAssertEqual(snapshot.holdings.map(\.accountID), ["w1-other", "w1-btc", "w1-eth", "w1-eth"])
        XCTAssertEqual(snapshot.holdings.map(\.assetID), ["eth", "btc", "alpha", "eth"])
        let other = try await db.snapshot(walletID: "w2", currency: "USD")
        XCTAssertEqual(other.holdings.map(\.transactionCount), [3, 0])
    }

    func testBitcoinFamilyHistoryIncludesPendingAndDeduplicatesOtherHistorySource() async throws {
        let (db, _) = try await fixture()
        for (index, network) in [UTXONetwork.bitcoin, .dogecoin, .litecoin, .bitcoincash].enumerated() {
            let name = network.rawValue
            let assetID = network == .bitcoin ? "btc" : name + ":native"
            let accountID = network == .bitcoin ? "w1-btc" : "w1-" + name
            if network != .bitcoin {
                try await db.seed(networks: [.init(id: name, name: name, family: "utxo", symbol: name, decimals: 8, derivationPath: "test", logo: "test", sortOrder: 0)],
                    assets: [.init(id: assetID, networkID: name, reference: "native", name: name, symbol: name, decimals: 8)])
                try await db.pool.write { sql in
                    try AccountRecord(id: accountID, walletID: "w1", networkID: name, address: "public-fixture", derivationPath: "test").insert(sql)
                }
            }
            // Public deterministic descriptor, never used by the app or funded.
            let descriptor = try network.wallet(seed: Data(0..<32))
            let encoded = try JSONEncoder().encode(descriptor)
            try await db.pool.write { sql in
                try sql.execute(sql: "INSERT INTO bitcoinWallets(accountID,descriptor,preferredType) VALUES(?,?,?)", arguments: [accountID, encoded, 44])
                for number in 0..<(index + 1) {
                    try sql.execute(sql: "INSERT INTO bitcoinHistory(accountID,txid,height) VALUES(?,?,?)",
                                    arguments: [accountID, "tx-\(number)", number == 0 ? 0 : 800_000])
                }
            }
            // The same transaction in the generic ledger must not count twice.
            try await history(db, network: name, account: accountID, entries: [(assetID, "tx-0")])
        }
        let snapshot = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(snapshot.holdings.map(\.networkID), ["bitcoincash", "litecoin", "dogecoin", "bitcoin", "ethereum"])
        XCTAssertEqual(snapshot.holdings.map(\.transactionCount), [4, 3, 2, 1, 0])
    }

    func testNameAndIdentityTiesStayStableWithUnknownAmountsAndAfterReopening() async throws {
        let (db, url) = try await fixture()
        for (id, name) in [("z", "Éther"), ("a", "ether"), ("m", " ETHER ")] {
            try await db.trackAsset(token(id, name: name), walletID: "w1")
        }
        let snapshot = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(snapshot.holdings.map(\.assetID), ["btc", "a", "m", "z", "eth"])
        XCTAssertTrue(snapshot.holdings.allSatisfy { $0.amountAtomic == nil })
        for _ in 0..<20 {
            XCTAssertEqual(AssetOrdering.sorted(snapshot.holdings.shuffled(), by: \.sortKey).map(\.id), snapshot.holdings.map(\.id))
        }
        let reopened = try await OathDatabase.open(at: url)
        let restored = try await reopened.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(restored.holdings, snapshot.holdings)
        // Tiny differences retain Decimal precision instead of rounding to cents.
        let smaller = AssetSortKey(balanceUSD: Decimal(string: "0.000000000000000001"), transactionCount: 99, name: "A", identity: "a")
        let larger = AssetSortKey(balanceUSD: Decimal(string: "0.000000000000000002"), name: "Z", identity: "z")
        XCTAssertLessThan(larger, smaller)
        XCTAssertEqual(AssetSortKey(balanceUSD: .nan, name: "A", identity: "a"), AssetSortKey(name: "A", identity: "a"))
    }

    func testSharedChoicesUseCanonicalAssetsAndTheSelectedWallet() async throws {
        let (db, _) = try await fixture()
        try await db.trackAsset(token("legacy-id", name: "Token"), walletID: "w1")
        try await db.saveBalances([balance("eth", amount: "1000000000000000000"), balance("btc", amount: "100000000"), balance("legacy-id", amount: "1000000")])
        try await db.savePrices([price("eth", "2"), price("btc", "1"), price("legacy-id", "3")])
        let snapshot = try await db.snapshot(walletID: "w1", currency: "USD")
        let order = PortfolioAssetOrder(snapshot.holdings)
        XCTAssertLessThan(order.key(networkID: "ethereum", reference: "contract-legacy-id", name: "Token"),
                          order.key(networkID: "ethereum", name: "Ethereum"))
        XCTAssertLessThan(order.key(networkID: "ethereum", accountID: "w1-eth", name: "Ethereum"),
                          order.key(networkID: "bitcoin", accountID: "w1-btc", name: "Bitcoin"))
        XCTAssertEqual(order.key(networkID: "ethereum", accountID: "w2-eth", name: "Ethereum"),
                       AssetSortKey(name: "Ethereum", identity: "ethereum:native:w2-eth"))
        XCTAssertEqual(snapshot.networks.map(\.id), ["ethereum", "bitcoin"])
        try await db.setSetting("activeWalletID", value: "w1")
        var networks = try await db.networks()
        XCTAssertEqual(networks.map(\.id), ["ethereum", "bitcoin"])
        try await db.setSetting("activeWalletID", value: "w2")
        networks = try await db.networks()
        XCTAssertEqual(networks.map(\.id), ["bitcoin", "ethereum"])
    }

    func testObservationReordersAfterHistoryPricesAndBalancesCommit() async throws {
        let (db, _) = try await fixture()
        let initial = expectation(description: "name fallback")
        let activity = expectation(description: "history order")
        let priced = expectation(description: "priced balance order")
        let refreshed = expectation(description: "refreshed balance order")
        let observer = Task {
            var seen = Set<String>()
            for try await snapshot in db.observeWallet(walletID: "w1", currency: "USD") {
                guard let first = snapshot.holdings.first else { continue }
                if first.assetID == "btc", first.amountAtomic == nil, seen.insert("initial").inserted { initial.fulfill() }
                if first.assetID == "eth", first.transactionCount == 1, first.amountAtomic == nil, seen.insert("history").inserted { activity.fulfill() }
                if first.assetID == "btc", first.usdDisplayValue == 5, seen.insert("priced").inserted { priced.fulfill() }
                if first.assetID == "eth", first.usdDisplayValue == 10, seen.insert("refreshed").inserted { refreshed.fulfill() }
            }
        }
        defer { observer.cancel() }
        await fulfillment(of: [initial], timeout: 3)
        try await history(db, network: "ethereum", entries: [("eth", "first")])
        await fulfillment(of: [activity], timeout: 3)
        try await db.saveBalances([balance("btc", amount: "100000000"), balance("eth", amount: "1000000000000000000")])
        try await db.savePrices([price("btc", "5"), price("eth", "1")])
        await fulfillment(of: [priced], timeout: 3)
        try await db.saveBalances([balance("eth", amount: "10000000000000000000", at: 2)])
        await fulfillment(of: [refreshed], timeout: 3)
    }

    func testV12MigrationKeepsHoldingsHistoryAndPreferences() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AssetOrderMigration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("wallet.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try Schema.migrator.migrate(old, upTo: "v12_ankr_whitelisted_holdings")
        try await old.write { sql in
            try NetworkRecord(id: "bitcoin", name: "Bitcoin", family: "utxo", symbol: "BTC", decimals: 8, derivationPath: "test", logo: "btc", sortOrder: 0).insert(sql)
            try AssetRecord(id: "btc", networkID: "bitcoin", reference: "native", name: "Bitcoin", symbol: "BTC", decimals: 8).insert(sql)
            try sql.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES(?,?,?,?,?,?)", arguments: ["w1", "Existing", "hd", "fixture", 1, false])
            try AccountRecord(id: "w1-btc", walletID: "w1", networkID: "bitcoin", address: "public-fixture", derivationPath: "test").insertIntoHistoricalAccounts(sql)
            try BalanceRecord(accountID: "w1-btc", assetID: "btc", networkID: "bitcoin", amountAtomic: "123", observedAt: 1, source: "fixture").insert(sql)
            try TransactionRecord(id: "tx", networkID: "bitcoin", hash: "public-hash", state: "pending", timestamp: 1, updatedAt: 1).insert(sql)
            try ActivityRecord(id: "event", walletID: "w1", accountID: "w1-btc", networkID: "bitcoin", transactionID: "tx", assetID: "btc", direction: "incoming", amountAtomic: "123", counterparty: "public-fixture", timestamp: 1).insert(sql)
            try SettingRecord(key: "language", value: "ar", updatedAt: 1).insert(sql)
        }
        try old.close()
        let db = try await OathDatabase.open(at: url)
        let snapshot = try await db.snapshot(walletID: "w1", currency: "USD")
        XCTAssertEqual(snapshot.wallet.name, "Existing")
        XCTAssertEqual(snapshot.settings["language"], "ar")
        XCTAssertEqual(snapshot.holdings.first?.amountAtomic, "123")
        XCTAssertEqual(snapshot.holdings.first?.transactionCount, 1)
        let indexes = try await db.pool.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='index'") }
        XCTAssertTrue(indexes.contains("activity_wallet_asset_transaction"))
    }
}
