import Foundation

struct WalletAssetDetailsRefreshContent: Sendable {
    let asset: WalletAsset
    let transactions: [WalletTransaction]
}

enum WalletAssetDetailsRefreshError: Error, Sendable {
    case selectedWalletUnavailable
    case unsupportedAsset
}

enum WalletAssetDetailsSelection {
    static func matches(
        _ transaction: WalletTransaction,
        asset: WalletAsset
    ) -> Bool {
        guard WalletTransactionVisibilityPolicy.includes(transaction),
              transaction.assetSymbol.caseInsensitiveCompare(asset.symbol)
                == .orderedSame
        else {
            return false
        }

        let assetNetworkID = networkID(for: asset)
        if let transactionNetworkID = transaction.metadata
            .blockchainIdentifier?.lowercased() {
            guard transactionNetworkID == assetNetworkID else {
                return false
            }
        } else if transaction.assetLogoSource.blockchain != asset.network {
            return false
        }

        let assetContract = contractAddress(for: asset)
        let transactionContract = transaction.metadata.contractAddress
            ?? transaction.assetLogoSource.checksummedContractAddress
        switch (assetContract, transactionContract) {
        case (nil, nil):
            return true
        case let (.some(assetValue), .some(transactionValue)):
            return AssetIdentityKey.make(
                networkID: assetNetworkID,
                contractAddress: assetValue
            ) == AssetIdentityKey.make(
                networkID: assetNetworkID,
                contractAddress: transactionValue
            )
        case (.none, .some), (.some, .none):
            return false
        }
    }

    static func networkID(for asset: WalletAsset) -> String {
        let canonical = AssetIdentityKey.canonical(asset.id)
        if let separator = canonical.firstIndex(of: ":") {
            return String(canonical[..<separator])
        }
        return canonical
    }

    static func contractAddress(for asset: WalletAsset) -> String? {
        switch asset.logoSource {
        case .nativeCoin, .network, .family:
            nil
        case let .token(_, contractAddress, _, _):
            contractAddress
        case .unavailable:
            AssetIdentityKey.contractAddress(from: asset.id)
        }
    }

    static func transactions(
        from values: [WalletTransaction],
        matching asset: WalletAsset
    ) -> [WalletTransaction] {
        values.filter { matches($0, asset: asset) }
    }
}

