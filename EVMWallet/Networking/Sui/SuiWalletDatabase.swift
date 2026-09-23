import Foundation
import GRDB
import WalletCore

struct SuiSecretDerivationAuthorization: Sendable {
    private let walletID: String

    fileprivate init(walletID: String) {
        self.walletID = walletID
    }

    func permits(walletID: String) -> Bool {
        self.walletID == walletID
    }
}

extension WalletDatabase {
    func ensureSuiAccount(
        walletID: String
    ) async throws -> SuiAccountMaterial {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(database, key: walletID),
                account: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .filter(Column("networkID") == SuiConstants.networkID)
                    .filter(Column("isEnabled") == true)
                    .fetchOne(database)
            )
        }
        guard let wallet = stored.wallet else {
            throw WalletCreationPersistenceError.missingSecret
        }
        if let account = stored.account,
           let address = SuiCoinType.validatedAccountAddress(account.address),
           let publicKey = account.publicKey {
            return SuiAccountMaterial(
                address: address,
                publicKey: publicKey,
                derivationPath: account.derivationPath
            )
        }

        let authorization = SuiSecretDerivationAuthorization(
            walletID: walletID
        )
        let key: PrivateKey
        let derivationPath: String?
        if wallet.kind == DatabaseWalletKind.importedPrivateKey.rawValue {
            guard let account = stored.account,
                  let privateKey = PrivateKey(
                    data: try await privateKeyData(
                        walletID: walletID,
                        authorization: authorization
                    )
                  )
            else {
                throw WalletCreationPersistenceError.missingSecret
            }
            key = privateKey
            derivationPath = account.derivationPath
        } else {
            let credential = try await recoveryCredential(
                walletID: walletID,
                authorization: authorization
            )
            guard let hdWallet = credential.makeHDWallet() else {
                throw WalletCreationPersistenceError.missingSecret
            }
            guard let derivedKey = hdWallet.getKey(
                coin: .sui,
                derivationPath: SuiConstants.derivationPath
            ) else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            key = derivedKey
            derivationPath = SuiConstants.derivationPath
        }
        let address = CoinType.sui.deriveAddress(privateKey: key)
        guard let canonicalAddress = SuiCoinType
            .validatedAccountAddress(address)
        else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        if let expected = stored.account?.address {
            guard SuiCoinType.canonicalAccountAddress(expected)
                == canonicalAddress else {
                throw WalletCreationPersistenceError.invalidDraft
            }
        }
        let material = SuiAccountMaterial(
            address: canonicalAddress,
            publicKey: key.getPublicKeyEd25519().description,
            derivationPath: derivationPath
        )
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            let accountID = "\(walletID):sui:0"
            let existing = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            )
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: SuiConstants.networkID,
                address: material.address,
                normalizedAddress: material.address,
                label: SuiConstants.accountLabel,
                derivationPath: material.derivationPath,
                accountIndex: 0,
                publicKey: material.publicKey,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                lastSyncedAt: existing?.lastSyncedAt
            ).save(database)
        }
        return material
    }

    func saveSuiSnapshot(
        _ snapshot: SuiWalletSnapshot,
        walletID: String
    ) async throws {
        let accountID = "\(walletID):sui:0"
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard let account = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            ), account.walletID == walletID,
               account.normalizedAddress == snapshot.material.address
            else {
                throw WalletCreationPersistenceError.invalidDraft
            }

            try Self.clearFetchedBalances(
                database: database,
                accountID: accountID,
                authority: snapshot.balanceFetchAuthority,
                now: now
            )
            for balance in snapshot.balances {
                guard let assetID = balance.assetID,
                      snapshot.balanceFetchAuthority.permitsUpdate(
                          assetID: assetID
                      )
                else { continue }
                try Self.saveSuiAsset(
                    database: database,
                    accountID: accountID,
                    balance: balance,
                    now: now
                )
            }
            for item in snapshot.history {
                try Self.saveSuiHistoryItem(
                    database: database,
                    accountID: accountID,
                    item: item,
                    now: now
                )
            }
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET lastSyncedAt = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [now, now, accountID]
            )
        }
    }

    private static func saveSuiAsset(
        database: Database,
        accountID: String,
        balance: SuiAssetBalance,
        now: Double
    ) throws {
        let assetID = try saveSuiAssetMetadata(
            database: database,
            metadata: balance.metadata,
            now: now
        )
        let existingHolding = try DBAccountAssetRecord.fetchOne(
            database,
            key: ["accountID": accountID, "assetID": assetID]
        )
        try DBAccountAssetRecord(
            accountID: accountID,
            assetID: assetID,
            balance: balance.amountText,
            balanceAtomic: balance.atomicAmount,
            fiatUSDValue: try cachedFiatUSDValue(
                amountText: balance.amountText,
                assetID: assetID,
                fallback: existingHolding?.fiatUSDValue,
                database: database
            ),
            isEnabled: existingHolding?.isEnabled ?? true,
            isPinned: existingHolding?.isPinned ?? false,
            isHidden: existingHolding?.isHidden ?? false,
            sortOrder: existingHolding?.sortOrder
                ?? balance.metadata.rank,
            firstSeenAt: existingHolding?.firstSeenAt ?? now,
            lastSeenAt: now,
            updatedAt: now
        ).save(database)
    }

    private static func saveSuiHistoryItem(
        database: Database,
        accountID: String,
        item: SuiHistoryItem,
        now: Double
    ) throws {
        let assetID = try saveSuiAssetMetadata(
            database: database,
            metadata: item.metadata,
            now: now
        )
        let outgoing = item.signedAtomicAmount.hasPrefix("-")
        let normalizedHash = item.transactionHash
        let submitted = try DBTransactionRecord
            .filter(Column("accountID") == accountID)
            .filter(Column("normalizedTransactionHash") == normalizedHash)
            .filter(Column("assetID") == assetID)
            .fetchOne(database)
        let recordID = submitted?.id
            ?? "\(accountID):\(item.id):\(assetID)"
        let existing: DBTransactionRecord?
        if let submitted {
            existing = submitted
        } else {
            existing = try DBTransactionRecord.fetchOne(
                database,
                key: recordID
            )
        }
        try DBTransactionRecord(
            id: recordID,
            accountID: accountID,
            networkID: SuiConstants.networkID,
            transactionHash: item.transactionHash,
            normalizedTransactionHash: normalizedHash,
            kind: outgoing ? "sent" : "received",
            status: item.failed ? "failed" : "confirmed",
            direction: outgoing ? "outgoing" : "incoming",
            fromAddress: item.sender,
            toAddress: outgoing ? item.counterparty : item.owner,
            counterpartyAddress: item.counterparty,
            blockNumber: nil,
            blockHash: nil,
            transactionIndex: nil,
            nonce: nil,
            transactionType: nil,
            timestamp: item.timestamp,
            assetID: assetID,
            assetSymbol: item.metadata.symbol,
            secondaryAssetSymbol: nil,
            assetAmount: item.amountText,
            fiatUSDValue: existing?.fiatUSDValue,
            networkFee: item.networkFeeText ?? existing?.networkFee,
            networkFeeFiatUSDValue: existing?.networkFeeFiatUSDValue,
            networkFeeSymbol: SuiConstants.nativeSymbol,
            gasPriceGwei: nil,
            gasLimit: nil,
            gasUsed: nil,
            inputData: nil,
            methodName: nil,
            displayDetail: item.counterparty ?? item.transactionHash,
            displayTime: WalletLocalization.string(
                item.failed
                    ? "wallet.activity.status.failed"
                    : "wallet.activity.status.confirmed"
            ),
            firstSeenAt: existing?.firstSeenAt ?? now,
            updatedAt: now
        ).save(database)
    }

    @discardableResult
    private static func saveSuiAssetMetadata(
        database: Database,
        metadata: SuiTokenMetadata,
        now: Double
    ) throws -> String {
        guard let assetID = SuiCoinType.assetID(metadata.coinType) else {
            throw SuiProviderError.invalidCoinType
        }
        let isNative = assetID == SuiConstants.nativeAssetID
        let existing = try DBAssetRecord.fetchOne(
            database,
            key: assetID
        )
        try DBAssetRecord(
            id: assetID,
            networkID: SuiConstants.networkID,
            assetType: isNative
                ? DatabaseAssetType.native.rawValue
                : DatabaseAssetType.fungibleToken.rawValue,
            contractAddress: isNative ? "" : metadata.coinType,
            normalizedContractAddress: isNative ? "" : metadata.coinType,
            name: metadata.name,
            symbol: metadata.symbol,
            decimals: metadata.decimals,
            trustWalletBlockchain: WalletBlockchain.sui.rawValue,
            trustWalletContractAddress: isNative ? nil : metadata.coinType,
            logoURL: isNative
                ? existing?.logoURL
                : metadata.iconURL?.absoluteString ?? existing?.logoURL,
            logoOrigin: isNative
                ? existing?.logoOrigin
                : metadata.iconURL == nil
                    ? existing?.logoOrigin
                    : AssetLogoSourceOrigin.ankr.rawValue,
            isVerified: metadata.isVerified,
            isSpam: false,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            metadataUpdatedAt: now
        ).save(database)
        return assetID
    }
}
