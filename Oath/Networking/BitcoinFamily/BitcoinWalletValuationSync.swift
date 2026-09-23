import Foundation

/// Imported Bitcoin wallets can discover hundreds of transactions and scan
/// Silent Payments. Neither operation is a prerequisite for a market quote.
/// Publish valuation from its own structured child task as soon as it persists.
enum BitcoinWalletValuationSync {
    typealias QuoteProvider = @Sendable (WalletAsset) async throws -> AssetUSDPrice

    static func run(
        databaseProvider: @escaping @Sendable () throws -> WalletDatabase,
        onProgress: WalletSyncProgressHandler?,
        quoteProvider: @escaping QuoteProvider = {
            try await AssetPriceClient.shared.usdPrice(for: $0)
        },
        synchronize: @escaping @Sendable () async -> WalletChainSyncOutcome
    ) async -> WalletChainSyncOutcome {
        await withTaskGroup(of: WalletChainSyncOutcome.self) { group in
            group.addTask { await synchronize() }
            group.addTask {
                await refresh(
                    databaseProvider: databaseProvider,
                    onProgress: onProgress,
                    quoteProvider: quoteProvider
                )
            }
            var outcomes: [WalletChainSyncOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return WalletChainSyncOutcome(
                source: .bitcoinFamily,
                didPersistData: outcomes.contains(where: \.didPersistData),
                failures: outcomes.flatMap(\.failures)
            )
        }
    }

    private static func refresh(
        databaseProvider: @Sendable () throws -> WalletDatabase,
        onProgress: WalletSyncProgressHandler?,
        quoteProvider: QuoteProvider
    ) async -> WalletChainSyncOutcome {
        var stage = WalletSyncFailureStage.providerRead
        do {
            try Task.checkCancellation()
            let database = try databaseProvider()
            let asset = WalletAsset(
                id: "bitcoin:native",
                name: BitcoinFamilyChain.bitcoin.name,
                symbol: BitcoinFamilyChain.bitcoin.symbol,
                logoSource: .nativeCoin(blockchain: .bitcoin),
                network: .bitcoin,
                balance: 0,
                fiatValue: 0,
                decimals: 8
            )
            let quote = try await quoteProvider(asset)
            try Task.checkCancellation()
            guard quote.assetID == asset.id, quote.price > 0 else {
                throw AssetPriceError.invalidResponse
            }
            stage = .persistence
            // Persist even a memory-cache hit: another import may have created
            // its holding after that quote was originally fetched. Balance
            // writes also consume this cache atomically if they finish later.
            try await database.saveAssetUSDPrice(quote)
            try Task.checkCancellation()
            await onProgress?(
                WalletSyncProgressEvent(
                    source: .bitcoinFamily,
                    networkID: BitcoinFamilyChain.bitcoin.networkID,
                    stage: .valuationPersisted
                )
            )
            return .success(.bitcoinFamily, didPersistData: true)
        } catch is CancellationError {
            return .cancelled(.bitcoinFamily)
        } catch {
            return .failure(
                .bitcoinFamily,
                stage: stage,
                error: error,
                networkID: BitcoinFamilyChain.bitcoin.networkID
            )
        }
    }
}
