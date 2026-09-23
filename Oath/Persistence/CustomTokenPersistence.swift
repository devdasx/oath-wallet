import Foundation
import GRDB

enum TrackedEVMTokenInventoryError: Error, Equatable, Sendable {
    case walletUnavailable
    case invalidAccount(accountID: String)
    case invalidAsset(assetID: String)
    case invalidNetwork(networkID: String)
}

extension WalletDatabase {
    func saveCustomToken(
        _ token: CustomToken
    ) async throws -> WalletAsset {
        let asset: WalletAsset
        switch token {
        case let .evm(token):
            asset = try await saveCustomToken(token)
        case let .solana(token):
            asset = try await saveCustomToken(token)
        case let .tron(token):
            asset = try await saveCustomToken(token)
        }
        AssetCatalogSyncService.schedule(database: self)
        return asset
    }

    func trackedEVMTokenBalanceTargets(
        walletID: String
    ) async throws -> [TrackedEVMTokenBalanceTarget] {
        try await pool.read { database in
            guard
                let wallet = try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                ),
                wallet.archivedAt == nil
            else {
                throw TrackedEVMTokenInventoryError.walletUnavailable
            }

            let accounts = try DBWalletAccountRecord
                .filter(Column("walletID") == wallet.id)
                .filter(Column("isEnabled") == true)
                .filter(Column("isWatchOnly") == false)
                .fetchAll(database)
                .filter {
                    AnkrAPIClient.supportsTokenLookup(
                        networkID: $0.networkID
                    )
                }
            guard !accounts.isEmpty else {
                return []
            }

            let accountIDs = accounts.map(\.id)
            let holdings = try DBAccountAssetRecord
                .filter(accountIDs.contains(Column("accountID")))
                .filter(Column("isEnabled") == true)
                .filter(Column("isPinned") == true)
                .fetchAll(database)
            guard !holdings.isEmpty else {
                return []
            }

            let assets = try DBAssetRecord
                .filter(holdings.map(\.assetID).contains(Column("id")))
                .fetchAll(database)
            let assetsByID = Dictionary(
                uniqueKeysWithValues: assets.map { ($0.id, $0) }
            )
            let networks = try DBNetworkRecord
                .filter(
                    Set(accounts.map(\.networkID))
                        .contains(Column("id"))
                )
                .fetchAll(database)
            let networksByID = Dictionary(
                uniqueKeysWithValues: networks.map { ($0.id, $0) }
            )
            let accountsByID = Dictionary(
                uniqueKeysWithValues: accounts.map { ($0.id, $0) }
            )

            return try holdings.compactMap { holding in
                guard let asset = assetsByID[holding.assetID] else {
                    throw TrackedEVMTokenInventoryError.invalidAsset(
                        assetID: holding.assetID
                    )
                }
                guard
                    asset.assetType
                        == DatabaseAssetType.fungibleToken.rawValue
                else {
                    return nil
                }
                guard
                    !asset.isSpam,
                    !TokenSafetyPolicy.isHardDenied(
                        networkID: asset.networkID,
                        contractAddress:
                            asset.normalizedContractAddress
                    )
                else {
                    return nil
                }
                guard
                    let account = accountsByID[holding.accountID],
                    AnkrAPIClient.isValidAddress(
                        account.normalizedAddress
                    )
                else {
                    throw TrackedEVMTokenInventoryError.invalidAccount(
                        accountID: holding.accountID
                    )
                }
                guard
                    asset.networkID == account.networkID,
                    let network = networksByID[account.networkID],
                    network.isEnabled,
                    network.isMainnet,
                    let expectedNetwork = ReceiveNetworkCatalog.network(
                        for: network.id
                    ),
                    let chainID = Int(exactly: network.chainID),
                    chainID == expectedNetwork.chainID,
                    AnkrAPIClient.supportsTokenLookup(
                        networkID: network.id
                    )
                else {
                    throw TrackedEVMTokenInventoryError.invalidNetwork(
                        networkID: account.networkID
                    )
                }
                guard
                    let contractAddress = Self.normalizedTokenContract(
                        asset.normalizedContractAddress
                    ),
                    let decimals = asset.decimals,
                    (0...255).contains(decimals)
                else {
                    throw TrackedEVMTokenInventoryError.invalidAsset(
                        assetID: asset.id
                    )
                }

                return TrackedEVMTokenBalanceTarget(
                    holdingID: TrackedEVMTokenHoldingID(
                        accountID: account.id,
                        assetID: asset.id
                    ),
                    networkID: network.id,
                    expectedChainID: chainID,
                    ownerAddress: account.normalizedAddress,
                    contractAddress: contractAddress.lowercased(),
                    decimals: decimals
                )
            }
            .sorted {
                if $0.networkID != $1.networkID {
                    return $0.networkID < $1.networkID
                }
                return $0.holdingID.assetID < $1.holdingID.assetID
            }
        }
    }

    func saveCustomToken(
        _ token: CustomEVMToken
    ) async throws -> WalletAsset {
        let normalizedContract = token.contractAddress.lowercased()
        guard
            AnkrAPIClient.supportsTokenLookup(networkID: token.network.id),
            Self.normalizedTokenContract(normalizedContract) != nil,
            !TokenSafetyPolicy.isHardDenied(
                networkID: token.network.id,
                contractAddress: normalizedContract
            )
        else {
            throw WalletDataStoreError.invalidAddress
        }

        return try await pool.write { database in
            guard
                let network = try DBNetworkRecord.fetchOne(
                    database,
                    key: token.network.id
                ),
                network.isMainnet,
                network.isEnabled,
                network.chainID == Int64(token.network.chainID),
                let wallet = try DBWalletRecord
                    .filter(Column("profileID") == Self.defaultProfileID)
                    .filter(Column("isSelected") == true)
                    .filter(Column("archivedAt") == nil)
                    .fetchOne(database),
                let account = try DBWalletAccountRecord
                    .filter(Column("walletID") == wallet.id)
                    .filter(Column("networkID") == network.id)
                    .filter(Column("isEnabled") == true)
                    .fetchOne(database)
            else {
                throw WalletDataStoreError.invalidState
            }

            let now = Date().timeIntervalSince1970
            let existingAsset = try DBAssetRecord
                .filter(Column("networkID") == network.id)
                .filter(
                    Column("normalizedContractAddress")
                        == normalizedContract
                )
                .fetchOne(database)
            let contractIdentity =
                token.logoSource.checksummedContractAddress
                    ?? normalizedContract
            let isCatalogToken =
                token.logoSource.origin == .catalog
            let asset = DBAssetRecord(
                id: existingAsset?.id ?? token.assetID,
                networkID: network.id,
                assetType: DatabaseAssetType.fungibleToken.rawValue,
                contractAddress: normalizedContract,
                normalizedContractAddress: normalizedContract,
                name: token.name,
                symbol: token.symbol,
                decimals: token.decimals,
                trustWalletBlockchain:
                    token.network.blockchain.rawValue,
                trustWalletContractAddress: contractIdentity,
                logoURL: token.logoSource.remoteLogoURL?.absoluteString,
                logoOrigin: token.logoSource.origin?.rawValue,
                isVerified: existingAsset?.isVerified == true
                    || isCatalogToken,
                isSpam: existingAsset?.isSpam ?? false,
                createdAt: existingAsset?.createdAt ?? now,
                updatedAt: now,
                metadataUpdatedAt: now
            )
            try asset.save(database)

            let existingHolding = try DBAccountAssetRecord
                .filter(Column("accountID") == account.id)
                .filter(Column("assetID") == asset.id)
                .fetchOne(database)
            let balance = existingHolding?.balance ?? "0"
            let fiatUSDValue: String
            if
                let price = token.usdPrice,
                let decimalBalance = Self.decimal(balance)
            {
                fiatUSDValue = Self.storageString(decimalBalance * price)
            } else {
                fiatUSDValue = existingHolding?.fiatUSDValue ?? "0"
            }
            let holding = DBAccountAssetRecord(
                accountID: account.id,
                assetID: asset.id,
                balance: balance,
                balanceAtomic: existingHolding?.balanceAtomic,
                fiatUSDValue: fiatUSDValue,
                isEnabled: true,
                isPinned: true,
                isHidden: false,
                sortOrder: existingHolding?.sortOrder,
                firstSeenAt: existingHolding?.firstSeenAt ?? now,
                lastSeenAt: now,
                updatedAt: now
            )
            try holding.save(database)
            try WalletAssetCatalogPersistence.enqueuePublication(
                networkID: network.id,
                contractAddress: normalizedContract,
                name: asset.name,
                symbol: asset.symbol,
                decimals: token.decimals,
                in: database,
                now: now
            )

            if let price = token.usdPrice, price > 0 {
                try DBAssetPriceRecord(
                    assetID: asset.id,
                    quoteCurrency: "USD",
                    price: Self.storageString(price),
                    provider: "ankr",
                    observedAt: now,
                    expiresAt: now + 300
                ).insert(database)
                try Self.applyAssetUSDPrice(
                    price,
                    assetID: asset.id,
                    database: database
                )
            }

            let trustNetwork = WalletBlockchain(
                rawValue: network.trustWalletBlockchain
            ) ?? token.network.blockchain
            return WalletAsset(
                id: asset.id,
                name: asset.name,
                symbol: asset.symbol,
                logoSource: Self.logoSource(
                    asset: asset,
                    fallbackNetwork: trustNetwork
                ),
                network: trustNetwork,
                balance: Self.decimal(holding.balance) ?? 0,
                fiatValue: Self.decimal(holding.fiatUSDValue ?? "0") ?? 0,
                receiveAddress: account.address,
                isPinned: true
            )
        }
    }

    func saveCustomToken(
        _ token: CustomSolanaToken
    ) async throws -> WalletAsset {
        let mint = token.mintAddress
        guard
            token.network.id == SolanaConstants.networkID,
            SolanaTokenEligibilityClient.isValidMint(mint),
            token.eligibility.mint == mint,
            token.eligibility.decimals == token.decimals,
            !token.eligibility.isSuspicious,
            token.eligibility.reason != .denylisted,
            !TokenSafetyPolicy.isHardDenied(
                networkID: token.network.id,
                contractAddress: mint
            )
        else {
            throw WalletDataStoreError.invalidAddress
        }

        return try await pool.write { database in
            guard
                let network = try DBNetworkRecord.fetchOne(
                    database,
                    key: token.network.id
                ),
                network.isMainnet,
                network.isEnabled,
                network.chainID == Int64(token.network.chainID),
                let wallet = try DBWalletRecord
                    .filter(Column("profileID") == Self.defaultProfileID)
                    .filter(Column("isSelected") == true)
                    .filter(Column("archivedAt") == nil)
                    .fetchOne(database)
            else {
                throw WalletDataStoreError.invalidState
            }
            let accounts = try DBWalletAccountRecord
                .filter(Column("walletID") == wallet.id)
                .filter(Column("networkID") == network.id)
                .filter(Column("isEnabled") == true)
                .fetchAll(database)
                .sorted { $0.id < $1.id }
            guard let account = accounts.first(where: {
                $0.label == SolanaDerivationKind.phantom.rawValue
                    || $0.derivationPath
                        == SolanaDerivationKind.phantom.derivationPath
            }) ?? accounts.first else {
                throw WalletDataStoreError.invalidState
            }

            let now = Date().timeIntervalSince1970
            let existingAsset = try DBAssetRecord
                .filter(Column("networkID") == network.id)
                .filter(Column("normalizedContractAddress") == mint)
                .fetchOne(database)
            let isCatalogToken = token.logoSource.origin == .catalog
            let asset = DBAssetRecord(
                id: existingAsset?.id ?? token.assetID,
                networkID: network.id,
                assetType: DatabaseAssetType.fungibleToken.rawValue,
                contractAddress: mint,
                normalizedContractAddress: mint,
                name: token.name,
                symbol: token.symbol,
                decimals: token.decimals,
                trustWalletBlockchain: WalletBlockchain.solana.rawValue,
                trustWalletContractAddress: mint,
                logoURL: token.logoSource.remoteLogoURL?.absoluteString,
                logoOrigin: token.logoSource.origin?.rawValue,
                isVerified: existingAsset?.isVerified == true
                    || token.eligibility.isVerified
                    || isCatalogToken,
                isSpam: false,
                createdAt: existingAsset?.createdAt ?? now,
                updatedAt: now,
                metadataUpdatedAt: now
            )
            try asset.save(database)
            try DBSolanaTokenEligibilityRecord(
                eligibility: token.eligibility
            ).save(database)

            let existingHolding = try DBAccountAssetRecord.fetchOne(
                database,
                key: ["accountID": account.id, "assetID": asset.id]
            )
            let holding = DBAccountAssetRecord(
                accountID: account.id,
                assetID: asset.id,
                balance: existingHolding?.balance ?? "0",
                balanceAtomic: existingHolding?.balanceAtomic ?? "0",
                fiatUSDValue: existingHolding?.fiatUSDValue ?? "0",
                isEnabled: true,
                isPinned: true,
                isHidden: false,
                sortOrder: existingHolding?.sortOrder,
                firstSeenAt: existingHolding?.firstSeenAt ?? now,
                lastSeenAt: now,
                updatedAt: now
            )
            try holding.save(database)
            try WalletAssetCatalogPersistence.enqueuePublication(
                networkID: network.id,
                contractAddress: mint,
                name: asset.name,
                symbol: asset.symbol,
                decimals: token.decimals,
                in: database,
                now: now
            )

            return WalletAsset(
                id: asset.id,
                name: asset.name,
                symbol: asset.symbol,
                logoSource: Self.logoSource(
                    asset: asset,
                    fallbackNetwork: .solana
                ),
                network: .solana,
                balance: Self.decimal(holding.balance) ?? 0,
                fiatValue: Self.decimal(
                    holding.fiatUSDValue ?? "0"
                ) ?? 0,
                receiveAddress: account.address,
                isPinned: true
            )
        }
    }

    func saveCustomToken(
        _ token: CustomTronToken
    ) async throws -> WalletAsset {
        let contract = token.contractAddress
        guard
            token.network.id == TronConstants.networkID,
            TronValueParser.hexAddress(contract) != nil,
            !TokenSafetyPolicy.isHardDenied(
                networkID: token.network.id,
                contractAddress: contract
            )
        else {
            throw WalletDataStoreError.invalidAddress
        }

        return try await pool.write { database in
            guard
                let network = try DBNetworkRecord.fetchOne(
                    database,
                    key: token.network.id
                ),
                network.isMainnet,
                network.isEnabled,
                network.chainID == Int64(token.network.chainID),
                let wallet = try DBWalletRecord
                    .filter(Column("profileID") == Self.defaultProfileID)
                    .filter(Column("isSelected") == true)
                    .filter(Column("archivedAt") == nil)
                    .fetchOne(database),
                let account = try DBWalletAccountRecord
                    .filter(Column("walletID") == wallet.id)
                    .filter(Column("networkID") == network.id)
                    .filter(Column("isEnabled") == true)
                    .fetchOne(database)
            else {
                throw WalletDataStoreError.invalidState
            }

            let now = Date().timeIntervalSince1970
            let existingAsset = try DBAssetRecord
                .filter(Column("networkID") == network.id)
                .filter(Column("normalizedContractAddress") == contract)
                .fetchOne(database)
            let isCatalogToken = token.logoSource.origin == .catalog
            let asset = DBAssetRecord(
                id: existingAsset?.id ?? token.assetID,
                networkID: network.id,
                assetType: DatabaseAssetType.fungibleToken.rawValue,
                contractAddress: contract,
                normalizedContractAddress: contract,
                name: token.name,
                symbol: token.symbol,
                decimals: token.decimals,
                trustWalletBlockchain: WalletBlockchain.tron.rawValue,
                trustWalletContractAddress: contract,
                logoURL: token.logoSource.remoteLogoURL?.absoluteString,
                logoOrigin: token.logoSource.origin?.rawValue,
                isVerified: existingAsset?.isVerified == true
                    || isCatalogToken,
                isSpam: false,
                createdAt: existingAsset?.createdAt ?? now,
                updatedAt: now,
                metadataUpdatedAt: now
            )
            try asset.save(database)

            let existingHolding = try DBAccountAssetRecord.fetchOne(
                database,
                key: ["accountID": account.id, "assetID": asset.id]
            )
            let holding = DBAccountAssetRecord(
                accountID: account.id,
                assetID: asset.id,
                balance: existingHolding?.balance ?? "0",
                balanceAtomic: existingHolding?.balanceAtomic ?? "0",
                fiatUSDValue: existingHolding?.fiatUSDValue ?? "0",
                isEnabled: true,
                isPinned: true,
                isHidden: false,
                sortOrder: existingHolding?.sortOrder,
                firstSeenAt: existingHolding?.firstSeenAt ?? now,
                lastSeenAt: now,
                updatedAt: now
            )
            try holding.save(database)
            try WalletAssetCatalogPersistence.enqueuePublication(
                networkID: network.id,
                contractAddress: contract,
                name: asset.name,
                symbol: asset.symbol,
                decimals: token.decimals,
                in: database,
                now: now
            )

            return WalletAsset(
                id: asset.id,
                name: asset.name,
                symbol: asset.symbol,
                logoSource: Self.logoSource(
                    asset: asset,
                    fallbackNetwork: .tron
                ),
                network: .tron,
                balance: Self.decimal(holding.balance) ?? 0,
                fiatValue: Self.decimal(
                    holding.fiatUSDValue ?? "0"
                ) ?? 0,
                receiveAddress: account.address,
                isPinned: true
            )
        }
    }
}
