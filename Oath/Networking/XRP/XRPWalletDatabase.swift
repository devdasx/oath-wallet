import Foundation
import GRDB
import WalletCore

struct XRPSecretDerivationAuthorization: Sendable {
    private let walletID: String

    fileprivate init(walletID: String) {
        self.walletID = walletID
    }

    func permits(walletID: String) -> Bool {
        self.walletID == walletID
    }
}

extension WalletDatabase {
    func ensureXRPAccount(
        walletID: String
    ) async throws -> XRPAccountMaterial {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(database, key: walletID),
                account: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .filter(Column("networkID") == XRPConstants.networkID)
                    .filter(Column("isEnabled") == true)
                    .fetchOne(database)
            )
        }
        guard let wallet = stored.wallet else {
            throw WalletCreationPersistenceError.missingSecret
        }
        if let account = stored.account,
           AnyAddress(string: account.address, coin: .xrp) != nil,
           let publicKey = account.publicKey {
            return XRPAccountMaterial(
                address: account.address,
                publicKey: publicKey,
                derivationPath: account.derivationPath
            )
        }

        let authorization = XRPSecretDerivationAuthorization(
            walletID: walletID
        )
        let key: PrivateKey
        let derivationPath: String?
        if wallet.kind == DatabaseWalletKind.importedPrivateKey.rawValue {
            guard let privateKey = PrivateKey(
                data: try await privateKeyData(
                    walletID: walletID,
                    authorization: authorization
                )
            ) else {
                throw WalletCreationPersistenceError.missingSecret
            }
            key = privateKey
            derivationPath = stored.account?.derivationPath
        } else {
            let credential = try await recoveryCredential(
                walletID: walletID,
                authorization: authorization
            )
            guard let hdWallet = credential.makeHDWallet() else {
                throw WalletCreationPersistenceError.missingSecret
            }
            guard let derivedKey = hdWallet.getKey(
                coin: .xrp,
                derivationPath: XRPConstants.derivationPath
            ) else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            key = derivedKey
            derivationPath = XRPConstants.derivationPath
        }
        let address = CoinType.xrp.deriveAddress(privateKey: key)
        guard AnyAddress(string: address, coin: .xrp) != nil else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        if let expected = stored.account?.address,
           expected != address {
            throw WalletCreationPersistenceError.invalidDraft
        }
        let material = XRPAccountMaterial(
            address: address,
            publicKey: key.getPublicKeySecp256k1(compressed: true).description,
            derivationPath: derivationPath
        )
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            let accountID = "\(walletID):xrp:0"
            let existing = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            )
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: XRPConstants.networkID,
                address: material.address,
                normalizedAddress: material.address,
                label: XRPConstants.accountLabel,
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

    func saveXRPSnapshot(
        _ snapshot: XRPWalletSnapshot,
        walletID: String
    ) async throws {
        let accountID = "\(walletID):xrp:0"
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard let account = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            ), account.walletID == walletID,
               account.address == snapshot.material.address
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
                guard snapshot.balanceFetchAuthority.permitsUpdate(
                    assetID: balance.assetID
                ) else { continue }
                try Self.saveXRPAsset(
                    database: database,
                    accountID: accountID,
                    balance: balance,
                    now: now
                )
            }
            for item in snapshot.history {
                try Self.saveXRPHistory(
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

    private static func saveXRPAsset(
        database: Database,
        accountID: String,
        balance: XRPAssetBalance,
        now: Double
    ) throws {
        let assetID = try saveXRPAssetMetadata(
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
            sortOrder: existing?.sortOrder
                ?? balance.metadata?.rank
                ?? 0,
            firstSeenAt: existing?.firstSeenAt ?? now,
            lastSeenAt: now,
            updatedAt: now
        ).save(database)
    }

    private static func saveXRPHistory(
        database: Database,
        accountID: String,
        item: XRPHistoryItem,
        now: Double
    ) throws {
        let assetID = try saveXRPAssetMetadata(
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
        let recordID = existing?.id
            ?? "\(accountID):\(item.id):\(assetID)"
        let fee = try XRPAmount.userUnitsFromDrops(item.networkFeeDrops)
        let tag = item.destinationTag.map(String.init)
        try DBTransactionRecord(
            id: recordID,
            accountID: accountID,
            networkID: XRPConstants.networkID,
            transactionHash: item.transactionHash,
            normalizedTransactionHash: normalizedHash,
            kind: outgoing ? "sent" : "received",
            status: item.failed ? "failed" : "confirmed",
            direction: outgoing ? "outgoing" : "incoming",
            fromAddress: item.sender,
            toAddress: item.recipient,
            counterpartyAddress: outgoing ? item.recipient : item.sender,
            blockNumber: item.ledgerIndex,
            blockHash: nil,
            transactionIndex: nil,
            nonce: item.sequence,
            transactionType: nil,
            timestamp: item.timestamp,
            assetID: assetID,
            assetSymbol: item.metadata?.symbol ?? XRPConstants.nativeSymbol,
            secondaryAssetSymbol: nil,
            assetAmount: item.signedAmountText,
            fiatUSDValue: existing?.fiatUSDValue,
            networkFee: fee,
            networkFeeFiatUSDValue: existing?.networkFeeFiatUSDValue,
            networkFeeSymbol: XRPConstants.nativeSymbol,
            gasPriceGwei: nil,
            gasLimit: nil,
            gasUsed: nil,
            inputData: tag,
            methodName: tag == nil ? nil : "DestinationTag",
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
    private static func saveXRPAssetMetadata(
        database: Database,
        metadata: XRPTokenMetadata?,
        now: Double
    ) throws -> String {
        let assetID = metadata?.assetID ?? XRPConstants.nativeAssetID
        let existing = try DBAssetRecord.fetchOne(database, key: assetID)
        let contract = metadata?.identity ?? ""
        try DBAssetRecord(
            id: assetID,
            networkID: XRPConstants.networkID,
            assetType: metadata == nil
                ? DatabaseAssetType.native.rawValue
                : DatabaseAssetType.fungibleToken.rawValue,
            contractAddress: contract,
            normalizedContractAddress: contract,
            name: metadata?.name
                ?? WalletLocalization.string(XRPConstants.nativeAssetNameKey),
            symbol: metadata?.symbol ?? XRPConstants.nativeSymbol,
            decimals: metadata?.decimals ?? XRPConstants.decimals,
            trustWalletBlockchain: WalletBlockchain.xrp.rawValue,
            trustWalletContractAddress: metadata?.identity,
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
