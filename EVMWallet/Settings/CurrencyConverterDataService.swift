import Foundation

struct CurrencyConverterDataService: Sendable {
    let database: WalletDatabase

    func savedSelection() async -> CurrencyConverterSelection? {
        try? await database.currencyConverterSelection()
    }

    func saveSelection(_ selection: CurrencyConverterSelection) async {
        try? await database.saveCurrencyConverterSelection(selection)
    }

    func cachedDataset(
        localCurrency: WalletCurrencyContext
    ) async -> CurrencyConverterDataset {
        async let fxSnapshot = FXRatesClient.shared.cachedSnapshot()
        async let metalPrices = MetalPriceClient.shared.cachedPrices()
        async let walletAssets = selectedWalletAssets()

        let resolvedWalletAssets = await walletAssets
        let assetCandidates = Self.assetCandidates(
            heldAssets: resolvedWalletAssets
        )
        async let cachedAssetPrices = cachedUSDPrices(
            for: assetCandidates
        )

        return Self.dataset(
            fxSnapshot: await fxSnapshot,
            metalPrices: await metalPrices,
            assets: assetCandidates,
            assetPrices: await cachedAssetPrices,
            localCurrency: localCurrency
        )
    }

    func refreshedDataset(
        localCurrency: WalletCurrencyContext
    ) async -> CurrencyConverterDataset {
        async let fxSnapshot = refreshedFXSnapshot()
        async let metalPrices = refreshedMetalPrices()
        async let walletAssets = selectedWalletAssets()

        let resolvedWalletAssets = await walletAssets
        let assetCandidates = Self.assetCandidates(
            heldAssets: resolvedWalletAssets
        )
        let liveAssetPrices = await AssetPriceClient.usdPrices(
            for: assetCandidates,
            maximumConcurrentRequests: 6
        )

        return Self.dataset(
            fxSnapshot: await fxSnapshot,
            metalPrices: await metalPrices,
            assets: assetCandidates,
            assetPrices: liveAssetPrices,
            localCurrency: localCurrency
        )
    }

    private func refreshedFXSnapshot() async -> FXRatesSnapshot? {
        if let snapshot = try? await FXRatesClient.shared.latestSnapshot() {
            return snapshot
        }
        return await FXRatesClient.shared.cachedSnapshot()
    }

    private func refreshedMetalPrices() async
        -> [String: CurrencyConverterMarketPrice] {
        if let prices = try? await MetalPriceClient.shared.latestPrices() {
            return prices
        }
        return await MetalPriceClient.shared.cachedPrices()
    }

    private func selectedWalletAssets() async -> [WalletAsset] {
        guard let identity = try? await database.selectedWalletIdentity()
        else {
            return []
        }
        return (
            try? await database.currencyConverterPositiveBalanceAssets(
                walletID: identity.walletID
            )
        ) ?? []
    }

    private func cachedUSDPrices(
        for assets: [WalletAsset]
    ) async -> [String: Decimal] {
        await withTaskGroup(
            of: (String, Decimal?).self,
            returning: [String: Decimal].self
        ) { group in
            for asset in assets {
                group.addTask {
                    let cached = try? await database.cachedAssetUSDPrice(
                        assetID: asset.id
                    )
                    return (asset.id, cached?.price)
                }
            }

            var prices: [String: Decimal] = [:]
            for await (assetID, price) in group {
                if let price, price > 0 {
                    prices[assetID] = price
                }
            }
            return prices
        }
    }

    private static func dataset(
        fxSnapshot: FXRatesSnapshot?,
        metalPrices: [String: CurrencyConverterMarketPrice],
        assets: [WalletAsset],
        assetPrices: [String: Decimal],
        localCurrency: WalletCurrencyContext
    ) -> CurrencyConverterDataset {
        let fiatUnits = fiatUnits(
            snapshot: fxSnapshot,
            localCurrency: localCurrency
        )
        let metalUnits = metalUnits(prices: metalPrices)
        let cryptoUnits = cryptoUnits(
            assets: assets,
            prices: assetPrices
        )
        var fetchedDates = metalPrices.values.map(\.observedAt)
        if let fxFetchedAt = fxSnapshot?.fetchedAt {
            fetchedDates.append(fxFetchedAt)
        }
        return CurrencyConverterDataset(
            units: fiatUnits + metalUnits + cryptoUnits,
            fetchedAt: fetchedDates.max() ?? Date()
        )
    }

    private static func fiatUnits(
        snapshot: FXRatesSnapshot?,
        localCurrency: WalletCurrencyContext
    ) -> [CurrencyConverterUnit] {
        var rates = snapshot?.currencies ?? []
        if !rates.contains(where: { $0.code == "USD" }) {
            rates.append(
                FXCurrencyRate(
                    code: "USD",
                    englishName: "USD",
                    symbol: "$",
                    ratePerUSD: 1,
                    rateDate: ""
                )
            )
        }

        let localCode = localCurrency.code.uppercased()
        if localCode != "USD",
           localCurrency.ratePerUSD > 0,
           !rates.contains(where: { $0.code == localCode }) {
            let locale = Locale(identifier: "en_US")
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .currency
            formatter.currencyCode = localCode
            rates.append(
                FXCurrencyRate(
                    code: localCode,
                    englishName: locale.localizedString(
                        forCurrencyCode: localCode
                    ) ?? localCode,
                    symbol: formatter.currencySymbol ?? localCode,
                    ratePerUSD: localCurrency.ratePerUSD,
                    rateDate: ""
                )
            )
        }

        return rates
            .filter { $0.ratePerUSD > 0 }
            .sorted { $0.code < $1.code }
            .enumerated()
            .map { index, rate in
                CurrencyConverterUnit(
                    id: "fiat:\(rate.code.uppercased())",
                    code: rate.code.uppercased(),
                    englishName: rate.englishName,
                    symbol: rate.symbol,
                    kind: .fiat,
                    usdPricePerUnit: 1 / rate.ratePerUSD,
                    flag: CurrencyFlagResolver.flag(for: rate.code),
                    network: nil,
                    walletAssetID: nil,
                    logoSource: nil,
                    sortOrder: index
                )
            }
    }

