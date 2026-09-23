import Foundation
import GRDB

struct WalletHomePortfolioSnapshotSlice: Sendable {
    let totalBalance: Decimal
    let assets: [WalletAsset]
}

struct WalletHomeActivitySnapshotSlice: Sendable {
    let transactions: [WalletTransaction]
    let hasStoredActivity: Bool
}

extension WalletDatabase {
    func cachedWalletPortfolioSlice(
        walletID: String
    ) async throws -> WalletHomePortfolioSnapshotSlice? {
        try await pool.read { database in
            let accounts = try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
            guard !accounts.isEmpty else { return nil }

            let accountByID = Dictionary(
                uniqueKeysWithValues: accounts.map { ($0.id, $0) }
            )
            let accountIDs = Array(accountByID.keys)
            let persistedHoldings = try DBAccountAssetRecord
                .filter(accountIDs.contains(Column("accountID")))
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
            let holdings = WalletHomeHoldingProjection.unifiedHoldings(
                persistedHoldings,
                accountByID: accountByID
            ).filter { !$0.isHidden }

            let assetIDs = Array(Set(holdings.map(\.assetID)))
            let assets = assetIDs.isEmpty
                ? []
                : try DBAssetRecord
                    .filter(assetIDs.contains(Column("id")))
                    .fetchAll(database)
            let assetsByID = Dictionary(
                uniqueKeysWithValues: assets.map { ($0.id, $0) }
            )
            let networkIDs = Array(
                Set(accounts.map(\.networkID) + assets.map(\.networkID))
            )
            let networkByID = Dictionary(
                uniqueKeysWithValues: try DBNetworkRecord
                    .filter(networkIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )

            let walletAssets = holdings.compactMap {
                holding -> WalletAsset? in
                guard let asset = assetsByID[holding.assetID],
                      let account = accountByID[holding.accountID],
                      let networkRecord = networkByID[asset.networkID],
                      let network = WalletBlockchain(
                          rawValue: networkRecord.trustWalletBlockchain
                      ),
                      let exactBalance = ExactDecimalText.canonicalUnsigned(
                          holding.balance
                      ),
                      let fiatValue = Self.decimal(
                          (try? Self.cachedFiatUSDValue(amountText: holding.balance, assetID: holding.assetID, fallback: holding.fiatUSDValue, database: database)) ?? holding.fiatUSDValue ?? "0"
                      ) else {
                    return nil
                }
                return WalletAsset(
                    id: asset.id,
                    name: asset.name,
                    symbol: asset.symbol,
                    logoSource: Self.logoSource(
                        asset: asset,
                        fallbackNetwork: network
                    ),
                    network: network,
                    balance: Self.decimal(exactBalance) ?? 0,
                    fiatValue: fiatValue,
                    balanceText: exactBalance,
                    balanceAtomic: holding.balanceAtomic,
                    decimals: asset.decimals,
                    receiveAddress: account.address,
                    isPinned: holding.isPinned,
                    isVerified: asset.isVerified,
                    isSpam: asset.isSpam
                )
            }
            .sorted {
                if $0.fiatValue == $1.fiatValue {
                    return $0.symbol < $1.symbol
                }
                return $0.fiatValue > $1.fiatValue
            }

            return WalletHomePortfolioSnapshotSlice(
                totalBalance: walletAssets.reduce(0) {
                    $0 + (
                        $1.isSpam || $1.requiresExplicitVisibility
                            ? 0 : $1.fiatValue
                    )
                },
                assets: walletAssets
            )
        }
    }

    func cachedWalletActivitySlice(
        walletID: String
    ) async throws -> WalletHomeActivitySnapshotSlice? {
        try await pool.read { database in
            let accounts = try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
            guard !accounts.isEmpty else { return nil }

            let accountIDs = accounts.map(\.id)
            let hasStoredActivity = try Self.hasStoredActivity(
                accountIDs: accountIDs,
                database: database
            )
            let transactions = try Self.cachedDisplayEligibleTransactions(
                accountIDs: accountIDs,
                database: database
            )
            let transactionIDs = transactions.map(\.id)
            let notes = transactionIDs.isEmpty
                ? []
                : try DBTransactionNoteRecord
                    .filter(
                        transactionIDs.contains(Column("transactionID"))
                    )
                    .fetchAll(database)
            let notesByTransactionID = Dictionary(
                uniqueKeysWithValues: notes.map {
                    ($0.transactionID, $0.note)
                }
            )
            let primaryTransfers = transactionIDs.isEmpty
                ? []
                : try DBTransactionTransferRecord
                    .filter(
                        transactionIDs.contains(Column("transactionID"))
                    )
                    .fetchAll(database)
            let primaryTransferByTransactionID = Dictionary(
                uniqueKeysWithValues: primaryTransfers.compactMap {
                    transfer
                        -> (String, DBTransactionTransferRecord)? in
                    transfer.id == "\(transfer.transactionID)|primary"
                        ? (transfer.transactionID, transfer) : nil
                }
            )
            let assetIDs = Array(Set(transactions.compactMap(\.assetID)))
            let assets = assetIDs.isEmpty
                ? []
                : try DBAssetRecord
                    .filter(assetIDs.contains(Column("id")))
                    .fetchAll(database)
            let assetsByID = Dictionary(
                uniqueKeysWithValues: assets.map { ($0.id, $0) }
            )
            let networkIDs = Array(
                Set(accounts.map(\.networkID) + transactions.map(\.networkID))
            )
            let networkByID = Dictionary(
                uniqueKeysWithValues: try DBNetworkRecord
                    .filter(networkIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )
            let walletTransactions = transactions.compactMap {
                transaction -> WalletTransaction? in
                guard Self.isDisplayEligibleTransaction(
                    transaction,
                    assetsByID: assetsByID
                ) else {
                    return nil
                }
                return Self.walletTransaction(
                    transaction,
                    assetsByID: assetsByID,
                    networkByID: networkByID,
                    localNote: notesByTransactionID[transaction.id],
                    primaryTransfer:
                        primaryTransferByTransactionID[transaction.id]
                )
            }
            return WalletHomeActivitySnapshotSlice(
                transactions: walletTransactions,
                hasStoredActivity: hasStoredActivity
            )
        }
    }
}
