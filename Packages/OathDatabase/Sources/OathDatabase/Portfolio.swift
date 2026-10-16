import Foundation
import GRDB
import OathBitcoin

public struct Holding: Decodable, FetchableRecord, Sendable, Equatable, Identifiable {
    public var id: String { "\(accountID.count):\(accountID)\(assetID)" }
    public let accountID: String
    public let networkID: String
    public let address: String
    public let assetID: String
    public let reference: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let logo: String?
    public let amountAtomic: String?
    public let balanceObservedAt: Double?
    public let usdPrice: String?
    public let exchangeRate: String?
    public let priceObservedAt: Double?
    public let priceSource: String?
    public let transactionCount: Int

    /// Retains an open asset's identity when a receive-path change removes it
    /// from the active portfolio. Old-address quantities must never leak into
    /// the new address's detail screen while its first inventory is loading.
    public func withoutBalance(address: String) -> Holding {
        Holding(accountID: accountID, networkID: networkID, address: address, assetID: assetID,
                reference: reference, name: name, symbol: symbol, decimals: decimals, logo: logo,
                amountAtomic: nil, balanceObservedAt: nil, usdPrice: usdPrice, exchangeRate: exchangeRate,
                priceObservedAt: priceObservedAt, priceSource: priceSource, transactionCount: 0)
    }

    public var sortKey: AssetSortKey {
        AssetSortKey(balanceUSD: usdDisplayValue, transactionCount: transactionCount, name: name,
                     identity: networkID + ":" + reference + ":" + accountID)
    }

    /// The same network registry drives display balances and spending rules.
    /// New Bitcoin-family native assets must not silently display a hardcoded zero.
    public var usesUTXOLedger: Bool { reference == "native" && UTXONetwork(rawValue: networkID) != nil }

    /// Unit price in the snapshot's display currency, derived from USD.
    public var price: String? {
        guard let usdPrice, let exchangeRate,
              let usd = Decimal(string: usdPrice, locale: Locale(identifier: "en_US_POSIX")),
              let rate = Decimal(string: exchangeRate, locale: Locale(identifier: "en_US_POSIX")),
              let result = FiatConversion.multiply(usd, rate) else { return nil }
        return NSDecimalNumber(decimal: result).stringValue
    }

