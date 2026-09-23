import Foundation
import GRDB
import WalletCore

struct TronSecretDerivationAuthorization: Sendable {
    private let walletID: String

    fileprivate init(walletID: String) {
        self.walletID = walletID
    }

    func permits(walletID: String) -> Bool {
        self.walletID == walletID
    }
}

extension WalletDatabase {
    func ensureTronAccount(
        walletID: String
    ) async throws -> TronAccountMaterial {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                ),
                account: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .filter(
                        Column("networkID")
                            == TronConstants.networkID
                    )
                    .filter(Column("isEnabled") == true)
                    .fetchOne(database)
            )
        }
        guard let wallet = stored.wallet else {
            throw WalletCreationPersistenceError.missingSecret
        }
        if let account = stored.account,
           CoinType.tron.validate(address: account.address),
           let publicKey = account.publicKey,
           !publicKey.isEmpty,
           let hexAddress = TronValueParser.accountHexAddress(
               account.address
           ) {
            return TronAccountMaterial(
                address: account.address,
                hexAddress: hexAddress,
                publicKey: publicKey
            )
        }
        let authorization = TronSecretDerivationAuthorization(
            walletID: walletID
        )
        let derivationPath = CoinType.tron.derivationPath()
        let key: PrivateKey
        let expectedAddress: String?
        let persistedDerivationPath: String?
        if wallet.kind == DatabaseWalletKind.importedPrivateKey.rawValue {
            let account = stored.account
            guard let account else {
                throw WalletCreationPersistenceError.invalidDraft
            }
            guard let privateKey = PrivateKey(
                data: try await privateKeyData(
                    walletID: walletID,
                    authorization: authorization
                )
            ) else {
                throw WalletCreationPersistenceError.missingSecret
            }
            key = privateKey
            expectedAddress = account.address
            persistedDerivationPath = account.derivationPath
        } else {
            let credential = try await recoveryCredential(
                walletID: walletID,
                authorization: authorization
            )
            guard let hdWallet = credential.makeHDWallet()
            else {
                throw WalletCreationPersistenceError.missingSecret
            }
            key = hdWallet.getKeyForCoin(coin: .tron)
            expectedAddress = hdWallet.getAddressForCoin(coin: .tron)
            persistedDerivationPath = derivationPath
        }
        let address = CoinType.tron.deriveAddress(privateKey: key)
        guard
            expectedAddress == nil || expectedAddress == address,
            let hex = TronValueParser.accountHexAddress(address)
        else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        let material = TronAccountMaterial(
            address: address,
            hexAddress: hex,
            publicKey: key.getPublicKeySecp256k1(compressed: false)
                .data.base64EncodedString()
        )
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            let accountID = "\(walletID):tron:0"
            let existing = try DBWalletAccountRecord.fetchOne(
                database,
                key: accountID
            )
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: TronConstants.networkID,
                address: material.address,
                normalizedAddress: material.address,
                label: nil,
                derivationPath: persistedDerivationPath,
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

    func trackedTronTokens(
        walletID: String
    ) async throws -> [TronTrackedToken] {
        let accountID = "\(walletID):tron:0"
        return try await pool.read { database in
            let assetIDs = try DBAccountAssetRecord
                .filter(Column("accountID") == accountID)
                .filter(Column("isEnabled") == true)
                .filter(Column("isPinned") == true)
                .fetchAll(database)
                .map(\.assetID)
            guard !assetIDs.isEmpty else { return [] }

            return try DBAssetRecord
                .filter(assetIDs.contains(Column("id")))
                .filter(Column("networkID") == TronConstants.networkID)
                .filter(Column("id") != "tron:native")
                .filter(
                    Column("assetType")
                        == DatabaseAssetType.fungibleToken.rawValue
                )
                .fetchAll(database)
                .compactMap { asset -> TronTrackedToken? in
                    guard
                        !asset.isSpam,
                        !asset.normalizedContractAddress.isEmpty,
                        !TokenSafetyPolicy.isHardDenied(
                            networkID: TronConstants.networkID,
                            contractAddress:
                                asset.normalizedContractAddress
                        ),
                        TronValueParser.hexAddress(
                            asset.normalizedContractAddress
                        ) != nil,
                        let decimals = asset.decimals
                    else {
                        return nil
                    }
                    return TronTrackedToken(
                        identity: asset.normalizedContractAddress,
                        type: "trc20",
                        name: asset.name,
                        symbol: asset.symbol,
                        decimals: decimals
                    )
                }
        }
    }

    func saveTronSnapshot(
        _ snapshot: TronWalletSnapshot,
        walletID: String
    ) async throws {
        let supportedTokens = snapshot.tokens.filter {
            Self.isSupportedTRC20Balance($0)
                && snapshot.queriedTRC20Identities.contains($0.identity)
                && !TokenSafetyPolicy.isHardDenied(
                    networkID: TronConstants.networkID,
                    contractAddress: $0.identity
                )
        }
        let priceAssets = [
            WalletAsset(
                id: "tron:native",
                name: WalletLocalization.string("network.tron.name"),
                symbol: "TRX",
                logoSource: .nativeCoin(blockchain: .tron),
                network: .tron,
                balance: snapshot.trxBalance,
                fiatValue: 0,
                receiveAddress: snapshot.material.address
            )
        ] + supportedTokens.map { token in
            let balance = TronValueParser.decimalProjection(
                exactDecimalText: token.amountText
            ) ?? 0
            return WalletAsset(
                id: "tron:\(token.identity)",
                name: token.name,
                symbol: token.symbol,
                logoSource: token.type == "trc20"
                    ? .catalogToken(
                        blockchain: .tron,
                        contractAddress: token.identity,
                        logoURL: ReceiveAssetCatalog.variant(
                            networkID: TronConstants.networkID,
                            contractAddress: token.identity
                        )?.logoURL
                    )
                    : .unavailable,
                network: .tron,
                balance: balance,
                fiatValue: 0,
                balanceText: token.amountText,
                balanceAtomic: token.rawAmount,
                decimals: token.decimals,
                receiveAddress: snapshot.material.address
            )
        }
        let resolvedPrices = await AssetPriceClient.usdPrices(
            for: priceAssets
        )
        try await saveTronSnapshot(
            snapshot,
            walletID: walletID,
            resolvedPrices: resolvedPrices
        )
    }

    func saveTronSnapshot(
        _ snapshot: TronWalletSnapshot,
        walletID: String,
        resolvedPrices: [String: Decimal]
    ) async throws {
        let accountID = "\(walletID):tron:0"
        let now = Date().timeIntervalSince1970
        let supportedTokens = snapshot.tokens.filter {
            Self.isSupportedTRC20Balance($0)
                && snapshot.queriedTRC20Identities.contains($0.identity)
                && !TokenSafetyPolicy.isHardDenied(
                    networkID: TronConstants.networkID,
                    contractAddress: $0.identity
                )
        }
        let supportedHistory = snapshot.history.filter {
            $0.assetIdentity == "native"
                || (
                    snapshot.queriedTRC20Identities.contains(
                        $0.assetIdentity
                    )
                        && !TokenSafetyPolicy.isHardDenied(
                            networkID: TronConstants.networkID,
                            contractAddress: $0.assetIdentity
                        )
                )
        }
        _ = try await pool.write { database in
            guard
                let account = try DBWalletAccountRecord.fetchOne(
                    database,
                    key: accountID
                ),
                account.walletID == walletID,
                account.networkID == TronConstants.networkID,
                account.address == snapshot.material.address
            else {
                throw WalletCreationPersistenceError.invalidDraft
            }

            let loadedPreviousHoldings = try DBAccountAssetRecord
                .filter(Column("accountID") == accountID)
                .fetchAll(database)
            let previousAssetIDs = loadedPreviousHoldings.map(\.assetID)
            let loadedPreviousAssets: [DBAssetRecord]
            if previousAssetIDs.isEmpty {
                loadedPreviousAssets = []
            } else {
                loadedPreviousAssets = try DBAssetRecord
                    .filter(previousAssetIDs.contains(Column("id")))
                    .filter(
                        Column("networkID") == TronConstants.networkID
                    )
                    .fetchAll(database)
            }
            let unsupportedAssetIDs = Set(
                loadedPreviousAssets.compactMap { asset -> String? in
                    guard asset.id != "tron:native" else { return nil }
                    guard
                        asset.assetType
                            == DatabaseAssetType.fungibleToken.rawValue,
                        TronValueParser.hexAddress(
                            asset.normalizedContractAddress
                        ) != nil
                    else {
                        return asset.id
                    }
                    return nil
                }
            )
            if !unsupportedAssetIDs.isEmpty {
                try DBTransactionRecord
                    .filter(Column("accountID") == accountID)
                    .filter(
                        unsupportedAssetIDs.contains(
                            Column("assetID")
                        )
                    )
                    .deleteAll(database)
                try DBAccountAssetRecord
                    .filter(Column("accountID") == accountID)
                    .filter(
                        unsupportedAssetIDs.contains(
                            Column("assetID")
                        )
                    )
                    .deleteAll(database)
            }
            let previousHoldings = loadedPreviousHoldings.filter {
                !unsupportedAssetIDs.contains($0.assetID)
            }
            let previousAssets = loadedPreviousAssets.filter {
                !unsupportedAssetIDs.contains($0.id)
            }
            let authoritativeResetAssetIDs = Set(
                previousAssets.compactMap { asset -> String? in
                    let identity = asset.normalizedContractAddress
                    guard
                        !identity.isEmpty,
                        TronValueParser.hexAddress(identity) != nil
                    else {
                        return asset.id
                    }
                    return snapshot.queriedTRC20Identities
                        .contains(identity) ? asset.id : nil
                }
            ).union(["tron:native"])
            let returnedBalanceAssetIDs = Set(
                supportedTokens.map { "tron:\($0.identity)" }
            ).union(["tron:native"])
            let previousPositiveCount = previousHoldings.filter {
                Self.isNonzeroTronBalance($0.balance)
            }.count
            let omittedPositiveCount = previousHoldings.filter {
                authoritativeResetAssetIDs.contains($0.assetID)
                    && !returnedBalanceAssetIDs.contains($0.assetID)
                    && Self.isNonzeroTronBalance($0.balance)
            }.count
            let resetRowCount = try DBAccountAssetRecord
                .filter(Column("accountID") == accountID)
                .filter(
                    authoritativeResetAssetIDs
                        .contains(Column("assetID"))
                )
                .updateAll(
                    database,
                    Column("balance").set(to: "0"),
                    Column("balanceAtomic").set(to: "0"),
                    Column("fiatUSDValue").set(to: "0"),
                    Column("updatedAt").set(to: now)
                )
            var writtenAssetCount = 0

            func saveAsset(
                id: String,
                identity: String,
                type: DatabaseAssetType,
                name: String,
                symbol: String,
                decimals: Int,
                balanceText: String,
                balanceProjection: Decimal,
                rawBalance: String,
                sortOrder: Int
            ) throws {
                let price = resolvedPrices[id] ?? 0
                let existingAsset = try DBAssetRecord.fetchOne(
                    database,
                    key: id
                )
                let existingHolding = try DBAccountAssetRecord.fetchOne(
                    database,
                    key: ["accountID": accountID, "assetID": id]
                )
                let catalogLogo = ReceiveAssetCatalog.variant(
                    networkID: TronConstants.networkID,
                    contractAddress: identity
                )?.logoSource.remoteLogoURL?.absoluteString
                try DBAssetRecord(
                    id: id,
                    networkID: TronConstants.networkID,
                    assetType: type.rawValue,
                    contractAddress: identity,
                    normalizedContractAddress: identity,
                    name: name,
                    symbol: symbol,
                    decimals: decimals,
                    trustWalletBlockchain: WalletBlockchain.tron.rawValue,
                    trustWalletContractAddress:
                        type == .fungibleToken ? identity : nil,
                    logoURL: catalogLogo ?? existingAsset?.logoURL,
                    logoOrigin: catalogLogo != nil
                        ? AssetLogoSourceOrigin.catalog.rawValue
                        : existingAsset?.logoOrigin,
                    isVerified: existingAsset?.isVerified == true
                        || identity.isEmpty
                        || TronTokenCatalog.byIdentity[identity] != nil,
                    isSpam: existingAsset?.isSpam == true
                        || TokenSafetyPolicy.isHardDenied(
                            networkID: TronConstants.networkID,
                            contractAddress: identity
                        ),
                    createdAt: existingAsset?.createdAt ?? now,
                    updatedAt: now,
                    metadataUpdatedAt: now
                ).save(database)
                try DBAccountAssetRecord(
                    accountID: accountID,
                    assetID: id,
                    balance: balanceText,
                    balanceAtomic: rawBalance,
                    fiatUSDValue: NSDecimalNumber(
                        decimal: balanceProjection * price
                    ).stringValue,
                    isEnabled: existingHolding?.isEnabled ?? true,
                    isPinned: existingHolding?.isPinned ?? false,
                    isHidden: existingHolding?.isHidden ?? false,
                    sortOrder: existingHolding?.sortOrder ?? sortOrder,
                    firstSeenAt: existingHolding?.firstSeenAt ?? now,
                    lastSeenAt: now,
                    updatedAt: now
                ).save(database)
                writtenAssetCount += 1
            }
            try saveAsset(
                id: "tron:native",
                identity: "",
                type: .native,
                name: WalletLocalization.string("network.tron.name"),
                symbol: "TRX",
                decimals: 6,
                balanceText: NSDecimalNumber(
                    decimal: snapshot.trxBalance
                ).stringValue,
                balanceProjection: snapshot.trxBalance,
                rawBalance: NSDecimalNumber(
                    decimal: snapshot.trxBalance * TronConstants.sunPerTRX
                ).stringValue,
                sortOrder: 0
            )
            for (index, token) in supportedTokens.enumerated() {
                try saveAsset(
                    id: "tron:\(token.identity)",
                    identity: token.identity,
                    type: .fungibleToken,
                    name: token.name,
                    symbol: token.symbol,
                    decimals: token.decimals,
                    balanceText: token.amountText,
                    balanceProjection:
                        TronValueParser.decimalProjection(
                            exactDecimalText: token.amountText
                        ) ?? 0,
                    rawBalance: token.rawAmount,
                    sortOrder: index + 1
                )
            }
            var persistedAssetIDs = Set(
                supportedTokens.map { "tron:\($0.identity)" }
            ).union(["tron:native"])
            for item in supportedHistory {
                let id = item.assetIdentity == "native"
                    ? "tron:native" : "tron:\(item.assetIdentity)"
                guard persistedAssetIDs.insert(id).inserted else {
                    continue
                }
                try saveAsset(
                    id: id,
                    identity: item.assetIdentity,
                    type: Self.tronAssetType(
                        identity: item.assetIdentity
                    ),
                    name: item.assetName,
                    symbol: item.assetSymbol,
                    decimals: item.decimals,
                    balanceText: "0",
                    balanceProjection: 0,
                    rawBalance: "0",
                    sortOrder: 10_000
                )
            }
            for item in supportedHistory {
                let assetID = item.assetIdentity == "native"
                    ? "tron:native" : "tron:\(item.assetIdentity)"
                let outgoing = item.from == snapshot.material.address
                let recordID =
                    "\(accountID):\(item.transactionID):\(assetID)"
                let amountProjection = TronValueParser.decimalProjection(
                    exactDecimalText: item.amountText
                )
                let providerFiatUSDValue = amountProjection.flatMap { amount in
                    resolvedPrices[assetID].map { price in
                        NSDecimalNumber(decimal: amount * price).stringValue
                    }
                }
                let existing = try DBTransactionRecord.fetchOne(
                    database,
                    key: recordID
                )
                let primaryTransferID = "\(recordID)|primary"
                let existingPrimaryTransfer =
                    try DBTransactionTransferRecord.fetchOne(
                        database,
                        key: primaryTransferID
                    )
                let fiatUSDValue =
                    providerFiatUSDValue ?? existing?.fiatUSDValue
                let networkFee = item.fee.map {
                    NSDecimalNumber(decimal: $0).stringValue
                }
                let networkFeeFiatUSDValue = item.fee.flatMap { fee in
                    resolvedPrices["tron:native"].map { price in
                        NSDecimalNumber(decimal: fee * price).stringValue
                    }
                } ?? existing?.networkFeeFiatUSDValue
                try DBTransactionRecord(
                    id: recordID,
                    accountID: accountID,
                    networkID: TronConstants.networkID,
                    transactionHash: item.transactionID,
                    normalizedTransactionHash: item.transactionID.lowercased(),
                    kind: outgoing ? "sent" : "received",
                    status: item.failed ? "failed" : "confirmed",
                    direction: outgoing ? "outgoing" : "incoming",
                    fromAddress: item.from,
                    toAddress: item.to,
                    counterpartyAddress: outgoing ? item.to : item.from,
                    blockNumber: item.blockNumber,
                    blockHash: nil,
                    transactionIndex: nil,
                    nonce: nil,
                    transactionType: nil,
                    timestamp: item.timestamp,
                    assetID: assetID,
                    assetSymbol: item.assetSymbol,
                    secondaryAssetSymbol: nil,
                    assetAmount: item.amountText,
                    fiatUSDValue: fiatUSDValue,
                    networkFee: networkFee,
                    networkFeeFiatUSDValue: networkFeeFiatUSDValue,
                    networkFeeSymbol: "TRX",
                    gasPriceGwei: nil,
                    gasLimit: nil,
                    gasUsed: nil,
                    inputData: nil,
                    methodName: nil,
                    displayDetail: outgoing ? item.to : item.from,
                    displayTime: WalletLocalization.string(
                        item.failed
                            ? "wallet.activity.status.failed"
                            : "wallet.activity.status.confirmed"
                    ),
                    firstSeenAt: existing?.firstSeenAt ?? now,
                    updatedAt: now
                ).save(database)
                try DBTransactionTransferRecord(
                    id: primaryTransferID,
                    transactionID: recordID,
                    logIndex: nil,
                    assetID: assetID,
                    fromAddress: item.from,
                    toAddress: item.to,
                    direction: outgoing ? "outgoing" : "incoming",
                    amount: item.amountText,
                    amountAtomic: item.rawAmount,
                    fiatUSDValue:
                        providerFiatUSDValue
                        ?? existingPrimaryTransfer?.fiatUSDValue,
                    tokenName: item.assetName,
                    tokenSymbol: item.assetSymbol,
                    tokenDecimals: item.decimals
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
            return (
                previousHoldingCount: previousHoldings.count,
                previousPositiveCount: previousPositiveCount,
                omittedPositiveCount: omittedPositiveCount,
                resetRowCount: resetRowCount,
                writtenAssetCount: writtenAssetCount,
                writtenTransactionCount: supportedHistory.count
            )
        }
    }

    private static func isNonzeroTronBalance(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return true
        }
        var decimalSeparatorCount = 0
        for byte in value.utf8 {
            if byte == 46 {
                decimalSeparatorCount += 1
                guard decimalSeparatorCount == 1 else { return true }
            } else if byte < 48 || byte > 57 {
                return true
            }
        }
        return value.utf8.contains { byte in
            byte >= 49 && byte <= 57
        }
    }

    private static func isSupportedTRC20Balance(
        _ token: TronTokenBalance
    ) -> Bool {
        token.type == "trc20"
            && TronValueParser.hexAddress(token.identity) != nil
    }

    private static func tronAssetType(
        identity: String
    ) -> DatabaseAssetType {
        guard identity != "native" else { return .native }
        return .fungibleToken
    }
}
