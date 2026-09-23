import Foundation
import GRDB
import WalletCore

struct TONSecretDerivationAuthorization: Sendable {
    private let walletID: String

    fileprivate init(walletID: String) {
        self.walletID = walletID
    }

    func permits(walletID: String) -> Bool {
        self.walletID == walletID
    }
}

extension WalletDatabase {
    func ensureTONAccount(walletID: String) async throws
        -> TONAccountMaterial {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                ),
                account: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .filter(Column("networkID") == TONConstants.networkID)
                    .filter(Column("isEnabled") == true)
                    .fetchOne(database)
            )
        }
        guard let wallet = stored.wallet else {
            throw WalletCreationPersistenceError.missingSecret
        }
        if let account = stored.account,
           CoinType.ton.validate(address: account.address),
           let publicKey = account.publicKey,
           let rawAddress = TONAddress.rawAddress(from: account.address),
           let bounceable = TONAddressConverter.toUserFriendly(
               address: rawAddress,
               bounceable: true,
               testnet: false
           ) {
            return TONAccountMaterial(
                address: account.address,
                rawAddress: rawAddress,
                bounceableAddress: bounceable,
                publicKey: publicKey,
                derivationPath: account.derivationPath
            )
        }

        let authorization = TONSecretDerivationAuthorization(
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
            guard let wallet = credential.makeHDWallet() else {
                throw WalletCreationPersistenceError.missingSecret
            }
            guard let derivedKey = wallet.getKey(
                coin: .ton,
                derivationPath: TONConstants.derivationPath
            ) else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            key = derivedKey
            derivationPath = TONConstants.derivationPath
        }
        let material = try TONAddress.material(
            privateKey: key,
            derivationPath: derivationPath
        )
        if let expected = stored.account?.address {
            guard TONAddress.rawAddress(from: expected)
                    == material.rawAddress else {
                throw WalletCreationPersistenceError.invalidDraft
            }
        }
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            let accountID = "\(walletID):ton:0"
            let existing = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            )
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: TONConstants.networkID,
                address: material.address,
                normalizedAddress: material.rawAddress,
                label: TONConstants.accountLabel,
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

    func saveTONSnapshot(
        _ snapshot: TONWalletSnapshot,
        walletID: String
    ) async throws {
        let accountID = "\(walletID):ton:0"
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard let account = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            ),
                  account.walletID == walletID,
                  account.normalizedAddress == snapshot.material.rawAddress
            else {
                throw WalletCreationPersistenceError.invalidDraft
            }

            let balanceAuthority = WalletBalanceFetchAuthority(
                successfulAssetIDs: [TONConstants.nativeAssetID],
                inventoryIsAuthoritative: snapshot.jettonsAreAuthoritative
            )
            try Self.clearFetchedBalances(
                database: database,
                accountID: accountID,
                authority: balanceAuthority,
                now: now
            )
            if snapshot.jettonsAreAuthoritative {
                try database.execute(
                    sql: """
                    DELETE FROM tonJettonWallets
                    WHERE accountID = ?
                    """,
                    arguments: [accountID]
                )
            }

            func saveAsset(
                id: String,
                contract: String,
                name: String,
                symbol: String,
                decimals: Int,
                balance: String,
                atomicBalance: String,
                price: String?,
                sortOrder: Int
            ) throws {
                let existingAsset = try DBAssetRecord.fetchOne(
                    database,
                    key: id
                )
                let existingHolding = try DBAccountAssetRecord.fetchOne(
                    database,
                    key: ["accountID": accountID, "assetID": id]
                )
                let cachedPrice = try Self.latestValidUSDPriceRecord(
                    assetID: id,
                    database: database
                )?.price
                try DBAssetRecord(
                    id: id,
                    networkID: TONConstants.networkID,
                    assetType: contract.isEmpty
                        ? DatabaseAssetType.native.rawValue
                        : DatabaseAssetType.fungibleToken.rawValue,
                    contractAddress: contract,
                    normalizedContractAddress: contract,
                    name: name,
                    symbol: symbol,
                    decimals: decimals,
                    trustWalletBlockchain: WalletBlockchain.ton.rawValue,
                    trustWalletContractAddress:
                        contract.isEmpty ? nil : contract,
                    logoURL: existingAsset?.logoURL,
                    logoOrigin: existingAsset?.logoOrigin,
                    isVerified: true,
                    isSpam: false,
                    createdAt: existingAsset?.createdAt ?? now,
                    updatedAt: now,
                    metadataUpdatedAt: now
                ).save(database)
                let validIncomingPrice = price.flatMap {
                    ExactDecimalText.canonicalUnsigned($0)
                }
                let valuationPrice = contract.isEmpty ? (validIncomingPrice ?? cachedPrice) : cachedPrice
                let fiat = Self.tonFiatValue(
                    balance: balance,
                    price: valuationPrice
                )
                try DBAccountAssetRecord(
                    accountID: accountID,
                    assetID: id,
                    balance: balance,
                    balanceAtomic: atomicBalance,
                    fiatUSDValue: fiat,
                    isEnabled: existingHolding?.isEnabled ?? true,
                    isPinned: existingHolding?.isPinned ?? false,
                    isHidden: existingHolding?.isHidden ?? false,
                    sortOrder: existingHolding?.sortOrder ?? sortOrder,
                    firstSeenAt: existingHolding?.firstSeenAt ?? now,
                    lastSeenAt: now,
                    updatedAt: now
                ).save(database)
                if contract.isEmpty, let price = validIncomingPrice {
                    try DBAssetPriceRecord(
                        assetID: id,
                        quoteCurrency: "USD",
                        price: price,
                        provider: "tonapi",
                        observedAt: now,
                        expiresAt: now + 120
                    ).save(database)
                }
            }

            try saveAsset(
                id: TONConstants.nativeAssetID,
                contract: "",
                name: WalletLocalization.string(
                    TONConstants.nativeAssetNameKey
                ),
                symbol: TONConstants.nativeSymbol,
                decimals: TONConstants.decimals,
                balance: snapshot.nativeAmountText,
                atomicBalance: snapshot.nativeAtomicAmount,
                price: snapshot.nativeUSDPriceText,
                sortOrder: 0
            )
            for token in snapshot.tokens {
                try saveAsset(
                    id: "ton:\(token.definition.address)",
                    contract: token.definition.address,
                    name: token.definition.name,
                    symbol: token.definition.symbol,
                    decimals: token.definition.decimals,
                    balance: token.amountText,
                    atomicBalance: token.atomicAmount,
                    price: token.usdPriceText,
                    sortOrder: token.definition.rank
                )
                try database.execute(
                    sql: """
                    INSERT INTO tonJettonWallets(
                        accountID, assetID, walletAddress, updatedAt
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(accountID, assetID) DO UPDATE SET
                        walletAddress = excluded.walletAddress,
                        updatedAt = excluded.updatedAt
                    """,
                    arguments: [
                        accountID,
                        "ton:\(token.definition.address)",
                        token.walletAddress,
                        now
                    ]
                )
            }
            for item in snapshot.history {
                let fromAddress = try Self.tonTransactionAddress(item.from)
                let toAddress = try Self.tonTransactionAddress(item.to)
                let assetID = item.assetAddress.map {
                    "ton:\($0)"
                } ?? TONConstants.nativeAssetID
                let outgoing = item.from == snapshot.material.rawAddress
                let normalizedHash = item.transactionHash.lowercased()
                let matchingSubmission = try DBTransactionRecord
                    .filter(Column("accountID") == accountID)
                    .filter(
                        Column("normalizedTransactionHash")
                            == normalizedHash
                    )
                    .filter(Column("assetID") == assetID)
                    .fetchOne(database)
                let recordID = matchingSubmission?.id
                    ?? "\(accountID):\(item.id):\(assetID)"
                let existing: DBTransactionRecord?
                if let matchingSubmission {
                    existing = matchingSubmission
                } else {
                    existing = try DBTransactionRecord.fetchOne(
                        database,
                        key: recordID
                    )
                }
                let price = item.assetAddress == nil
                    ? snapshot.nativeUSDPriceText
                    : try Self.latestValidUSDPriceRecord(assetID: assetID, database: database)?.price
                let fiat = Self.tonFiatValue(
                    balance: item.amountText,
                    price: price
                )
                try DBTransactionRecord(
                    id: recordID,
                    accountID: accountID,
                    networkID: TONConstants.networkID,
                    transactionHash: item.transactionHash,
                    normalizedTransactionHash: normalizedHash,
                    kind: outgoing ? "sent" : "received",
                    status: item.failed ? "failed" : "confirmed",
                    direction: outgoing ? "outgoing" : "incoming",
                    fromAddress: fromAddress,
                    toAddress: toAddress,
                    counterpartyAddress: outgoing
                        ? toAddress : fromAddress,
                    blockNumber: nil,
                    blockHash: nil,
                    transactionIndex: nil,
                    nonce: nil,
                    transactionType: nil,
                    timestamp: item.timestamp,
                    assetID: assetID,
                    assetSymbol: item.assetSymbol,
                    secondaryAssetSymbol: nil,
                    assetAmount: item.amountText,
                    fiatUSDValue: fiat ?? existing?.fiatUSDValue,
                    networkFee: nil,
                    networkFeeFiatUSDValue:
                        existing?.networkFeeFiatUSDValue,
                    networkFeeSymbol: TONConstants.nativeSymbol,
                    gasPriceGwei: nil,
                    gasLimit: nil,
                    gasUsed: nil,
                    inputData: nil,
                    methodName: nil,
                    displayDetail: outgoing
                        ? (toAddress ?? "")
                        : (fromAddress ?? ""),
                    displayTime: WalletLocalization.string(
                        item.failed
                            ? "wallet.activity.status.failed"
                            : "wallet.activity.status.confirmed"
                    ),
                    firstSeenAt: existing?.firstSeenAt ?? now,
                    updatedAt: now
                ).save(database)
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

    func tonJettonWallet(
        walletID: String,
        assetID: String
    ) async throws -> String? {
        try await pool.read { database in
            try String.fetchOne(
                database,
                sql: """
                SELECT walletAddress
                FROM tonJettonWallets
                WHERE accountID = ? AND assetID = ?
                """,
                arguments: ["\(walletID):ton:0", assetID]
            )
        }
    }

    private static func tonFiatValue(
        balance: String,
        price: String?
    ) -> String? {
        guard let price,
              let balanceValue = Decimal(
                  string: balance,
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              let priceValue = Decimal(
                  string: price,
                  locale: Locale(identifier: "en_US_POSIX")
              )
        else {
            return nil
        }
        return NSDecimalNumber(
            decimal: balanceValue * priceValue
        ).stringValue
    }

    private static func tonTransactionAddress(
        _ value: String?
    ) throws -> String? {
        guard let value else { return nil }
        guard let address = TONAddress.mainnetDisplayAddress(from: value)
        else {
            throw TONProviderError.invalidResponse("history_address")
        }
        return address
    }
}
