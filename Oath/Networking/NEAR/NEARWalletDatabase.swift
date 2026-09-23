import Foundation
import GRDB
import WalletCore

struct NEARSecretDerivationAuthorization: Sendable {
    private let walletID: String

    fileprivate init(walletID: String) { self.walletID = walletID }

    func permits(walletID: String) -> Bool { self.walletID == walletID }
}

extension WalletDatabase {
    func ensureNEARAccount(walletID: String) async throws
        -> NEARAccountMaterial {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(database, key: walletID),
                account: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .filter(Column("networkID") == NEARConstants.networkID)
                    .filter(Column("isEnabled") == true)
                    .fetchOne(database)
            )
        }
        guard let wallet = stored.wallet else {
            throw WalletCreationPersistenceError.missingSecret
        }
        if let account = stored.account,
           NEARAddress.isValid(account.address),
           let publicKey = account.publicKey {
            return NEARAccountMaterial(
                address: account.address,
                publicKey: publicKey,
                derivationPath: account.derivationPath
            )
        }
        let authorization = NEARSecretDerivationAuthorization(walletID: walletID)
        let key: PrivateKey
        let path: String?
        if wallet.kind == DatabaseWalletKind.importedPrivateKey.rawValue {
            guard let privateKey = PrivateKey(
                data: try await privateKeyData(
                    walletID: walletID,
                    authorization: authorization
                )
            ) else { throw WalletCreationPersistenceError.missingSecret }
            key = privateKey
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
                coin: .near,
                derivationPath: NEARConstants.derivationPath
            ) else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            key = derivedKey
            path = NEARConstants.derivationPath
        }
        let material = try NEARAddress.material(
            privateKey: key,
            derivationPath: path
        )
        if let expected = stored.account?.address,
           expected != material.address {
            throw WalletCreationPersistenceError.invalidDraft
        }
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            let accountID = "\(walletID):near:0"
            let existing = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            )
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: NEARConstants.networkID,
                address: material.address,
                normalizedAddress: material.address,
                label: NEARConstants.accountLabel,
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

    func saveNEARSnapshot(
        _ snapshot: NEARWalletSnapshot,
        walletID: String
    ) async throws {
        let accountID = "\(walletID):near:0"
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
                try Self.saveNEARBalance(
                    database: database,
                    accountID: accountID,
                    balance: balance,
                    now: now
                )
            }
            for item in snapshot.history {
                try Self.saveNEARHistory(
                    database: database,
                    accountID: accountID,
                    item: item,
                    now: now
                )
            }
            if snapshot.historyIsAuthoritative {
                // Upsert real transactions first to repair overwritten rows in
                // place (including their IDs and notes), then remove refund-only
                // entries imported by older versions. Balances are unaffected.
                try database.execute(
                    sql: """
                    DELETE FROM transactions
                    WHERE accountID = ? AND networkID = 'near'
                      AND assetID = 'near:native' AND fromAddress = 'system'
                    """,
                    arguments: [accountID]
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

    private static func saveNEARBalance(
        database: Database,
        accountID: String,
        balance: NEARAssetBalance,
        now: Double
    ) throws {
        let assetID = try saveNEARMetadata(
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

    private static func saveNEARHistory(
        database: Database,
        accountID: String,
        item: NEARHistoryItem,
        now: Double
    ) throws {
        guard item.sender != "system" || item.metadata != nil else { return }
        let assetID = try saveNEARMetadata(
            database: database,
            metadata: item.metadata,
            now: now
        )
        let outgoing = item.signedAmountText.hasPrefix("-")
        let normalizedHash = item.transactionHash.lowercased()
        let existing = try DBTransactionRecord
            .filter(Column("accountID") == accountID)
            .filter(Column("normalizedTransactionHash") == normalizedHash)
            .filter(Column("assetID") == assetID)
            .fetchOne(database)
        let fee = try item.networkFeeAtomic.map {
            try NEARAPIClient.userUnits(
                atomic: $0,
                decimals: NEARConstants.decimals
            )
        }
        try DBTransactionRecord(
            id: existing?.id ?? "\(accountID):\(item.id):\(assetID)",
            accountID: accountID,
            networkID: NEARConstants.networkID,
            transactionHash: item.transactionHash,
            normalizedTransactionHash: normalizedHash,
            kind: outgoing ? "sent" : "received",
            status: item.failed ? "failed" : "confirmed",
            direction: outgoing ? "outgoing" : "incoming",
            fromAddress: item.sender,
            toAddress: item.recipient,
            counterpartyAddress: outgoing ? item.recipient : item.sender,
            blockNumber: item.blockHeight,
            blockHash: nil,
            transactionIndex: nil,
            nonce: item.nonce,
            transactionType: nil,
            timestamp: item.timestamp,
            assetID: assetID,
            assetSymbol: item.metadata?.symbol ?? NEARConstants.nativeSymbol,
            secondaryAssetSymbol: nil,
            assetAmount: item.signedAmountText,
            fiatUSDValue: existing?.fromAddress == "system"
                ? nil : existing?.fiatUSDValue,
            networkFee: fee,
            networkFeeFiatUSDValue: existing?.fromAddress == "system"
                ? nil : existing?.networkFeeFiatUSDValue,
            networkFeeSymbol: NEARConstants.nativeSymbol,
            gasPriceGwei: nil,
            gasLimit: nil,
            gasUsed: nil,
            inputData: nil,
            methodName: item.metadata == nil ? nil : "ft_transfer",
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
    private static func saveNEARMetadata(
        database: Database,
        metadata: NEARTokenMetadata?,
        now: Double
    ) throws -> String {
        let assetID = metadata?.assetID ?? NEARConstants.nativeAssetID
        let existing = try DBAssetRecord.fetchOne(database, key: assetID)
        let contract = metadata?.contractID ?? ""
        try DBAssetRecord(
            id: assetID,
            networkID: NEARConstants.networkID,
            assetType: metadata == nil
                ? DatabaseAssetType.native.rawValue
                : DatabaseAssetType.fungibleToken.rawValue,
            contractAddress: contract,
            normalizedContractAddress: contract,
            name: metadata?.name
                ?? WalletLocalization.string(NEARConstants.nativeAssetNameKey),
            symbol: metadata?.symbol ?? NEARConstants.nativeSymbol,
            decimals: metadata?.decimals ?? NEARConstants.decimals,
            trustWalletBlockchain: WalletBlockchain.near.rawValue,
            trustWalletContractAddress: metadata?.contractID,
            logoURL: metadata?.isVerified == false
                ? metadata?.iconURL?.absoluteString : existing?.logoURL,
            logoOrigin: metadata?.isVerified == false
                ? "provider" : existing?.logoOrigin,
            isVerified: metadata?.isVerified ?? true,
            isSpam: false,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            metadataUpdatedAt: now
        ).save(database)
        return assetID
    }
}
