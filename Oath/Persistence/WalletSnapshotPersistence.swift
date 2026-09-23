import Foundation
import GRDB

private struct WalletSnapshotHoldingKey: Hashable {
    let accountID: String
    let assetID: String
}

extension WalletDatabase {
    func saveWalletSnapshot(
        _ snapshot: WalletHomeSnapshot,
        address: String,
        trackedTokenBalances: TrackedEVMTokenBalanceBatch = .empty
    ) async throws {
        guard
            let authority = snapshot.evmBalanceAuthority,
            authority.isAuthoritative,
            authority.mappedAssetCount == snapshot.assets.count
        else {
            throw WalletSnapshotPersistenceError.unverifiedBalanceSnapshot
        }
        let normalizedAddress = Self.normalizedAddress(address)
        guard AnkrAPIClient.isValidAddress(normalizedAddress) else {
            throw AnkrAPIError.invalidWalletAddress
        }
        let trackedUpdateIDs = trackedTokenBalances.updates.map(
            \.holdingID
        )
        guard
            Set(trackedUpdateIDs).count == trackedUpdateIDs.count,
            Set(trackedUpdateIDs).isDisjoint(
                with: trackedTokenBalances.failedHoldingIDs
            )
        else {
            throw WalletSnapshotPersistenceError
                .invalidTrackedTokenBalance
        }

        _ = try await pool.write { database in
            let now = Date().timeIntervalSince1970
            let context = try Self.registeredWalletAndAccounts(
                address: address,
                normalizedAddress: normalizedAddress,
                database: database
            )
            let evmAccountsByNetwork = context.accountsByNetwork.filter {
                AnkrAPIClient.supportsTokenLookup(networkID: $0.key)
            }
            let evmAccounts = Array(evmAccountsByNetwork.values)
            let evmAccountIDs = evmAccounts.map(\.id)
            let providerAuthoritativeNetworkIDs =
                authority.authoritativeNetworkIDs
                    ?? Set(evmAccountsByNetwork.keys)
            let authoritativeNetworkIDs = providerAuthoritativeNetworkIDs
                .intersection(evmAccountsByNetwork.keys)
            let resolvedSnapshotNetworkIDs = snapshot.assets.compactMap {
                Self.networkID(for: $0.network)
            }
            let snapshotNetworkIDs = Set(resolvedSnapshotNetworkIDs)
            guard
                !authoritativeNetworkIDs.isEmpty,
                resolvedSnapshotNetworkIDs.count == snapshot.assets.count,
                snapshotNetworkIDs.isSubset(
                    of: providerAuthoritativeNetworkIDs
                )
            else {
                throw WalletSnapshotPersistenceError
                    .unverifiedBalanceSnapshot
            }
            let authoritativeAccountIDs = authoritativeNetworkIDs
                .compactMap { evmAccountsByNetwork[$0]?.id }

            let resetRowCount = try DBAccountAssetRecord
                .filter(
                    authoritativeAccountIDs.contains(
                        Column("accountID")
                    )
                )
                .filter(Column("isPinned") == false)
                .updateAll(
                    database,
                    Column("balance").set(to: "0"),
                    Column("balanceAtomic").set(to: "0"),
                    Column("fiatUSDValue").set(to: "0"),
                    Column("updatedAt").set(to: now)
                )

            let assetIDs = Set(
                snapshot.assets.compactMap { asset -> String? in
                    guard let networkID = Self.networkID(for: asset.network)
                    else {
                        return nil
                    }
                    return Self.assetIdentity(
                        logoSource: asset.logoSource,
                        networkID: networkID,
                        fallbackContractAddress:
                            Self.contractAddress(from: asset.id)
                    ).id
                }
                + snapshot.persistenceTransactions.compactMap {
                    transaction -> String? in
                    guard
                        let networkID = Self.transactionNetworkID(transaction)
                    else {
                        return nil
                    }
                    return Self.assetIdentity(
                        logoSource: transaction.assetLogoSource,
                        networkID: networkID,
                        fallbackContractAddress:
                            transaction.metadata.contractAddress
                    ).id
                }
                + trackedTokenBalances.updates.map {
                    $0.holdingID.assetID
                }
            )
            let existingAssetsByID = Dictionary(
                uniqueKeysWithValues: try DBAssetRecord
                    .filter(assetIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )
            let existingHoldingsByKey = Dictionary(
                uniqueKeysWithValues: try DBAccountAssetRecord
                    .filter(evmAccountIDs.contains(Column("accountID")))
                    .filter(assetIDs.contains(Column("assetID")))
                    .fetchAll(database)
                    .map {
                        (
                            WalletSnapshotHoldingKey(
                                accountID: $0.accountID,
                                assetID: $0.assetID
                            ),
                            $0
                        )
                    }
            )
            let transactionIDs = snapshot.persistenceTransactions.compactMap {
                transaction -> String? in
                guard
                    let networkID = Self.transactionNetworkID(transaction)
                else {
                    return nil
                }
                return Self.transactionRecordID(
                    transaction,
                    walletAddress: normalizedAddress,
                    networkID: networkID
                )
            }
            var existingTransactionsByID = Dictionary(
                uniqueKeysWithValues: try DBTransactionRecord
                    .filter(transactionIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )

            var persistedAssetsByID = existingAssetsByID
            var writtenAssetCount = 0
            for (index, asset) in snapshot.assets.enumerated() {
                guard
                    let networkID = Self.networkID(for: asset.network),
                    let account = context.accountsByNetwork[networkID]
                else {
                    continue
                }

                let assetRecord = try Self.upsertAsset(
                    asset,
                    networkID: networkID,
                    existing: existingAssetsByID[
                        Self.assetIdentity(
                            logoSource: asset.logoSource,
                            networkID: networkID,
                            fallbackContractAddress:
                                Self.contractAddress(from: asset.id)
                        ).id
                    ],
                    now: now,
                    database: database
                )
                persistedAssetsByID[assetRecord.id] = assetRecord

                let existing = existingHoldingsByKey[
                    WalletSnapshotHoldingKey(
                        accountID: account.id,
                        assetID: assetRecord.id
                    )
                ]
                let persistedBalance = Self.providerBalanceText(
                    asset.balanceText,
                    matching: asset.balance
                )
                let providerFiatUSDValue = Self.storageString(
                    asset.fiatValue
                )
                let persistedFiatUSDValue = if assetRecord.assetType == DatabaseAssetType.native.rawValue && asset.fiatValue > 0 {
                    providerFiatUSDValue
                } else {
                    try Self.cachedFiatUSDValue(
                        amountText: persistedBalance,
                        assetID: assetRecord.id,
                        fallback: assetRecord.assetType == DatabaseAssetType.native.rawValue ? providerFiatUSDValue : nil,
                        database: database
                    ) ?? "0"
                }
                try DBAccountAssetRecord(
                    accountID: account.id,
                    assetID: assetRecord.id,
                    balance: persistedBalance,
                    balanceAtomic: Self.providerAtomicBalance(
                        asset.balanceAtomic
                    ),
                    fiatUSDValue: persistedFiatUSDValue,
                    isEnabled: existing?.isEnabled ?? true,
                    isPinned: existing?.isPinned ?? false,
                    isHidden: existing?.isHidden ?? false,
                    sortOrder: existing?.sortOrder ?? index,
                    firstSeenAt: existing?.firstSeenAt ?? now,
                    lastSeenAt: now,
                    updatedAt: now
                ).save(database)
                writtenAssetCount += 1

                if asset.balance != 0 {
                    let price = Self.magnitude(asset.fiatValue / asset.balance)
                    if price > 0 {
                        try DBAssetPriceRecord(
                            assetID: assetRecord.id,
                            quoteCurrency: "USD",
                            price: Self.storageString(price),
                            provider: "ankr",
                            observedAt: now,
                            expiresAt: now + 300
                        ).insert(database)
                        try Self.applyAssetUSDPrice(
                            price,
                            assetID: assetRecord.id,
                            database: database
                        )
                    }
                }
            }

            for update in trackedTokenBalances.updates {
                guard
                    var holding = existingHoldingsByKey[
                        WalletSnapshotHoldingKey(
                            accountID: update.holdingID.accountID,
                            assetID: update.holdingID.assetID
                        )
                    ],
                    holding.isPinned,
                    holding.isEnabled,
                    let asset = persistedAssetsByID[
                        update.holdingID.assetID
                    ],
                    asset.assetType
                        == DatabaseAssetType.fungibleToken.rawValue,
                    let account = context.accountsByNetwork[
                        asset.networkID
                    ],
                    account.id == update.holdingID.accountID,
                    Self.normalizedTokenContract(
                        asset.normalizedContractAddress
                    ) != nil
                else {
                    throw WalletSnapshotPersistenceError
                        .invalidTrackedTokenBalance
                }

                let retainedFiatValue = holding.fiatUSDValue ?? "0"
                let balanceWasUnchanged =
                    holding.balanceAtomic == update.balanceAtomic
                        || (
                            holding.balanceAtomic == nil
                                && holding.balance == update.balanceText
                        )
                let latestPrice = try Self.latestValidUSDPriceRecord(
                    assetID: asset.id,
                    database: database
                )
                let cachedUnitPrice = latestPrice.flatMap {
                    priceRecord -> Decimal? in
                    guard
                        let price = Self.decimal(priceRecord.price),
                        price > 0
                    else {
                        return nil
                    }
                    return price
                }
                let fiatUSDValue = cachedUnitPrice.flatMap {
                    Self.transactionUSDValueText(
                        amountText: update.balanceText,
                        unitPrice: $0
                    )
                } ?? (balanceWasUnchanged ? retainedFiatValue : "0")

                holding.balance = update.balanceText
                holding.balanceAtomic = update.balanceAtomic
                holding.fiatUSDValue = fiatUSDValue
                holding.lastSeenAt = now
                holding.updatedAt = now
                try holding.save(database)
            }

            var writtenTransactionCount = 0
            for transaction in snapshot.persistenceTransactions {
                try Self.upsertTransaction(
                    transaction,
                    walletAddress: normalizedAddress,
                    accountsByNetwork: context.accountsByNetwork,
                    persistedAssetsByID: &persistedAssetsByID,
                    existingTransactionsByID: &existingTransactionsByID,
                    now: now,
                    database: database
                )
                writtenTransactionCount += 1
            }

            let synchronizedAccountIDs = Set(authoritativeAccountIDs)
                .union(trackedTokenBalances.updates.map {
                    $0.holdingID.accountID
                })
            try DBWalletAccountRecord
                .filter(Array(synchronizedAccountIDs).contains(Column("id")))
                .updateAll(
                    database,
                    Column("lastSyncedAt").set(to: now),
                    Column("updatedAt").set(to: now)
                )
            for account in evmAccounts {
                try Self.pruneActivity(
                    accountID: account.id,
                    database: database
                )
            }
            try Self.pruneCaches(now: now, database: database)
            return (
                resetRows: resetRowCount,
                writtenAssets: writtenAssetCount,
                writtenTransactions: writtenTransactionCount
            )
        }
    }

    /// Merges one directly queried EVM asset without resetting the other
    /// holdings on that network. The full-wallet writer above intentionally
    /// reconciles an authoritative inventory; an asset-details read is only
    /// authoritative for its selected native coin or token contract.
    func saveEVMAssetDetailsSnapshot(
        _ snapshot: WalletHomeSnapshot,
        walletID: String
    ) async throws {
        guard snapshot.assets.count == 1,
              let selectedAsset = snapshot.assets.first,
              let networkID = Self.networkID(for: selectedAsset.network),
              AnkrAPIClient.supportsTokenLookup(networkID: networkID),
              let authority = snapshot.evmBalanceAuthority,
              authority.isAuthoritative,
              authority.providerAssetCount == 1,
              authority.mappedAssetCount == 1,
              authority.authoritativeNetworkIDs == [networkID]
        else {
            throw WalletSnapshotPersistenceError.unverifiedBalanceSnapshot
        }

        try await pool.write { database in
            guard let wallet = try DBWalletRecord
                .filter(Column("id") == walletID)
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database),
                  let account = try DBWalletAccountRecord
                    .filter(Column("walletID") == wallet.id)
                    .filter(Column("networkID") == networkID)
                    .filter(Column("isEnabled") == true)
                    .fetchOne(database)
            else {
                throw WalletSnapshotPersistenceError
                    .selectedWalletUnavailable
            }

            let normalizedAddress = Self.normalizedAddress(account.address)
            guard AnkrAPIClient.isValidAddress(normalizedAddress) else {
                throw WalletSnapshotPersistenceError
                    .addressDoesNotBelongToSelectedWallet
            }
            let now = Date().timeIntervalSince1970
            let identity = Self.assetIdentity(
                logoSource: selectedAsset.logoSource,
                networkID: networkID,
                fallbackContractAddress:
                    Self.contractAddress(from: selectedAsset.id)
            )
            let existingAsset = try DBAssetRecord.fetchOne(
                database,
                key: identity.id
            )
            let assetRecord = try Self.upsertAsset(
                selectedAsset,
                networkID: networkID,
                existing: existingAsset,
                now: now,
                database: database
            )
            let existingHolding = try DBAccountAssetRecord.fetchOne(
                database,
                key: [
                    "accountID": account.id,
                    "assetID": assetRecord.id
                ]
            )
            let balanceText = Self.providerBalanceText(
                selectedAsset.balanceText,
                matching: selectedAsset.balance
            )
            let providerFiatValue = Self.storageString(
                selectedAsset.fiatValue
            )
            let fiatValue = if selectedAsset.fiatValue > 0 {
                providerFiatValue
            } else {
                try Self.cachedFiatUSDValue(
                    amountText: balanceText,
                    assetID: assetRecord.id,
                    fallback: providerFiatValue,
                    database: database
                ) ?? providerFiatValue
            }
            try DBAccountAssetRecord(
                accountID: account.id,
                assetID: assetRecord.id,
                balance: balanceText,
                balanceAtomic: Self.providerAtomicBalance(
                    selectedAsset.balanceAtomic
                ),
                fiatUSDValue: fiatValue,
                isEnabled: existingHolding?.isEnabled ?? true,
                isPinned: existingHolding?.isPinned ?? selectedAsset.isPinned,
                isHidden: existingHolding?.isHidden ?? false,
                sortOrder: existingHolding?.sortOrder,
                firstSeenAt: existingHolding?.firstSeenAt ?? now,
                lastSeenAt: now,
                updatedAt: now
            ).save(database)

            if selectedAsset.balance != 0 {
                let unitPrice = Self.magnitude(
                    selectedAsset.fiatValue / selectedAsset.balance
                )
                if unitPrice > 0 {
                    try DBAssetPriceRecord(
                        assetID: assetRecord.id,
                        quoteCurrency: "USD",
                        price: Self.storageString(unitPrice),
                        provider: "asset_details",
                        observedAt: now,
                        expiresAt: now + 300
                    ).save(database)
                    try Self.applyAssetUSDPrice(
                        unitPrice,
                        assetID: assetRecord.id,
                        database: database
                    )
                }
            }

            let transactions = snapshot.persistenceTransactions.filter {
                WalletAssetDetailsSelection.matches($0, asset: selectedAsset)
            }
            let transactionIDs = transactions.map {
                Self.transactionRecordID(
                    $0,
                    walletAddress: normalizedAddress,
                    networkID: networkID
                )
            }
            var existingTransactionsByID = Dictionary(
                uniqueKeysWithValues: try DBTransactionRecord
                    .filter(transactionIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )
            var persistedAssetsByID = [assetRecord.id: assetRecord]
            for transaction in transactions {
                try Self.upsertTransaction(
                    transaction,
                    walletAddress: normalizedAddress,
                    accountsByNetwork: [networkID: account],
                    persistedAssetsByID: &persistedAssetsByID,
                    existingTransactionsByID: &existingTransactionsByID,
                    now: now,
                    database: database
                )
            }

            try DBWalletAccountRecord
                .filter(Column("id") == account.id)
                .updateAll(
                    database,
                    Column("lastSyncedAt").set(to: now),
                    Column("updatedAt").set(to: now)
                )
            try Self.pruneActivity(
                accountID: account.id,
                database: database
            )
            try Self.pruneCaches(now: now, database: database)
        }
    }

    func cachedWalletSnapshot(
        address: String
    ) async throws -> WalletHomeSnapshot? {
        let normalizedAddress = Self.normalizedAddress(address)
        return try await pool.read {
            database -> WalletHomeSnapshot? in
            let accounts = try DBWalletAccountRecord
                .filter(Column("normalizedAddress") == normalizedAddress)
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
            guard !accounts.isEmpty else { return nil }

            let accountIDs = accounts.map(\.id)
            let hasStoredActivity = try Self.hasStoredActivity(
                accountIDs: accountIDs,
                database: database
            )
            let holdings = try DBAccountAssetRecord
                .filter(accountIDs.contains(Column("accountID")))
                .filter(Column("isEnabled") == true)
                .filter(Column("isHidden") == false)
                .fetchAll(database)
            let transactions = try Self.cachedDisplayEligibleTransactions(
                accountIDs: accountIDs,
                database: database
            )
            let transactionIDs = transactions.map(\.id)
            let transactionNotes =
                transactionIDs.isEmpty
                    ? []
                    : try DBTransactionNoteRecord
                        .filter(
                            transactionIDs.contains(
                                Column("transactionID")
                            )
                        )
                        .fetchAll(database)
            let notesByTransactionID = Dictionary(
                uniqueKeysWithValues: transactionNotes.map {
                    ($0.transactionID, $0.note)
                }
            )
            let primaryTransfers =
                transactionIDs.isEmpty
                    ? []
                    : try DBTransactionTransferRecord
                        .filter(
                            transactionIDs.contains(
                                Column("transactionID")
                            )
                        )
                        .fetchAll(database)
            let primaryTransferByTransactionID = Dictionary(
                uniqueKeysWithValues: primaryTransfers.compactMap {
                    transfer
                        -> (String, DBTransactionTransferRecord)? in
                    guard
                        transfer.id
                            == "\(transfer.transactionID)|primary"
                    else {
                        return nil
                    }
                    return (transfer.transactionID, transfer)
                }
            )

            let assetIDs = Array(
                Set(
                    holdings.map(\.assetID)
                        + transactions.compactMap(\.assetID)
                )
            )
            let assets = try DBAssetRecord
                .filter(assetIDs.contains(Column("id")))
                .fetchAll(database)
            let assetsByID = Dictionary(
                uniqueKeysWithValues: assets.map { ($0.id, $0) }
            )
            let networkIDs = Array(
                Set(
                    accounts.map(\.networkID)
                        + assets.map(\.networkID)
                        + transactions.map(\.networkID)
                )
            )
            let networkByID = Dictionary(
                uniqueKeysWithValues: try DBNetworkRecord
                    .filter(networkIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map { ($0.id, $0) }
            )

            let walletAssets = holdings.compactMap { holding -> WalletAsset? in
                guard
                    let asset = assetsByID[holding.assetID],
                    Self.isDisplayEligibleAsset(asset),
                    let fiatValue = Self.decimal((try? Self.cachedFiatUSDValue(amountText: holding.balance, assetID: holding.assetID, fallback: holding.fiatUSDValue, database: database)) ?? holding.fiatUSDValue ?? "0"),
                    let network = networkByID[asset.networkID],
                    let trustNetwork = WalletBlockchain(
                        rawValue: network.trustWalletBlockchain
                    ),
                    let exactBalance = ExactDecimalText.canonicalUnsigned(
                        holding.balance
                    ),
                    ExactDecimalText.isNonzeroUnsigned(exactBalance)
                        || fiatValue != 0
                else {
                    return nil
                }
                let balance = Self.decimal(exactBalance) ?? 0

                return WalletAsset(
                    id: asset.id,
                    name: asset.name,
                    symbol: asset.symbol,
                    logoSource: Self.logoSource(
                        asset: asset,
                        fallbackNetwork: trustNetwork
                    ),
                    network: trustNetwork,
                    balance: balance,
                    fiatValue: fiatValue,
                    balanceText: exactBalance,
                    balanceAtomic: holding.balanceAtomic,
                    decimals: asset.decimals,
                    isPinned: holding.isPinned,
                    isVerified: asset.isVerified,
                    isSpam: asset.isSpam
                )
            }
            .sorted { $0.fiatValue > $1.fiatValue }

            let walletTransactions = transactions.compactMap {
                record -> WalletTransaction? in
                guard Self.isDisplayEligibleTransaction(
                    record,
                    assetsByID: assetsByID
                ) else {
                    return nil
                }
                return Self.walletTransaction(
                    record,
                    assetsByID: assetsByID,
                    networkByID: networkByID,
                    localNote: notesByTransactionID[record.id],
                    primaryTransfer:
                        primaryTransferByTransactionID[record.id]
                )
            }

            return WalletHomeSnapshot(
                totalBalance: walletAssets.reduce(0) {
                    $0 + (
                        $1.isSpam || $1.requiresExplicitVisibility
                            ? 0 : $1.fiatValue
                    )
                },
                assets: walletAssets,
                transactions: Array(walletTransactions),
                hasStoredActivity: hasStoredActivity
            )
        }
    }

}