    /// Display calculations only. Signing and balances retain exact atomic strings.
    public var nativeDisplayValue: Decimal? {
        guard let amountAtomic, let amount = try? AtomicAmount(amountAtomic),
              let units = try? amount.units(decimals: decimals) else { return nil }
        return Decimal(string: units, locale: Locale(identifier: "en_US_POSIX"))
    }
    public var usdDisplayValue: Decimal? {
        guard let quantity = nativeDisplayValue else { return nil }
        if quantity == 0 { return 0 }
        guard let usdPrice, let usd = Decimal(string: usdPrice, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return FiatConversion.multiply(quantity, usd)
    }
    public var fiatDisplayValue: Decimal? {
        guard let usdValue = usdDisplayValue else { return nil }
        if usdValue == 0 { return 0 }
        guard let exchangeRate, let rate = Decimal(string: exchangeRate, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return FiatConversion.multiply(usdValue, rate)
    }
}

public struct WalletSnapshot: Sendable, Equatable {
    public let wallet: WalletRecord
    public let accounts: [AccountRecord]
    public let networks: [NetworkRecord]
    public let holdings: [Holding]
    public let settings: [String: String]
    public let assetFilter: PortfolioFilter
    public let currency: String
    public let totalFiat: Decimal
    public let valuationComplete: Bool
    public let accountSync: [AnkrSyncRecord]
}

/// A wallet-list projection of the same valuation used by Home. Keep the
/// currency attached to the amount so a preference change cannot relabel it.
public struct WalletValuation: Sendable, Equatable, Identifiable {
    public let id: String
    public let currency: String
    public let totalFiat: Decimal
    public let valuationComplete: Bool

    public init(snapshot: WalletSnapshot) {
        id = snapshot.wallet.id
        currency = snapshot.currency
        totalFiat = snapshot.totalFiat
        valuationComplete = snapshot.valuationComplete
    }
}

extension OathDatabase {
    public func walletValuations(walletIDs: Set<String>, currency: String) async throws -> [WalletValuation] {
        try await pool.read { try Self.walletValuations($0, walletIDs: walletIDs, currency: currency) }
    }

    /// One consistent database read, off the main thread. Callers observe only
    /// while the wallet list is visible, and supply vault-authorized membership.
    public func observeWalletValuations(walletIDs: Set<String>, currency: String) -> AsyncThrowingStream<[WalletValuation], Error> {
        stream { try Self.walletValuations($0, walletIDs: walletIDs, currency: currency) }
    }

    private static func walletValuations(_ db: Database, walletIDs: Set<String>, currency: String) throws -> [WalletValuation] {
        guard !walletIDs.isEmpty else { return [] }
        let ids = try String.fetchAll(db, sql: "SELECT id FROM wallets WHERE deletedAt IS NULL ORDER BY sortOrder, createdAt, id")
        return try ids.filter { walletIDs.contains($0) }.map {
            WalletValuation(snapshot: try snapshot(db, walletID: $0, currency: currency))
        }
    }

    public func snapshot(walletID: String, currency: String) async throws -> WalletSnapshot {
        try await pool.read { try Self.snapshot($0, walletID: walletID, currency: currency) }
    }
    public func observeWallet(walletID: String, currency: String) -> AsyncThrowingStream<WalletSnapshot, Error> {
        stream { try Self.snapshot($0, walletID: walletID, currency: currency) }
    }
    static func snapshot(_ db: Database, walletID: String, currency: String) throws -> WalletSnapshot {
        guard let wallet = try WalletRecord.fetchOne(db, key: walletID) else { throw StoreError.missingRecord }
        let settings = try settings(db)
        let assetFilter = try portfolioFilter(db, walletID: walletID)
        let quoteCurrency = settings["currency"] ?? currency
        try Validation.currency(quoteCurrency)
        let rows = try Holding.fetchAll(db, sql: """
            WITH visibility(hidesUnverified) AS (VALUES (?)),
            walletAccounts AS (SELECT * FROM accounts WHERE walletID=?), effectiveBalances AS (
                SELECT b.* FROM balances b JOIN walletAccounts ac ON ac.id=b.accountID WHERE ac.networkID NOT IN ('solana','tron')
                AND NOT (ac.networkID='ton' AND EXISTS(SELECT 1 FROM tonHoldings th WHERE th.accountID=b.accountID AND th.assetID=b.assetID))
                AND NOT (ac.networkID='aptos' AND EXISTS(SELECT 1 FROM aptosHoldings th WHERE th.accountID=b.accountID AND th.assetID=b.assetID))
                AND NOT (ac.networkID='sui' AND EXISTS(SELECT 1 FROM suiHoldings th WHERE th.accountID=b.accountID AND th.assetID=b.assetID))
                AND NOT (ac.networkID='near' AND EXISTS(SELECT 1 FROM nearHoldings th WHERE th.accountID=b.accountID AND th.assetID=b.assetID))
                AND NOT (ac.networkID='xrpl' AND EXISTS(SELECT 1 FROM xrplHoldings th WHERE th.accountID=b.accountID AND th.assetID=b.assetID))
                AND NOT (ac.networkID='arc' AND EXISTS(SELECT 1 FROM arcHoldings ah WHERE ah.accountID=b.accountID AND ah.assetID=b.assetID))
                AND NOT (ac.networkID='robinhood' AND EXISTS(SELECT 1 FROM robinhoodHoldings rh WHERE rh.accountID=b.accountID AND rh.assetID=b.assetID))
                AND NOT (ac.networkID='hyperevm' AND EXISTS(SELECT 1 FROM hyperevmHoldings rh WHERE rh.accountID=b.accountID AND rh.assetID=b.assetID))
                AND NOT (ac.networkID IN ('unichain','monad') AND EXISTS(SELECT 1 FROM indexedEVMHoldings rh WHERE rh.accountID=b.accountID AND rh.assetID=b.assetID))
                AND NOT (ac.networkID='stellar' AND EXISTS(SELECT 1 FROM stellarHoldings th WHERE th.accountID=b.accountID AND th.assetID=b.assetID))
                UNION ALL
                SELECT h.accountID,h.assetID,'solana' AS networkID,h.amountAtomic,h.observedAt,h.slot AS blockHeight,'solana' AS source
                FROM solanaHoldings h JOIN walletAccounts ac ON ac.id=h.accountID
                WHERE h.owner=COALESCE((SELECT address FROM solanaReceiveAddresses WHERE accountID=ac.id AND isSelected=1),ac.address)
                AND ((SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID))
                UNION ALL
                SELECT h.accountID,h.assetID,'tron',h.amountAtomic,h.observedAt,NULL,'tron'
                FROM tronHoldings h
                WHERE h.accountID IN (SELECT id FROM walletAccounts) AND ((SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID))
                UNION ALL
                SELECT h.accountID,h.assetID,'ton',h.amountAtomic,h.observedAt,NULL,'ton'
                FROM tonHoldings h
                WHERE h.accountID IN (SELECT id FROM walletAccounts) AND ((SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID))
                UNION ALL
                SELECT h.accountID,h.assetID,'aptos',h.amountAtomic,h.observedAt,NULL,'aptos'
                FROM aptosHoldings h
                WHERE h.accountID IN (SELECT id FROM walletAccounts) AND ((SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID))
                UNION ALL
                SELECT h.accountID,h.assetID,'sui',h.amountAtomic,h.observedAt,NULL,'sui'
                FROM suiHoldings h
                WHERE h.accountID IN (SELECT id FROM walletAccounts) AND ((SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID))
                UNION ALL
                SELECT h.accountID,h.assetID,'near',h.amountAtomic,h.observedAt,h.blockHeight,'near'
                FROM nearHoldings h
                WHERE h.accountID IN (SELECT id FROM walletAccounts) AND (h.amountAtomic IS NOT NULL AND ((SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID)))
                UNION ALL
                SELECT h.accountID,h.assetID,'xrpl',h.amountAtomic,h.observedAt,h.checkpoint,'xrpl'
                FROM xrplHoldings h
                WHERE h.accountID IN (SELECT id FROM walletAccounts) AND ((SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID))
                UNION ALL
                SELECT h.accountID,h.assetID,'stellar',h.amountAtomic,h.observedAt,h.checkpoint,'stellar'
                FROM stellarHoldings h
                WHERE h.accountID IN (SELECT id FROM walletAccounts) AND ((SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID))
                UNION ALL
                SELECT h.accountID,h.assetID,'arc',h.amountAtomic,h.observedAt,h.checkpoint,'arc'
                FROM arcHoldings h
                WHERE h.accountID IN (SELECT id FROM walletAccounts) AND ((SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID))
                UNION ALL
                SELECT h.accountID,h.assetID,'robinhood',h.amountAtomic,h.observedAt,h.checkpoint,'robinhood'
                FROM robinhoodHoldings h
                WHERE h.accountID IN (SELECT id FROM walletAccounts) AND ((SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID))
                UNION ALL
                SELECT h.accountID,h.assetID,'hyperevm',h.amountAtomic,h.observedAt,h.checkpoint,'hyperevm'
                FROM hyperevmHoldings h
                WHERE h.accountID IN (SELECT id FROM walletAccounts) AND ((SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID))
                UNION ALL
                SELECT h.accountID,h.assetID,ac.networkID,h.amountAtomic,h.observedAt,h.checkpoint,'indexedEVM'
                FROM indexedEVMHoldings h JOIN walletAccounts ac ON ac.id=h.accountID
                WHERE (SELECT hidesUnverified FROM visibility)=0 OR h.verified=1 OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=h.accountID AND tr.assetID=h.assetID)
            ), walletAssets AS (
                SELECT c.id AS accountID,a.id AS assetID FROM accounts c
                JOIN assets a ON a.networkID=c.networkID AND a.reference='native' WHERE c.walletID=?
                UNION
                SELECT b.accountID,b.assetID FROM accounts c JOIN effectiveBalances b ON b.accountID=c.id
                JOIN assets a ON a.id=b.assetID AND a.reference<>'native' WHERE c.walletID=?
                AND ((SELECT hidesUnverified FROM visibility)=0 OR b.source<>'ankr' OR EXISTS (
                    SELECT 1 FROM ankrAssets verified WHERE verified.accountID=b.accountID
                    AND verified.assetID=b.assetID AND verified.onlyWhitelisted=1))
                UNION
                SELECT t.accountID,t.assetID FROM accounts c JOIN trackedAssets t ON t.accountID=c.id
                WHERE c.walletID=?
            ), walletTransactions AS (
                SELECT h.accountID,h.assetID,t.hash AS transactionHash
                FROM visibleActivity h JOIN transactions t ON t.id=h.transactionID WHERE h.walletID=?
                AND (h.networkID<>'solana' OR EXISTS (SELECT 1 FROM solanaActivity sa
                    JOIN accounts ownerAccount ON ownerAccount.id=h.accountID
                    WHERE sa.activityID=h.id AND sa.owner=COALESCE((SELECT address FROM solanaReceiveAddresses
                        WHERE accountID=h.accountID AND isSelected=1),ownerAccount.address)))
                UNION
                SELECT h.accountID,a.id,h.txid FROM bitcoinHistory h
                JOIN accounts c ON c.id=h.accountID
                JOIN assets a ON a.networkID=c.networkID AND a.reference='native' WHERE c.walletID=?
            ), transactionCounts AS (
                SELECT accountID,assetID,COUNT(*) AS count FROM walletTransactions GROUP BY accountID,assetID
            )
            SELECT c.id AS accountID,c.networkID,CASE WHEN c.networkID='solana' THEN
                   COALESCE((SELECT address FROM solanaReceiveAddresses WHERE accountID=c.id AND isSelected=1),c.address)
                   ELSE c.address END AS address,a.id AS assetID,a.reference,a.name,a.symbol,a.decimals,a.logo,
                   b.amountAtomic,b.observedAt AS balanceObservedAt,p.value AS usdPrice,p.observedAt AS priceObservedAt,p.source AS priceSource,
                   COALESCE(tc.count,0) AS transactionCount,
                   CASE WHEN ?='USD' THEN '1' ELSE fx.unitsPerUSD END AS exchangeRate
            FROM walletAssets v JOIN accounts c ON c.id=v.accountID JOIN networks n ON n.id=c.networkID
            JOIN assets a ON a.id=v.assetID
            LEFT JOIN effectiveBalances b ON b.accountID=c.id AND b.assetID=a.id
                AND ((SELECT hidesUnverified FROM visibility)=0 OR b.source<>'ankr' OR a.reference='native' OR EXISTS (
                    SELECT 1 FROM ankrAssets verified WHERE verified.accountID=b.accountID
                    AND verified.assetID=b.assetID AND verified.onlyWhitelisted=1))
            LEFT JOIN prices p ON p.assetID=a.id AND p.currency='USD' AND p.observedAt=(
                SELECT MAX(observedAt) FROM prices WHERE assetID=a.id AND currency='USD')
            LEFT JOIN exchangeRates fx ON fx.currency=?
            LEFT JOIN transactionCounts tc ON tc.accountID=c.id AND tc.assetID=a.id
            WHERE n.enabled=1
            """, arguments: [assetFilter.hidesUnverifiedTokens, walletID, walletID, walletID, walletID, walletID, walletID, quoteCurrency, quoteCurrency])
        let holdings = AssetOrdering.sorted(rows, by: \.sortKey)
        var total: Decimal = 0
        var complete = true
        for holding in holdings {
            if let value = holding.fiatDisplayValue { total += value }
            else if holding.amountAtomic != "0" { complete = false }
        }
        let networkRows = try NetworkRecord.fetchAll(db, sql: """
            SELECT * FROM networks WHERE id IN (SELECT networkID FROM accounts WHERE walletID=?)
            """, arguments: [walletID])
        let order = PortfolioAssetOrder(holdings)
        let networks = AssetOrdering.sorted(networkRows) { order.key(networkID: $0.id, name: $0.name) }
        let accountSync = try AnkrSyncRecord.fetchAll(db, sql: """
            SELECT s.* FROM ankrSync s JOIN accounts a ON a.id=s.accountID WHERE a.walletID=? ORDER BY s.accountID,s.stream
            """, arguments: [walletID])
        return WalletSnapshot(wallet: wallet, accounts: try accounts(db, walletID: walletID), networks: networks,
                              holdings: holdings, settings: settings, assetFilter: assetFilter, currency: quoteCurrency,
                              totalFiat: total.isNaN ? 0 : total, valuationComplete: complete && !total.isNaN, accountSync: accountSync)
    }
}
