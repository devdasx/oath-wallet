import Foundation
import GRDB

extension WalletDatabase {
    func cachedAnkrHistoricalTokenPrices(
        walletID: String,
        now: Double = Date().timeIntervalSince1970
    ) async throws -> [String: Decimal] {
        try await pool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT prices.assetID, prices.price, prices.provider,
                       assets.assetType, assets.isVerified
                FROM assetPrices AS prices
                JOIN assets ON assets.id = prices.assetID
                JOIN accountAssets AS holdings
                  ON holdings.assetID = prices.assetID
                JOIN walletAccounts AS accounts
                  ON accounts.id = holdings.accountID
                WHERE accounts.walletID = ?
                  AND prices.quoteCurrency = 'USD'
                  AND prices.observedAt >= ?
                ORDER BY prices.observedAt DESC
                """,
                arguments: [walletID, now - 300]
            )

            var cached: [String: Decimal] = [:]
            for row in rows {
                let assetID: String = row["assetID"]
                guard cached[assetID] == nil else { continue }
                let priceText: String = row["price"]
                let provider: String = row["provider"]
                let assetType: String = row["assetType"]
                guard
                    assetType == DatabaseAssetType.native.rawValue
                        || AssetPriceClient
                            .priceProviderCarriesExactAssetIdentity(provider),
                    let price = Decimal(
                        string: priceText,
                        locale: Locale(identifier: "en_US_POSIX")
                    ),
                    price > 0
                else {
                    continue
                }
                cached[assetID] = price
            }
            return cached
        }
    }

    func saveAnkrHistoricalTokenPrices(
        _ prices: [String: Decimal],
        walletID: String,
        now: Double = Date().timeIntervalSince1970
    ) async throws {
        guard !prices.isEmpty else { return }
        // These values originate in the shared DEX-first resolver. Preserve
        // its observation and provenance instead of relabeling them as ANKR.
        let ownedAssetIDs = try await pool.read { database in
            Set(try String.fetchAll(database, sql: """
                SELECT DISTINCT holdings.assetID FROM accountAssets AS holdings
                JOIN walletAccounts AS accounts ON accounts.id = holdings.accountID
                WHERE accounts.walletID = ?
                """, arguments: [walletID]))
        }
        for assetID in ownedAssetIDs where prices[assetID] != nil {
            if let quote = await AssetPriceClient.shared.resolvedQuote(assetID: assetID) {
                try await saveAssetUSDPrice(quote)
            }
        }
    }
}
