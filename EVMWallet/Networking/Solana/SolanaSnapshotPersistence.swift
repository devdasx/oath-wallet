import Foundation
import GRDB

extension WalletDatabase {
    func saveSolanaSnapshot(
        _ snapshot: SolanaWalletSnapshot,
        walletID: String,
        eligibilityByMint: [String: SolanaTokenEligibility],
        resolvedPriceByIDOverride: [String: Decimal]? = nil,
        operationID: UUID = UUID()
    ) async throws {
        let balanceAuthorities = snapshot.addressSnapshots.map(
            \.balanceAuthority
        )
        guard
            balanceAuthorities.count == snapshot.accounts.all.count,
            balanceAuthorities.allSatisfy(\.isComplete)
        else {
            throw SolanaSnapshotPersistenceError.incompleteBalanceSnapshot
        }
        guard
            snapshot.spendable.material.kind
                == snapshot.accounts.primary.kind,
            snapshot.spendable.material.address
                == snapshot.accounts.primary.address
        else {
            throw SolanaSnapshotPersistenceError.spendableSourceMismatch
        }
        let accountID = Self.solanaAccountID(
            walletID: walletID,
            kind: snapshot.accounts.primary.kind
        )
        let priceAssets = Self.solanaPriceAssets(
            snapshot,
            eligibilityByMint: eligibilityByMint
        )
        let resolvedPriceByID: [String: Decimal]
        if let resolvedPriceByIDOverride {
            resolvedPriceByID = resolvedPriceByIDOverride
        } else {
            resolvedPriceByID = await AssetPriceClient.usdPrices(
                for: priceAssets
            )
        }

        let now = Date().timeIntervalSince1970
        let addressSet = Set(snapshot.accounts.all.map(\.address))
        let accountIDs = snapshot.accounts.all.map {
            Self.solanaAccountID(walletID: walletID, kind: $0.kind)
        }
        let safeTokens = snapshot.tokens.filter {
            !TokenSafetyPolicy.isHardDenied(
                networkID: SolanaConstants.networkID,
                contractAddress: $0.mint
            )
        }
        let safeHistory = snapshot.history.filter {
            guard let mint = $0.mint else {
                return true
            }
            return !TokenSafetyPolicy.isHardDenied(
                networkID: SolanaConstants.networkID,
                contractAddress: mint
            )
        }
        _ = try await pool.write { database in
            for eligibility in eligibilityByMint.values {
                let isSpam = eligibility.isSuspicious
                    || TokenSafetyPolicy.isHardDenied(
                        networkID: SolanaConstants.networkID,
                        contractAddress: eligibility.mint
                    )
                try database.execute(
                    sql: """
                    UPDATE assets
                    SET isVerified = CASE
                            WHEN decimals = ? AND ? = 1 THEN 1
                            ELSE 0
                        END,
                        isSpam = CASE
                            WHEN decimals = ? THEN ?
                            ELSE isSpam
                        END,
                        updatedAt = ?,
                        metadataUpdatedAt = ?
                    WHERE networkID = ?
                      AND normalizedContractAddress = ?
                    """,
                    arguments: [
                        eligibility.decimals,
                        eligibility.isEligible,
                        eligibility.decimals,
                        isSpam,
                        now,
                        now,
                        SolanaConstants.networkID,
                        eligibility.mint
                    ]
                )
            }
            let snapshotAssetIDs = Set(
                ["solana:native"]
                    + safeTokens.map { "solana:\($0.mint)" }
                    + safeHistory.map {
                        $0.mint.map { "solana:\($0)" } ?? "solana:native"
                    }
            )
            var persistedAssetIDs = Set(
                try DBAssetRecord
                    .filter(snapshotAssetIDs.contains(Column("id")))
                    .fetchAll(database)
                    .map(\.id)
            )

            let resetRowCount = try DBAccountAssetRecord
                .filter(accountIDs.contains(Column("accountID")))
                .updateAll(
                    database,
                    Column("balance").set(to: "0"),
                    Column("balanceAtomic").set(to: "0"),
                    Column("fiatUSDValue").set(to: "0"),
                    Column("updatedAt").set(to: now)
                )

            var writtenAssetCount = 0
            var writtenTransactionCount = 0

            try Self.saveSolanaAsset(
                id: "solana:native",
                mint: "",
                name: WalletLocalization.string("network.solana.name"),
                symbol: "SOL",
                decimals: 9,
                balance: snapshot.solBalance,
                atomicBalance: snapshot.solAtomicBalance,
                price: resolvedPriceByID["solana:native"] ?? 0,
                sortOrder: 0,
                accountID: accountID,
                isVerified: true,
                isSpam: false,
                now: now,
                database: database
            )
            writtenAssetCount += 1
            persistedAssetIDs.insert("solana:native")
            for (index, token) in safeTokens.enumerated() {
                let assetID = "solana:\(token.mint)"
                try Self.saveSolanaAsset(
                    id: assetID,
                    mint: token.mint,
                    name: token.name,
                    symbol: token.symbol,
                    decimals: token.decimals,
                    balance: token.amount,
                    atomicBalance: token.atomicAmount,
                    price: resolvedPriceByID["solana:\(token.mint)"] ?? 0,
                    sortOrder: token.catalogRank ?? (10_000 + index),
                    accountID: accountID,
                    isVerified:
                        eligibilityByMint[token.mint].map {
                            $0.isEligible
                                && $0.decimals == token.decimals
                        } ?? false,
                    isSpam:
                        eligibilityByMint[token.mint]?.isSuspicious == true,
                    now: now,
                    database: database
                )
                writtenAssetCount += 1
                persistedAssetIDs.insert(assetID)
            }

            for item in safeHistory {
                let assetID = item.mint.map { "solana:\($0)" }
                    ?? "solana:native"
                if persistedAssetIDs.insert(assetID).inserted {
                    try Self.saveSolanaAsset(
                        id: assetID,
                        mint: item.mint ?? "",
                        name: item.mint.flatMap { mint in
                            eligibilityByMint[mint]?.name
                                ?? SolanaTokenCatalog.byMint[mint]?.name
                        } ?? item.symbol,
                        symbol: item.symbol,
                        decimals: item.decimals,
                        balance: 0,
                        atomicBalance: "0",
                        price: resolvedPriceByID[assetID] ?? 0,
                        sortOrder: 20_000,
                        accountID: accountID,
                        isVerified: item.mint.map {
                            eligibilityByMint[$0].map {
                                $0.isEligible
                                    && $0.decimals == item.decimals
                            } ?? false
                        } ?? true,
                        isSpam: item.mint.map {
                            eligibilityByMint[$0]?.isSuspicious == true
                        } ?? false,
                        now: now,
                        database: database
                    )
                    writtenAssetCount += 1
                }
                let price = resolvedPriceByID[assetID]
                let fiatValue = price.map { item.amount * $0 }
                let recordID =
                    "\(accountID):\(item.signature):\(assetID)"
                let existing = try DBTransactionRecord.fetchOne(
                    database,
                    key: recordID
                )
                let providerFiatUSDValue = fiatValue.map {
                    SolanaTransactionMapper.decimalText($0)
                }
                let persistedFiatUSDValue =
                    providerFiatUSDValue ?? existing?.fiatUSDValue
                if item.mint != nil {
                    guard
                        let persistedFiatUSDValue,
                        let visibleFiatValue = Decimal(
                            string: persistedFiatUSDValue,
                            locale: Locale(identifier: "en_US_POSIX")
                        ),
                        abs(visibleFiatValue)
                            >= WalletTransactionVisibilityPolicy
                            .minimumTokenUSDValue
                    else {
                        continue
                    }
                }
                let outgoing = item.from.map(addressSet.contains) ?? false
                try DBTransactionRecord(
                    id: recordID,
                    accountID: accountID,
                    networkID: SolanaConstants.networkID,
                    transactionHash: item.signature,
                    normalizedTransactionHash: item.signature,
                    kind: outgoing ? "sent" : "received",
                    status: item.failed ? "failed" : "confirmed",
                    direction: outgoing ? "outgoing" : "incoming",
                    fromAddress: item.from,
                    toAddress: item.to,
                    counterpartyAddress: outgoing ? item.to : item.from,
                    blockNumber: item.slot,
                    blockHash: nil,
                    transactionIndex: nil,
                    nonce: nil,
                    transactionType: nil,
                    timestamp: item.timestamp,
                    assetID: assetID,
                    assetSymbol: item.symbol,
                    secondaryAssetSymbol: nil,
                    assetAmount: SolanaTransactionMapper.decimalText(
                        item.amount
                    ),
                    fiatUSDValue: persistedFiatUSDValue,
                    networkFee: SolanaTransactionMapper.decimalText(
                        item.fee
                    ),
                    networkFeeFiatUSDValue:
                        resolvedPriceByID["solana:native"].map {
                            SolanaTransactionMapper.decimalText(
                                item.fee * $0
                            )
                        } ?? existing?.networkFeeFiatUSDValue,
                    networkFeeSymbol: "SOL",
                    gasPriceGwei: nil,
                    gasLimit: nil,
                    gasUsed: nil,
                    inputData: nil,
                    methodName: nil,
                    displayDetail: outgoing
                        ? (item.to ?? "") : (item.from ?? ""),
                    displayTime: WalletLocalization.string(
                        item.failed
                            ? "wallet.activity.status.failed"
                            : "wallet.activity.status.confirmed"
                    ),
                    firstSeenAt: existing?.firstSeenAt ?? now,
                    updatedAt: now
                ).save(database)
                writtenTransactionCount += 1
            }

            for material in snapshot.accounts.all {
                let materialAccountID = Self.solanaAccountID(
                    walletID: walletID,
                    kind: material.kind
                )
                try database.execute(
                    sql: """
                    UPDATE walletAccounts
                    SET lastSyncedAt = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [now, now, materialAccountID]
                )
            }

            for cursor in snapshot.historyCursors {
                let materialAccountID = Self.solanaAccountID(
                    walletID: walletID,
                    kind: cursor.ownerKind
                )
                try database.execute(
                    sql: """
                    INSERT INTO solanaSyncState (
                        address,
                        accountID,
                        newestSignature,
                        oldestSignature,
                        providerHistoryComplete,
                        updatedAt
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(address) DO UPDATE SET
                        accountID = excluded.accountID,
                        newestSignature = excluded.newestSignature,
                        oldestSignature = excluded.oldestSignature,
                        providerHistoryComplete =
                            excluded.providerHistoryComplete,
                        updatedAt = excluded.updatedAt
                    """,
                    arguments: [
                        cursor.queriedAddress,
                        materialAccountID,
                        cursor.newestSignature,
                        cursor.oldestSignature,
                        cursor.providerHistoryComplete,
                        now
                    ]
                )
            }
            return (
                resetRows: resetRowCount,
                writtenAssets: writtenAssetCount,
                writtenTransactions: writtenTransactionCount
            )
        }
    }

    private static func solanaPriceAssets(
        _ snapshot: SolanaWalletSnapshot,
        eligibilityByMint: [String: SolanaTokenEligibility]
    ) -> [WalletAsset] {
        let historyMints = Set(snapshot.history.compactMap(\.mint))
        return [
            WalletAsset(
                id: "solana:native",
                name: WalletLocalization.string("network.solana.name"),
                symbol: "SOL",
                logoSource: .nativeCoin(blockchain: .solana),
                network: .solana,
                balance: snapshot.solBalance,
                fiatValue: 0,
                receiveAddress: snapshot.accounts.primary.address
            )
        ] + snapshot.tokens.filter { token in
            !TokenSafetyPolicy.isHardDenied(
                networkID: SolanaConstants.networkID,
                contractAddress: token.mint
            )
                &&
            eligibilityByMint[token.mint].map {
                $0.isEligible && $0.decimals == token.decimals
            } == true
                && (token.amount > 0 || historyMints.contains(token.mint))
        }.map { token in
            let catalogLogo = ReceiveAssetCatalog.variant(
                networkID: SolanaConstants.networkID,
                contractAddress: token.mint
            )?.logoSource
            return WalletAsset(
                id: "solana:\(token.mint)",
                name: token.name,
                symbol: token.symbol,
                logoSource: catalogLogo ?? .unavailable,
                network: .solana,
                balance: token.amount,
                fiatValue: 0,
                receiveAddress: snapshot.accounts.primary.address
            )
        }
    }

    private static func saveSolanaAsset(
        id: String,
        mint: String,
        name: String,
        symbol: String,
        decimals: Int,
        balance: Decimal,
        atomicBalance: String,
        price: Decimal,
        sortOrder: Int,
        accountID: String,
        isVerified: Bool,
        isSpam: Bool,
        now: Double,
        database: Database
    ) throws {
        let isNative = mint.isEmpty
        let catalogVariant = isNative ? nil : ReceiveAssetCatalog.variant(
            networkID: SolanaConstants.networkID,
            contractAddress: mint
        )
        let existingAsset = try DBAssetRecord.fetchOne(
            database,
            key: id
        )
        let existingHolding = try DBAccountAssetRecord.fetchOne(
            database,
            key: ["accountID": accountID, "assetID": id]
        )
        try DBAssetRecord(
            id: id,
            networkID: SolanaConstants.networkID,
            assetType: (
                isNative
                    ? DatabaseAssetType.native
                    : DatabaseAssetType.fungibleToken
            ).rawValue,
            contractAddress: mint,
            normalizedContractAddress: mint,
            name: name,
            symbol: symbol,
            decimals: decimals,
            trustWalletBlockchain: WalletBlockchain.solana.rawValue,
            trustWalletContractAddress: isNative ? nil : mint,
            logoURL: catalogVariant?.logoURL ?? existingAsset?.logoURL,
            logoOrigin: isNative
                ? AssetLogoSourceOrigin.bundled.rawValue
                : (
                    catalogVariant?.logoSource.remoteLogoURL != nil
                        ? AssetLogoSourceOrigin.catalog.rawValue
                        : existingAsset?.logoOrigin
            ),
            isVerified: existingAsset?.isVerified == true
                || isNative || isVerified
                || catalogVariant?.isVerified == true,
            isSpam: !isNative
                && (existingAsset?.isSpam == true || isSpam),
            createdAt: existingAsset?.createdAt ?? now,
            updatedAt: now,
            metadataUpdatedAt: now
        ).save(database)
        try DBAccountAssetRecord(
            accountID: accountID,
            assetID: id,
            balance: SolanaTransactionMapper.decimalText(balance),
            balanceAtomic: atomicBalance,
            fiatUSDValue: SolanaTransactionMapper.decimalText(
                balance * price
            ),
            isEnabled: existingHolding?.isEnabled ?? true,
            isPinned: existingHolding?.isPinned ?? false,
            isHidden: existingHolding?.isHidden ?? false,
            sortOrder: existingHolding?.sortOrder ?? sortOrder,
            firstSeenAt: existingHolding?.firstSeenAt ?? now,
            lastSeenAt: now,
            updatedAt: now
        ).save(database)
    }
}