actor WalletAssetDetailsRefreshService {
    typealias DatabaseProvider = @Sendable () throws -> WalletDatabase

    static let shared = WalletAssetDetailsRefreshService(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private let databaseProvider: DatabaseProvider

    init(database: WalletDatabase) {
        databaseProvider = { database }
    }

    private init(databaseProvider: @escaping DatabaseProvider) {
        self.databaseProvider = databaseProvider
    }

    func refresh(
        asset: WalletAsset
    ) async throws -> WalletAssetDetailsRefreshContent {
        let database = try databaseProvider()
        guard let identity = try await database.selectedWalletIdentity()
        else {
            throw WalletAssetDetailsRefreshError
                .selectedWalletUnavailable
        }
        #if DEBUG
        if CommandLine.arguments.contains("--marketing-screenshot") {
            let snapshot = try await database.cachedWalletSnapshot(
                walletID: identity.walletID
            )
            let canonicalID = AssetIdentityKey.canonical(asset.id)
            let cachedAsset = snapshot?.assets.first {
                AssetIdentityKey.canonical($0.id) == canonicalID
            } ?? asset
            return WalletAssetDetailsRefreshContent(
                asset: cachedAsset,
                transactions: WalletAssetDetailsSelection.transactions(
                    from: snapshot?.transactions ?? [],
                    matching: cachedAsset
                )
            )
        }
        #endif
        guard let source = Self.source(for: asset.network) else {
            throw WalletAssetDetailsRefreshError.unsupportedAsset
        }
        try Task.checkCancellation()

        _ = await refresh(
            source: source,
            asset: asset,
            walletID: identity.walletID,
            fallbackAddress: identity.address,
            database: database
        )
        try Task.checkCancellation()

        let snapshot = try await database.cachedWalletSnapshot(
            walletID: identity.walletID
        )
        let canonicalID = AssetIdentityKey.canonical(asset.id)
        let refreshedAsset = snapshot?.assets.first {
            AssetIdentityKey.canonical($0.id) == canonicalID
        } ?? asset
        let transactions = WalletAssetDetailsSelection.transactions(
            from: snapshot?.transactions ?? [],
            matching: refreshedAsset
        )
        return WalletAssetDetailsRefreshContent(
            asset: refreshedAsset,
            transactions: transactions
        )
    }

    nonisolated static func source(
        for blockchain: WalletBlockchain?
    ) -> WalletSyncSource? {
        guard let blockchain else { return nil }
        if blockchain.isEVM { return .evm }
        return switch blockchain {
        case .aptos: .aptos
        case .stellar: .stellar
        case .near: .near
        case .xrp: .xrp
        case .sui: .sui
        case .ton: .ton
        case .tron: .tron
        case .solana: .solana
        case .bitcoin, .bitcoincash, .litecoin, .dogecoin:
            .bitcoinFamily
        case .ethereum, .smartchain, .polygon, .arbitrum,
             .avalanchec, .optimism, .base, .xdai, .scroll, .linea,
             .taiko, .telos, .xlayer, .arc:
            .evm
        }
    }

    private func refresh(
        source: WalletSyncSource,
        asset: WalletAsset,
        walletID: String,
        fallbackAddress: String,
        database: WalletDatabase
    ) async -> WalletChainSyncOutcome {
        switch source {
        case .evm:
            return await refreshEVM(
                asset: asset,
                walletID: walletID,
                fallbackAddress: fallbackAddress,
                database: database
            )
        case .bitcoinFamily:
            guard let chain = Self.bitcoinFamilyChain(for: asset.network)
            else {
                return .failure(
                    .bitcoinFamily,
                    stage: .configuration,
                    error: WalletAssetDetailsRefreshError.unsupportedAsset
                )
            }
            return await BitcoinFamilySyncService(database: database).sync(
                walletID: walletID,
                chain: chain
            )
        case .solana:
            return await SolanaSyncService(database: database).sync(
                walletID: walletID
            )
        case .tron:
            return await TronSyncService(database: database).sync(
                walletID: walletID
            )
        case .ton:
            return await TONSyncService.shared.sync(walletID: walletID)
        case .sui:
            return await SuiSyncService.shared.sync(walletID: walletID)
        case .near:
            return await NEARSyncService.shared.sync(walletID: walletID)
        case .xrp:
            return await XRPSyncService.shared.sync(walletID: walletID)
        case .aptos:
            return await AptosSyncService.shared.sync(walletID: walletID)
        case .stellar:
            return await StellarSyncService.shared.sync(walletID: walletID)
        }
    }

    private func refreshEVM(
        asset: WalletAsset,
        walletID: String,
        fallbackAddress: String,
        database: WalletDatabase
    ) async -> WalletChainSyncOutcome {
        do {
            let client = try AnkrAPIClient.localBuild()
            let result = try await client.loadAssetDetails(
                asset: asset,
                address: asset.receiveAddress ?? fallbackAddress
            )
            try await database.saveEVMAssetDetailsSnapshot(
                result.snapshot,
                walletID: walletID
            )
            return WalletChainSyncOutcome(
                source: .evm,
                didPersistData: true,
                failures: result.failures
            )
        } catch is CancellationError {
            return .cancelled(.evm)
        } catch {
            return .failure(
                .evm,
                stage: error is WalletSnapshotPersistenceError
                    ? .persistence
                    : .providerRead,
                error: error,
                networkID: WalletAssetDetailsSelection.networkID(for: asset)
            )
        }
    }

    private nonisolated static func bitcoinFamilyChain(
        for blockchain: WalletBlockchain?
    ) -> BitcoinFamilyChain? {
        switch blockchain {
        case .bitcoin: .bitcoin
        case .bitcoincash: .bitcoinCash
        case .litecoin: .litecoin
        case .dogecoin: .dogecoin
        default: nil
        }
    }
}