    private static func metalUnits(
        prices: [String: CurrencyConverterMarketPrice]
    ) -> [CurrencyConverterUnit] {
        [
            (code: "XAU", name: "XAU"),
            (code: "XAG", name: "XAG")
        ].enumerated().map { index, metal in
            let unitID = "metal:\(metal.code)"
            return CurrencyConverterUnit(
                id: unitID,
                code: metal.code,
                englishName: metal.name,
                symbol: metal.code,
                kind: .metal,
                usdPricePerUnit: prices[unitID]?.priceUSD,
                flag: "",
                network: nil,
                walletAssetID: nil,
                logoSource: nil,
                sortOrder: index
            )
        }
    }

    private static func cryptoUnits(
        assets: [WalletAsset],
        prices: [String: Decimal]
    ) -> [CurrencyConverterUnit] {
        assets.enumerated().map { index, asset in
            let inferredPrice: Decimal? = if asset.balance > 0,
                                             asset.fiatValue > 0 {
                asset.fiatValue / asset.balance
            } else {
                nil
            }
            let liveOrCached = prices[asset.id]
            let resolvedPrice: Decimal? = if let liveOrCached,
                                   liveOrCached > 0 {
                liveOrCached
            } else if let inferredPrice, inferredPrice > 0 {
                inferredPrice
            } else {
                nil
            }
            return CurrencyConverterUnit(
                id: "asset:\(AssetIdentityKey.canonical(asset.id))",
                code: asset.symbol.uppercased(),
                englishName: asset.name,
                symbol: asset.symbol.uppercased(),
                kind: .crypto,
                usdPricePerUnit: resolvedPrice,
                flag: "",
                network: asset.network,
                walletAssetID: asset.id,
                logoSource: asset.logoSource,
                sortOrder: index
            )
        }
    }

    private static func assetCandidates(
        heldAssets: [WalletAsset]
    ) -> [WalletAsset] {
        let sortedHeldAssets = heldAssets
            .filter { $0.balance > 0 && !$0.isSpam }
            .sorted {
                if $0.fiatValue == $1.fiatValue {
                    return $0.name.localizedStandardCompare($1.name)
                        == .orderedAscending
                }
                return $0.fiatValue > $1.fiatValue
            }
        let heldByID = Dictionary(
            sortedHeldAssets.map {
                (AssetIdentityKey.canonical($0.id), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var seen = Set<String>()
        var result: [WalletAsset] = []
        for coreAsset in coreAssets {
            let identity = AssetIdentityKey.canonical(coreAsset.id)
            result.append(heldByID[identity] ?? coreAsset)
            seen.insert(identity)
        }
        for asset in sortedHeldAssets {
            let identity = AssetIdentityKey.canonical(asset.id)
            if seen.insert(identity).inserted {
                result.append(asset)
            }
        }
        return result
    }

    private static let coreAssets: [WalletAsset] = [
        WalletAsset(
            id: "bitcoin:native",
            name: BitcoinFamilyChain.bitcoin.name,
            symbol: "BTC",
            logoSource: .nativeCoin(blockchain: .bitcoin),
            network: .bitcoin,
            balance: 0,
            fiatValue: 0,
            decimals: 8
        ),
        WalletAsset(
            id: "eth:native",
            name: WalletLocalization.string(
                "wallet.asset.ethereum.name"
            ),
            symbol: "ETH",
            logoSource: .nativeCoin(blockchain: .ethereum),
            network: .ethereum,
            balance: 0,
            fiatValue: 0,
            decimals: 18
        ),
        WalletAsset(
            id: "solana:native",
            name: WalletLocalization.string("network.solana.name"),
            symbol: "SOL",
            logoSource: .nativeCoin(blockchain: .solana),
            network: .solana,
            balance: 0,
            fiatValue: 0,
            decimals: 9
        ),
        WalletAsset(
            id: XRPConstants.nativeAssetID,
            name: WalletLocalization.string(
                XRPConstants.nativeAssetNameKey
            ),
            symbol: XRPConstants.nativeSymbol,
            logoSource: .nativeCoin(blockchain: .xrp),
            network: .xrp,
            balance: 0,
            fiatValue: 0,
            decimals: XRPConstants.decimals
        ),
        WalletAsset(
            id: StellarConstants.nativeAssetID,
            name: WalletLocalization.string(
                StellarConstants.nativeAssetNameKey
            ),
            symbol: StellarConstants.nativeSymbol,
            logoSource: .nativeCoin(blockchain: .stellar),
            network: .stellar,
            balance: 0,
            fiatValue: 0,
            decimals: StellarConstants.decimals
        )
    ]
}
