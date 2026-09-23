import Foundation
import GRDB
import WalletCore

struct AptosSecretDerivationAuthorization: Sendable {
    private let walletID: String

    fileprivate init(walletID: String) { self.walletID = walletID }

    func permits(walletID: String) -> Bool { self.walletID == walletID }
}

extension WalletDatabase {
    func ensureAptosAccount(
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws
        -> AptosAccountMaterial {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(database, key: walletID),
                accounts: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .filter(Column("networkID") == AptosConstants.networkID)
                    .filter(Column("isEnabled") == true)
                    .fetchAll(database)
            )
        }
        guard let wallet = stored.wallet else {
            throw WalletCreationPersistenceError.missingSecret
        }
        let accountID = "\(walletID):aptos:0"
        let storedAccount = stored.accounts.first { $0.id == accountID }
            ?? stored.accounts.first
        if let storedAccount,
           storedAccount.id == accountID,
           storedAccount.label == AptosConstants.accountLabel,
           let material = AptosAddress.validatedPersistedMaterial(
               address: storedAccount.address,
               normalizedAddress: storedAccount.normalizedAddress,
               publicKey: storedAccount.publicKey,
               derivationPath: storedAccount.derivationPath
           ) {
            return material
        }
        let authorization = AptosSecretDerivationAuthorization(
            walletID: walletID
        )
        let material: AptosAccountMaterial
        if wallet.kind == DatabaseWalletKind.importedPrivateKey.rawValue {
            guard let privateKey = PrivateKey(
                data: try await privateKeyData(
                    walletID: walletID,
                    authorization: authorization,
                    vault: vault
                )
            ) else { throw WalletCreationPersistenceError.missingSecret }
            material = try AptosAddress.material(
                privateKey: privateKey,
                derivationPath: storedAccount?.derivationPath
            )
        } else {
            let credential = try await recoveryCredential(
                walletID: walletID,
                authorization: authorization,
                vault: vault
            )
            guard let hdWallet = credential.makeHDWallet() else {
                throw WalletCreationPersistenceError.missingSecret
            }
            material = try AptosAddress.material(hdWallet: hdWallet)
        }
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            let existing = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            )
            let identityMatches = existing.map {
                AptosAddress.canonical($0.address) == material.address
                    && $0.normalizedAddress == material.address
                    && $0.publicKey == material.publicKey
            } ?? false

            // Older builds could create an Aptos row with the EVM identity.
            // Remove every non-canonical Aptos account and its cascaded cache;
            // the authoritative Aptos snapshot will repopulate those rows.
            try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("networkID") == AptosConstants.networkID)
                .filter(Column("id") != accountID)
                .deleteAll(database)
            if existing != nil, !identityMatches {
                try DBWalletAccountRecord
                    .filter(Column("id") == accountID)
                    .deleteAll(database)
            }
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: AptosConstants.networkID,
                address: material.address,
                normalizedAddress: material.address,
                label: AptosConstants.accountLabel,
                derivationPath: material.derivationPath,
                accountIndex: 0,
                publicKey: material.publicKey,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: identityMatches ? existing?.createdAt ?? now : now,
                updatedAt: now,
                lastSyncedAt: identityMatches ? existing?.lastSyncedAt : nil
            ).save(database)
        }
        return material
    }

    func saveAptosSnapshot(
        _ snapshot: AptosWalletSnapshot,
        walletID: String
    ) async throws {
        let accountID = "\(walletID):aptos:0"
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard let account = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            ), account.walletID == walletID,
               account.normalizedAddress == snapshot.material.address
            else { throw WalletCreationPersistenceError.invalidDraft }
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
                try Self.saveAptosBalance(
                    database: database,
                    accountID: accountID,
                    balance: balance,
                    now: now
                )
            }
            for item in snapshot.history {
                try Self.saveAptosHistory(
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

    private static func saveAptosBalance(
        database: Database,
        accountID: String,
        balance: AptosAssetBalance,
        now: Double
    ) throws {
        let assetID = try saveAptosMetadata(
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
            sortOrder: existing?.sortOrder ?? balance.metadata.rank,
            firstSeenAt: existing?.firstSeenAt ?? now,
            lastSeenAt: now,
            updatedAt: now
        ).save(database)
    }

    private static func saveAptosHistory(
        database: Database,
        accountID: String,
        item: AptosHistoryItem,
        now: Double
    ) throws {
        let assetID = try saveAptosMetadata(
            database: database,
            metadata: item.metadata,
            now: now
        )
        let outgoing = item.signedAmountText.hasPrefix("-")
        let stableID = "\(accountID):\(item.id):\(assetID)"
        let incomingHasCanonicalHash = isCanonicalAptosTransactionHash(
            item.transactionHash
        )
        let existingByHash = incomingHasCanonicalHash
            ? try DBTransactionRecord
                .filter(Column("accountID") == accountID)
                .filter(
                    Column("normalizedTransactionHash")
                        == item.transactionHash.lowercased()
                )
                .filter(Column("assetID") == assetID)
                .fetchOne(database)
            : nil
        let existingByID = try DBTransactionRecord.fetchOne(
            database,
            key: stableID
        )
        let existingByVersion: DBTransactionRecord?
        if incomingHasCanonicalHash {
            existingByVersion = nil
        } else {
            existingByVersion = try DBTransactionRecord
                .filter(Column("accountID") == accountID)
                .filter(Column("networkID") == AptosConstants.networkID)
                .filter(Column("blockNumber") == item.transactionVersion)
                .filter(Column("assetID") == assetID)
                .filter(
                    Column("direction")
                        == (outgoing ? "outgoing" : "incoming")
                )
                .filter(Column("assetAmount") == item.signedAmountText)
                .fetchAll(database)
                .first {
                    isCanonicalAptosTransactionHash($0.transactionHash)
                }
        }
        let existing = existingByHash ?? existingByID ?? existingByVersion
        let transactionReference: String
        if incomingHasCanonicalHash {
            transactionReference = item.transactionHash.lowercased()
        } else if let existingHash = existing?.transactionHash,
                  isCanonicalAptosTransactionHash(existingHash) {
            transactionReference = existingHash.lowercased()
        } else {
            transactionReference = item.transactionHash
        }
        let fromAddress = item.sender ?? existing?.fromAddress
        let toAddress = item.recipient ?? existing?.toAddress
        let counterpartyAddress = outgoing ? toAddress : fromAddress
        try DBTransactionRecord(
            id: existing?.id ?? stableID,
            accountID: accountID,
            networkID: AptosConstants.networkID,
            transactionHash: transactionReference,
            normalizedTransactionHash: transactionReference,
            kind: outgoing ? "sent" : "received",
            status: item.failed ? "failed" : "confirmed",
            direction: outgoing ? "outgoing" : "incoming",
            fromAddress: fromAddress,
            toAddress: toAddress,
            counterpartyAddress: counterpartyAddress,
            blockNumber: item.transactionVersion,
            blockHash: nil,
            transactionIndex: nil,
            nonce: nil,
            transactionType: nil,
            timestamp: item.timestamp > 0
                ? item.timestamp
                : existing?.timestamp,
            assetID: assetID,
            assetSymbol: item.metadata.symbol,
            secondaryAssetSymbol: nil,
            assetAmount: item.signedAmountText,
            fiatUSDValue: existing?.fiatUSDValue,
            networkFee: item.networkFeeText ?? existing?.networkFee,
            networkFeeFiatUSDValue: existing?.networkFeeFiatUSDValue,
            networkFeeSymbol: AptosConstants.nativeSymbol,
            gasPriceGwei: nil,
            gasLimit: nil,
            gasUsed: nil,
            inputData: nil,
            methodName: item.entryFunction ?? existing?.methodName,
            displayDetail: counterpartyAddress
                ?? existing?.counterpartyAddress
                ?? transactionReference,
            displayTime: "",
            firstSeenAt: existing?.firstSeenAt ?? now,
            updatedAt: now
        ).save(database)
    }

    private static func isCanonicalAptosTransactionHash(
        _ value: String
    ) -> Bool {
        value.hasPrefix("0x")
            && value.count == 66
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    @discardableResult
    private static func saveAptosMetadata(
        database: Database,
        metadata: AptosTokenMetadata,
        now: Double
    ) throws -> String {
        guard let assetID = AptosAssetType.assetID(metadata.assetType) else {
            throw AptosProviderError.invalidAssetType
        }
        let isNative = assetID == AptosConstants.nativeAssetID
        let existing = try DBAssetRecord.fetchOne(database, key: assetID)
        try DBAssetRecord(
            id: assetID,
            networkID: AptosConstants.networkID,
            assetType: isNative
                ? DatabaseAssetType.native.rawValue
                : DatabaseAssetType.fungibleToken.rawValue,
            contractAddress: isNative ? "" : metadata.assetType,
            normalizedContractAddress: isNative ? "" : metadata.assetType,
            name: metadata.name,
            symbol: metadata.symbol,
            decimals: metadata.decimals,
            trustWalletBlockchain: WalletBlockchain.aptos.rawValue,
            trustWalletContractAddress: isNative ? nil : metadata.assetType,
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
