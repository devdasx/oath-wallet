import Foundation
import GRDB

enum AssetPriceProviderFailureReason: String, Sendable {
    case invalidURL
    case httpStatus
    case decoding
    case missingPrice
    case identityMismatch
}

enum AssetPriceError: Error, Equatable, Sendable {
    case unsupportedAsset
    case unavailable
    case invalidResponse
    case providerFailure(
        provider: String,
        reason: AssetPriceProviderFailureReason,
        statusCode: Int?
    )
}

struct AssetUSDPrice: Sendable {
    let assetID: String
    let price: Decimal
    let provider: String
    let observedAt: Date
}

/// Resolves exact USD prices without requiring credentials. Asset identity is
/// retained through the request and cache. Tokens always use chain plus contract
/// identity; native coins have their own market-provider lane.
actor AssetPriceClient {
    static let shared = AssetPriceClient(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private static let freshLifetime: TimeInterval = 5 * 60
    static let exactContractPriceProvider = "coingecko-contract-v3"
    static let defiLlamaContractPriceProvider = "defillama-contract-v2"
    static let geckoTerminalContractPriceProvider =
        "geckoterminal-contract-v2"
    static let dexScreenerContractPriceProvider =
        "dexscreener-contract-v2"
    static let tonAPIContractPriceProvider = "tonapi-contract-v2"
    static let defiLlamaMarketPriceProvider = "defillama-market-v1"
    private static let exactAssetPriceProviders: Set<String> = [
        exactContractPriceProvider,
        defiLlamaContractPriceProvider,
        geckoTerminalContractPriceProvider,
        dexScreenerContractPriceProvider,
        tonAPIContractPriceProvider
    ]

    private let session: URLSession
    private let databaseProvider:
        @Sendable () throws -> WalletDatabase
    private var memory: [String: AssetUSDPrice] = [:]
    private var inFlight: [String: Task<AssetUSDPrice, Error>] = [:]

    init(
        session: URLSession? = nil,
        database: WalletDatabase
    ) {
        databaseProvider = { database }
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    private init(
        session: URLSession? = nil,
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase
    ) {
        self.databaseProvider = databaseProvider
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    private var database: WalletDatabase {
        get throws {
            try databaseProvider()
        }
    }

    func usdPrice(for asset: WalletAsset) async throws -> AssetUSDPrice {
        if let value = memory[asset.id],
           Date().timeIntervalSince(value.observedAt) < Self.freshLifetime,
           Self.cachedPriceIsReusable(value, for: asset) {
            return value
        }
        memory[asset.id] = nil

        if let cached = try? await database.cachedAssetUSDPrice(
            assetID: asset.id,
            maximumAge: Self.freshLifetime
        ), Self.cachedPriceIsReusable(cached, for: asset) {
            memory[asset.id] = cached
            return cached
        }

        if let task = inFlight[asset.id] {
            return try await task.value
        }

        let task = Task<AssetUSDPrice, Error> {
            try await Self.fetchPrice(
                for: asset,
                session: session
            )
        }
        inFlight[asset.id] = task

        do {
            let price = try await task.value
            inFlight[asset.id] = nil
            memory[asset.id] = price
            try? await database.saveAssetUSDPrice(price)
            return price
        } catch {
            inFlight[asset.id] = nil
            if let stale = try? await database.cachedAssetUSDPrice(
                assetID: asset.id
            ), Self.cachedPriceIsReusable(stale, for: asset) {
                memory[asset.id] = stale
                return stale
            }
            throw error
        }
    }

    /// Used after newly discovered assets have been inserted into the database.
    func resolvedQuote(assetID: String) -> AssetUSDPrice? {
        guard let quote = memory[assetID],
              Date().timeIntervalSince(quote.observedAt) < Self.freshLifetime else {
            return nil
        }
        return quote
    }

    func clearMemory() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        memory.removeAll()
    }

    /// Returns the token contract, mint, or coin type carried by the canonical
    /// asset identity. Logo metadata is intentionally not consulted: custom
    /// assets can have no image while still being non-native assets.
    static func priceContractAddress(for asset: WalletAsset) -> String? {
        AssetIdentityKey.contractAddress(from: asset.id)
    }

    static func cachedPriceIsReusable(
        _ value: AssetUSDPrice,
        for asset: WalletAsset
    ) -> Bool {
        guard value.assetID == asset.id else { return false }
        guard priceContractAddress(for: asset) != nil else {
            return true
        }
        return exactAssetPriceProviders.contains(value.provider)
    }

    static func cachedPriceIsReusable(
        _ value: DBAssetPriceRecord,
        for asset: DBAssetRecord
    ) -> Bool {
        value.assetID == asset.id && (asset.assetType == DatabaseAssetType.native.rawValue
            || exactAssetPriceProviders.contains(value.provider))
    }

    static func priceProviderCarriesExactAssetIdentity(_ provider: String) -> Bool {
        exactAssetPriceProviders.contains(provider)
    }

    /// The provider market identity resolved from the exact app asset
    /// identity. Exposed internally so the complete supported-network matrix
    /// can be regression tested without making a network request.
    static func coinGeckoMarketID(for asset: WalletAsset) -> String? {
        coinGeckoID(for: asset)
    }

    static func usdPrices(
        for assets: [WalletAsset],
        maximumConcurrentRequests: Int = 6
    ) async -> [String: Decimal] {
        guard !assets.isEmpty else { return [:] }
        let requestLimit = max(
            1,
            min(maximumConcurrentRequests, assets.count)
        )
        return await withTaskGroup(
            of: (String, Decimal?).self,
            returning: [String: Decimal].self
        ) { group in
            var iterator = assets.makeIterator()
            for _ in 0..<requestLimit {
                guard let asset = iterator.next() else { break }
                group.addTask {
                    let quote = try? await AssetPriceClient.shared.usdPrice(
                        for: asset
                    )
                    return (asset.id, quote?.price)
                }
            }

            var prices: [String: Decimal] = [:]
            while let (assetID, price) = await group.next() {
                if let price {
                    prices[assetID] = price
                }
                if let asset = iterator.next() {
                    group.addTask {
                        let quote =
                            try? await AssetPriceClient.shared.usdPrice(
                                for: asset
                            )
                        return (asset.id, quote?.price)
                    }
                }
            }
            return prices
        }
    }
}

extension WalletDatabase {
    func saveAssetUSDPrice(_ value: AssetUSDPrice) async throws {
        try await pool.write { database in
            guard try DBAssetRecord.fetchOne(
                database,
                key: value.assetID
            ) != nil else {
                return
            }
            try DBAssetPriceRecord(
                assetID: value.assetID,
                quoteCurrency: "USD",
                price: NSDecimalNumber(decimal: value.price).stringValue,
                provider: value.provider,
                observedAt: value.observedAt.timeIntervalSince1970,
                expiresAt: value.observedAt.addingTimeInterval(300)
                    .timeIntervalSince1970
            ).insert(database, onConflict: .ignore)
            // An identical cached observation is already durable, but newly
            // imported or refreshed holdings still need its valuation applied.
            try Self.applyAssetUSDPrice(
                value.price,
                assetID: value.assetID,
                database: database
            )
        }
    }

    func cachedAssetUSDPrice(
        assetID: String,
        maximumAge: TimeInterval? = nil
    ) async throws -> AssetUSDPrice? {
        try await pool.read { database in
            guard let record = try Self.latestValidUSDPriceRecord(
                assetID: assetID,
                maximumAge: maximumAge,
                database: database
            ), let price = Decimal(
                string: record.price,
                locale: Locale(identifier: "en_US_POSIX")
            ), price > 0 else {
                return nil
            }
            return AssetUSDPrice(
                assetID: assetID,
                price: price,
                provider: record.provider,
                observedAt: Date(timeIntervalSince1970: record.observedAt)
            )
        }
    }

    /// Returns every non-spam asset that currently needs a wallet valuation,
    /// not only assets attached to an unpriced activity row. Balance providers
    /// publish independently, so a positive holding can legitimately exist
    /// before the separate market-price lane has run.
    func walletAssetsRequiringUSDValuation(
        walletID: String,
        maximumCount: Int = 250
    ) async throws -> [WalletAsset] {
        let limit = max(1, min(maximumCount, 250))
        return try await pool.read { database in
            let accounts = try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
            let accountIDs = accounts.map(\.id)
            guard !accountIDs.isEmpty else { return [] }

            let holdings = try DBAccountAssetRecord
                .filter(accountIDs.contains(Column("accountID")))
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
            let heldAssetIDs = Set<String>(holdings.compactMap { holding in
                guard
                    let canonical = ExactDecimalText.canonicalUnsigned(
                        holding.balance
                    ),
                    canonical != "0"
                else { return nil }
                return holding.assetID
            })
            let unpricedActivityAssetIDs = Set(
                try DBTransactionRecord
                    .filter(accountIDs.contains(Column("accountID")))
                    .filter(Column("fiatUSDValue") == nil)
                    .fetchAll(database)
                    .compactMap(\.assetID)
            )
            let candidateIDs = heldAssetIDs.union(
                unpricedActivityAssetIDs
            )
            guard !candidateIDs.isEmpty else { return [] }

            let assets = try DBAssetRecord
                .filter(candidateIDs.contains(Column("id")))
                .filter(Column("isSpam") == false)
                .fetchAll(database)
                .sorted { lhs, rhs in
                    let lhsHeld = heldAssetIDs.contains(lhs.id)
                    let rhsHeld = heldAssetIDs.contains(rhs.id)
                    if lhsHeld != rhsHeld { return lhsHeld }
                    let lhsNative = lhs.assetType
                        == DatabaseAssetType.native.rawValue
                    let rhsNative = rhs.assetType
                        == DatabaseAssetType.native.rawValue
                    if lhsNative != rhsNative { return lhsNative }
                    return lhs.id < rhs.id
                }
            let networkIDs = Array(Set(assets.map(\.networkID)))
            let networksByID = Dictionary(
                uniqueKeysWithValues: try DBNetworkRecord
                    .filter(networkIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )
            return assets.prefix(limit).compactMap { asset in
                guard
                    let networkRecord = networksByID[asset.networkID],
                    let blockchain = WalletBlockchain(
                        rawValue: networkRecord.trustWalletBlockchain
                    )
                else { return nil }
                return WalletAsset(
                    id: asset.id,
                    name: asset.name,
                    symbol: asset.symbol,
                    logoSource: Self.logoSource(
                        asset: asset,
                        fallbackNetwork: blockchain
                    ),
                    network: blockchain,
                    balance: 0,
                    fiatValue: 0,
                    decimals: asset.decimals,
                    isVerified: asset.isVerified,
                    isSpam: asset.isSpam
                )
            }
        }
    }

    /// Reapplies both fresh and cached exact quotes after a balance snapshot.
    /// This is necessary because an authoritative balance reset deliberately
    /// clears fiat values before the new balances are written.
    func applyAssetUSDPrices(
        _ prices: [String: Decimal]
    ) async throws -> Int {
        let validPrices = prices.filter { $0.value > 0 }
        guard !validPrices.isEmpty else { return 0 }
        return try await pool.write { database in
            var appliedCount = 0
            for (assetID, price) in validPrices.sorted(by: {
                $0.key < $1.key
            }) {
                guard try DBAssetRecord.fetchOne(
                    database,
                    key: assetID
                ) != nil else { continue }
                try Self.applyAssetUSDPrice(
                    price,
                    assetID: assetID,
                    database: database
                )
                appliedCount += 1
            }
            return appliedCount
        }
    }

    func assetsNeedingTransactionUSDPrices(
        walletID: String,
        maximumCount: Int = 100
    ) async throws -> [WalletAsset] {
        let limit = max(1, min(maximumCount, 100))
        let priceCutoff =
            Date().timeIntervalSince1970
            - (24 * 60 * 60)
        return try await pool.read { database in
            let assets = try DBAssetRecord.fetchAll(
                database,
                sql: """
                SELECT assets.*
                FROM assets
                JOIN transactions
                  ON transactions.assetID = assets.id
                JOIN walletAccounts
                  ON walletAccounts.id = transactions.accountID
                WHERE walletAccounts.walletID = ?
                  AND walletAccounts.isEnabled = 1
                  AND transactions.fiatUSDValue IS NULL
                  AND assets.isSpam = 0
                  AND (
                    assets.assetType = 'native'
                    OR assets.isVerified = 1
                  )
                  AND NOT EXISTS (
                    SELECT 1
                    FROM assetPrices
                    WHERE assetPrices.assetID = assets.id
                      AND assetPrices.quoteCurrency = 'USD'
                      AND assetPrices.observedAt >= ?
                  )
                GROUP BY assets.id
                ORDER BY MAX(
                    COALESCE(
                        transactions.timestamp,
                        transactions.firstSeenAt
                    )
                ) DESC
                LIMIT ?
                """,
                arguments: [walletID, priceCutoff, limit]
            )
            guard !assets.isEmpty else { return [] }

            let networkIDs = Array(Set(assets.map(\.networkID)))
            let networksByID = Dictionary(
                uniqueKeysWithValues: try DBNetworkRecord
                    .filter(networkIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )
            return assets.compactMap { asset in
                guard
                    let networkRecord = networksByID[asset.networkID],
                    let blockchain = WalletBlockchain(
                        rawValue: networkRecord.trustWalletBlockchain
                    )
                else {
                    return nil
                }
                return WalletAsset(
                    id: asset.id,
                    name: asset.name,
                    symbol: asset.symbol,
                    logoSource: Self.logoSource(
                        asset: asset,
                        fallbackNetwork: blockchain
                    ),
                    network: blockchain,
                    balance: 0,
                    fiatValue: 0,
                    decimals: asset.decimals,
                    isVerified: asset.isVerified,
                    isSpam: asset.isSpam
                )
            }
        }
    }

    static func applyAssetUSDPrice(
        _ unitPrice: Decimal,
        assetID: String,
        database: Database
    ) throws {
        guard unitPrice > 0,
              let asset = try DBAssetRecord.fetchOne(
                  database,
                  key: assetID
              ) else {
            return
        }

        var holdings = try DBAccountAssetRecord
            .filter(Column("assetID") == assetID)
            .fetchAll(database)
        for index in holdings.indices {
            guard
                let fiatText = transactionUSDValueText(
                    amountText: holdings[index].balance,
                    unitPrice: unitPrice
                )
            else {
                continue
            }
            holdings[index].fiatUSDValue = fiatText
            try holdings[index].update(database)
        }

        var transactions = try DBTransactionRecord
            .filter(Column("assetID") == assetID)
            .filter(Column("fiatUSDValue") == nil)
            .fetchAll(database)
        for index in transactions.indices {
            guard
                let fiatText = transactionUSDValueText(
                    amountText: transactions[index].assetAmount,
                    unitPrice: unitPrice
                )
            else {
                continue
            }
            transactions[index].fiatUSDValue = fiatText
            try transactions[index].update(database)
        }

        var transfers = try DBTransactionTransferRecord
            .filter(Column("assetID") == assetID)
            .filter(Column("fiatUSDValue") == nil)
            .fetchAll(database)
        for index in transfers.indices {
            guard
                let fiatText = transactionUSDValueText(
                    amountText: transfers[index].amount,
                    unitPrice: unitPrice
                )
            else {
                continue
            }
            transfers[index].fiatUSDValue = fiatText
            try transfers[index].update(database)
        }

        guard asset.assetType == DatabaseAssetType.native.rawValue else {
            return
        }
        var feeTransactions = try DBTransactionRecord
            .filter(Column("networkID") == asset.networkID)
            .filter(Column("networkFeeFiatUSDValue") == nil)
            .fetchAll(database)
        for index in feeTransactions.indices {
            guard
                let networkFee = feeTransactions[index].networkFee,
                let fiatText = transactionUSDValueText(
                    amountText: networkFee,
                    unitPrice: unitPrice
                )
            else {
                continue
            }
            feeTransactions[index].networkFeeFiatUSDValue = fiatText
            try feeTransactions[index].update(database)
        }
    }
}

/// Wallet valuation is independent of balance/history synchronization and Markets.
/// Cached quotes are applied first; each fresh result publishes independently.
enum WalletAssetPriceRefresh {
    typealias QuoteProvider = @Sendable (WalletAsset) async throws -> AssetUSDPrice

    static func refresh(
        database: WalletDatabase,
        assets: [WalletAsset],
        quoteProvider: @escaping QuoteProvider = { try await AssetPriceClient.shared.usdPrice(for: $0) },
        onValuation: @escaping @Sendable () async -> Void
    ) async {
        let candidates = Dictionary(assets.filter { !$0.isSpam }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted {
            if ($0.balance > 0) != ($1.balance > 0) { return $0.balance > 0 }
            return $0.id < $1.id
        }
        let cached = (try? await database.pool.read { db in
            try candidates.compactMap { asset -> AssetUSDPrice? in
                guard let row = try WalletDatabase.latestValidUSDPriceRecord(assetID: asset.id, database: db),
                      let price = WalletDatabase.decimal(row.price), price > 0 else { return nil }
                return AssetUSDPrice(assetID: asset.id, price: price, provider: row.provider, observedAt: Date(timeIntervalSince1970: row.observedAt))
            }
        }) ?? []
        guard !Task.isCancelled else { return }
        if !cached.isEmpty {
            _ = try? await database.applyAssetUSDPrices(Dictionary(uniqueKeysWithValues: cached.map { ($0.assetID, $0.price) }))
            await onValuation()
        }
        await withTaskGroup(of: Void.self) { group in
            var iterator = candidates.makeIterator()
            func enqueue(_ asset: WalletAsset) {
                group.addTask {
                    guard !Task.isCancelled else { return }
                    guard let quote = try? await quoteProvider(asset), !Task.isCancelled,
                          quote.price > 0, AssetPriceClient.cachedPriceIsReusable(quote, for: asset) else { return }
                    // Cache hits must value holdings created after the quote was fetched.
                    do { try await database.saveAssetUSDPrice(quote) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    await onValuation()
                }
            }
            for _ in 0..<6 { if let asset = iterator.next() { enqueue(asset) } }
            while await group.next() != nil {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let asset = iterator.next() { enqueue(asset) }
            }
        }
    }
}
