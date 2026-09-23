import Foundation
import GRDB
import WalletCore

struct StellarSecretDerivationAuthorization: Sendable {
    private let walletID: String
    fileprivate init(walletID: String) { self.walletID = walletID }
    func permits(walletID: String) -> Bool { self.walletID == walletID }
}

extension WalletDatabase {
    func ensureStellarAccount(walletID: String) async throws
        -> StellarAccountMaterial {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(database, key: walletID),
                account: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .filter(Column("networkID") == StellarConstants.networkID)
                    .filter(Column("isEnabled") == true)
                    .fetchOne(database)
            )
        }
        guard let wallet = stored.wallet else {
            throw WalletCreationPersistenceError.missingSecret
        }
        if let account = stored.account,
           StellarAddress.validated(account.address) != nil,
           let publicKey = account.publicKey {
            return StellarAccountMaterial(
                address: account.address,
                publicKey: publicKey,
                derivationPath: account.derivationPath
            )
        }
        let authorization = StellarSecretDerivationAuthorization(
            walletID: walletID
        )
        let key: PrivateKey
        let path: String?
        if wallet.kind == DatabaseWalletKind.importedPrivateKey.rawValue {
            guard let imported = PrivateKey(
                data: try await privateKeyData(
                    walletID: walletID,
                    authorization: authorization
                )
            ) else { throw WalletCreationPersistenceError.missingSecret }
            key = imported
            path = stored.account?.derivationPath
        } else {
            let credential = try await recoveryCredential(
                walletID: walletID,
                authorization: authorization
            )
            guard let hdWallet = credential.makeHDWallet() else {
                throw WalletCreationPersistenceError.missingSecret
            }
            guard let derivedKey = hdWallet.getKey(
                coin: .stellar,
                derivationPath: StellarConstants.derivationPath
            ) else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            key = derivedKey
            path = StellarConstants.derivationPath
        }
        let material = try StellarAddress.material(
            privateKey: key,
            derivationPath: path
        )
        if let expected = stored.account?.address,
           expected != material.address {
            throw WalletCreationPersistenceError.invalidDraft
        }
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            let accountID = "\(walletID):stellar:0"
            let existing = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            )
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: StellarConstants.networkID,
                address: material.address,
                normalizedAddress: material.address,
                label: StellarConstants.accountLabel,
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

    func saveStellarSnapshot(
        _ snapshot: StellarWalletSnapshot,
        walletID: String
    ) async throws {
        let accountID = "\(walletID):stellar:0"
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard let account = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            ), account.walletID == walletID,
               account.address == snapshot.material.address
            else { throw WalletCreationPersistenceError.invalidDraft }
            try Self.clearFetchedBalances(
                database: database,
                accountID: accountID,
                authority: snapshot.balanceFetchAuthority,
                now: now
            )
            for balance in snapshot.balances {
                guard snapshot.balanceFetchAuthority.permitsUpdate(
                    assetID: balance.assetID
                ) else { continue }
                try Self.saveStellarBalance(
                    database: database,
                    accountID: accountID,
                    balance: balance,
                    now: now
                )
            }
            for item in snapshot.history {
                try Self.saveStellarHistory(
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

    private static func saveStellarBalance(
        database: Database,
        accountID: String,
        balance: StellarAssetBalance,
        now: Double
    ) throws {
        let assetID = try saveStellarMetadata(
            database: database,
            metadata: balance.metadata,
            now: now
        )
        let existing = try DBAccountAssetRecord.fetchOne(
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
                fallback: existing?.fiatUSDValue,
                database: database
            ),
            isEnabled: existing?.isEnabled ?? true,
            isPinned: existing?.isPinned ?? false,
            isHidden: existing?.isHidden ?? false,
            sortOrder: existing?.sortOrder ?? balance.metadata?.rank ?? 0,
            firstSeenAt: existing?.firstSeenAt ?? now,
            lastSeenAt: now,
            updatedAt: now
        ).save(database)
    }

    private static func saveStellarHistory(
        database: Database,
        accountID: String,
        item: StellarHistoryItem,
        now: Double
    ) throws {
        let assetID = try saveStellarMetadata(
            database: database,
            metadata: item.metadata,
            now: now
        )
        let outgoing = item.signedAmountText.hasPrefix("-")
        let hash = item.transactionHash.lowercased()
        let existing = try DBTransactionRecord
            .filter(Column("accountID") == accountID)
            .filter(Column("normalizedTransactionHash") == hash)
            .filter(Column("assetID") == assetID)
            .fetchOne(database)
        let fee = try item.networkFeeStroops.map {
            try StellarAmount.userUnits(atomic: $0)
        }
        try DBTransactionRecord(
            id: existing?.id ?? "\(accountID):\(item.id):\(assetID)",
            accountID: accountID,
            networkID: StellarConstants.networkID,
            transactionHash: item.transactionHash,
            normalizedTransactionHash: hash,
            kind: outgoing ? "sent" : "received",
            status: item.failed ? "failed" : "confirmed",
            direction: outgoing ? "outgoing" : "incoming",
            fromAddress: item.sender,
            toAddress: item.recipient,
            counterpartyAddress: outgoing ? item.recipient : item.sender,
            blockNumber: item.ledgerIndex,
            blockHash: nil,
            transactionIndex: nil,
            nonce: item.sourceSequence,
            transactionType: nil,
            timestamp: item.timestamp,
            assetID: assetID,
            assetSymbol: item.metadata?.symbol ?? StellarConstants.nativeSymbol,
            secondaryAssetSymbol: nil,
            assetAmount: item.signedAmountText,
            fiatUSDValue: existing?.fiatUSDValue,
            networkFee: fee,
            networkFeeFiatUSDValue: existing?.networkFeeFiatUSDValue,
            networkFeeSymbol: StellarConstants.nativeSymbol,
            gasPriceGwei: nil,
            gasLimit: nil,
            gasUsed: nil,
            inputData: item.memo,
            methodName: nil,
            displayDetail: outgoing ? item.recipient : item.sender,
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
    private static func saveStellarMetadata(
        database: Database,
        metadata: StellarTokenMetadata?,
        now: Double
    ) throws -> String {
        let assetID = metadata?.assetID ?? StellarConstants.nativeAssetID
        let existing = try DBAssetRecord.fetchOne(database, key: assetID)
        let contract = metadata?.identity.contractAddress ?? ""
        try DBAssetRecord(
            id: assetID,
            networkID: StellarConstants.networkID,
            assetType: metadata == nil
                ? DatabaseAssetType.native.rawValue
                : DatabaseAssetType.fungibleToken.rawValue,
            contractAddress: contract,
            normalizedContractAddress: contract,
            name: metadata?.name
                ?? WalletLocalization.string(StellarConstants.nativeAssetNameKey),
            symbol: metadata?.symbol ?? StellarConstants.nativeSymbol,
            decimals: metadata?.decimals ?? StellarConstants.decimals,
            trustWalletBlockchain: WalletBlockchain.stellar.rawValue,
            trustWalletContractAddress: metadata?.identity.contractAddress,
            logoURL: existing?.logoURL,
            logoOrigin: existing?.logoOrigin,
            isVerified: metadata?.isVerified ?? true,
            isSpam: false,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            metadataUpdatedAt: now
        ).save(database)
        return assetID
    }
}
