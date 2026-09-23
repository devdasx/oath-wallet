import Foundation

/// Decodes provider prices without converting through binary floating point.
/// Public market APIs are inconsistent: some emit JSON strings while others
/// emit JSON numbers for the same financial field.
struct AssetPriceJSONDecimal: Decodable, Equatable, Sendable {
    let value: Decimal

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self),
           let decimal = Decimal(
               string: text,
               locale: Locale(identifier: "en_US_POSIX")
           ) {
            value = decimal
            return
        }
        if let decimal = try? container.decode(Decimal.self) {
            value = decimal
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected a base-10 JSON number or string."
        )
    }
}

extension AssetPriceClient {
    static func fetchPrice(
        for asset: WalletAsset,
        session: URLSession
    ) async throws -> AssetUSDPrice {
        if priceContractAddress(for: asset) != nil {
            return try await fetchTokenPrice(for: asset, session: session)
        }
        let serviceID = "asset_usd_price_" + AdaptiveProviderIdentity.opaqueID(asset.id)
        let attempts = nativePriceAttempts(
            asset: asset, marketID: coinGeckoID(for: asset),
            serviceID: serviceID, session: session
        )
        guard !attempts.isEmpty else { throw AssetPriceError.unsupportedAsset }
        return try await AdaptiveProviderRouter.shared.executeRead(
            serviceID: serviceID, attempts: attempts,
            timeoutSeconds: 4, overallTimeoutSeconds: 16,
            shouldFallback: { priceProviderShouldFallback($0) }
        )
    }

    static func coinbasePrice(
        symbol: String,
        session: URLSession
    ) async throws -> Decimal {
        let provider = "coinbase"
        var components = URLComponents(
            string: "https://api.coinbase.com/v2/exchange-rates"
        )
        components?.queryItems = [
            URLQueryItem(name: "currency", value: normalizedSymbol(symbol))
        ]
        guard let url = components?.url else {
            throw providerFailure(provider, .invalidURL)
        }
        let response: CoinbaseEnvelope = try await request(
            url,
            provider: provider,
            session: session
        )
        guard response.data.currency.caseInsensitiveCompare(symbol)
                == .orderedSame else {
            throw providerFailure(provider, .identityMismatch)
        }
        guard let rawPrice = response.data.rates["USD"],
              let price = decimal(rawPrice),
              price > 0 else {
            throw providerFailure(provider, .missingPrice)
        }
        return price
    }

    static func coinGeckoPrice(
        coinID: String,
        session: URLSession
    ) async throws -> Decimal {
        let provider = "coingecko"
        var components = URLComponents(
            string: "https://api.coingecko.com/api/v3/simple/price"
        )
        components?.queryItems = [
            URLQueryItem(name: "ids", value: coinID),
            URLQueryItem(name: "vs_currencies", value: "usd"),
            URLQueryItem(name: "precision", value: "full")
        ]
        guard let url = components?.url else {
            throw providerFailure(provider, .invalidURL)
        }
        let response: [String: CoinGeckoQuote] = try await request(
            url,
            provider: provider,
            session: session
        )
        guard let price = response[coinID]?.usd?.value, price > 0 else {
            throw providerFailure(provider, .missingPrice)
        }
        return price
    }

    static func coinGeckoContractPrice(
        asset: WalletAsset,
        session: URLSession
    ) async throws -> Decimal {
        let provider = exactContractPriceProvider
        guard let contract = priceContractAddress(for: asset),
              let network = asset.network,
              let platform = coinGeckoPlatformID(network) else {
            throw AssetPriceError.unsupportedAsset
        }
        var components = URLComponents(
            string: "https://api.coingecko.com/api/v3/simple/token_price/\(platform)"
        )
        components?.queryItems = [
            URLQueryItem(name: "contract_addresses", value: contract),
            URLQueryItem(name: "vs_currencies", value: "usd"),
            URLQueryItem(name: "precision", value: "full")
        ]
        guard let url = components?.url else {
            throw providerFailure(provider, .invalidURL)
        }
        let response: [String: CoinGeckoQuote] = try await request(
            url,
            provider: provider,
            session: session
        )
        guard let quote = response.first(where: {
            assetIdentityMatches(
                providerValue: $0.key,
                requestedValue: contract,
                network: network
            )
        }) else {
            throw providerFailure(provider, .missingPrice)
        }
        guard let price = quote.value.usd?.value, price > 0 else {
            throw providerFailure(provider, .missingPrice)
        }
        return price
    }

    static func defiLlamaMarketPrice(
        marketID: String,
        session: URLSession
    ) async throws -> Decimal {
        let provider = defiLlamaMarketPriceProvider
        let identifier = "coingecko:\(marketID)"
        let response = try await defiLlamaPrices(
            identifier: identifier,
            provider: provider,
            session: session
        )
        guard let quote = response.coins[identifier],
              quote.price.value > 0 else {
            throw providerFailure(provider, .missingPrice)
        }
        return quote.price.value
    }

    static func defiLlamaContractPrice(
        asset: WalletAsset,
        session: URLSession
    ) async throws -> Decimal {
        let provider = defiLlamaContractPriceProvider
        guard let contract = priceContractAddress(for: asset),
              let network = asset.network,
              let chain = defiLlamaChainID(network) else {
            throw AssetPriceError.unsupportedAsset
        }
        let identifier = "\(chain):\(contract)"
        let response = try await defiLlamaPrices(
            identifier: identifier,
            provider: provider,
            session: session
        )
        guard let quote = response.coins.first(where: {
            defiLlamaIdentifierMatches(
                providerValue: $0.key,
                chain: chain,
                contract: contract,
                network: network
            )
        })?.value,
              quote.price.value > 0 else {
            throw providerFailure(provider, .missingPrice)
        }
        return quote.price.value
    }

    static func geckoTerminalContractPrice(
        asset: WalletAsset,
        session: URLSession
    ) async throws -> Decimal {
        let provider = geckoTerminalContractPriceProvider
        guard let contract = onChainProviderTokenAddress(for: asset),
              let network = asset.network,
              let providerNetwork = geckoTerminalNetworkID(network),
              let encodedContract = encodedPathComponent(contract),
              let url = URL(
                  string: "https://api.geckoterminal.com/api/v2/simple/networks/\(providerNetwork)/token_price/\(encodedContract)"
              ) else {
            throw AssetPriceError.unsupportedAsset
        }
        let response: GeckoTerminalEnvelope = try await request(
            url,
            provider: provider,
            accept: "application/json;version=20230203",
            session: session
        )
        guard let entry = response.data.attributes.tokenPrices.first(where: {
            assetIdentityMatches(
                providerValue: $0.key,
                requestedValue: contract,
                network: network
            )
        }), let quote = entry.value, quote.value > 0 else {
            throw providerFailure(provider, .missingPrice)
        }
        return quote.value
    }

    static func dexScreenerContractPrice(
        asset: WalletAsset,
        session: URLSession
    ) async throws -> Decimal {
        let provider = dexScreenerContractPriceProvider
        guard let contract = onChainProviderTokenAddress(for: asset),
              let network = asset.network,
              let providerNetwork = dexScreenerNetworkID(network),
              let encodedContract = encodedPathComponent(contract),
              let url = URL(
                  string: "https://api.dexscreener.com/token-pairs/v1/\(providerNetwork)/\(encodedContract)"
              ) else {
            throw AssetPriceError.unsupportedAsset
        }
        let pairs: [DexScreenerPair] = try await request(
            url,
            provider: provider,
            session: session
        )
        let candidates = pairs.compactMap { pair -> DexPriceCandidate? in
            guard pair.chainID == providerNetwork,
                  assetIdentityMatches(
                      providerValue: pair.baseToken.address,
                      requestedValue: contract,
                      network: network
                  ),
                  let price = pair.priceUSD?.value,
                  price > 0 else {
                return nil
            }
            return DexPriceCandidate(
                price: price,
                liquidityUSD: max(pair.liquidity?.usd?.value ?? 0, 0)
            )
        }
        guard let selected = robustDexPrice(candidates) else {
            throw providerFailure(provider, .missingPrice)
        }
        return selected
    }

    static func tonAPIContractPrice(
        asset: WalletAsset,
        session: URLSession
    ) async throws -> Decimal {
        guard asset.network == .ton,
              let contract = priceContractAddress(for: asset) else {
            throw AssetPriceError.unsupportedAsset
        }
        return try await tonAPIPrice(
            token: contract,
            provider: tonAPIContractPriceProvider,
            session: session
        )
    }

    static func coinLoreNativePrice(
        network: WalletBlockchain,
        session: URLSession
    ) async throws -> Decimal {
        let provider = "coinlore-native-v1"
        guard let identity = coinLoreNativeIdentity(network) else {
            throw AssetPriceError.unsupportedAsset
        }
        var components = URLComponents(
            string: "https://api.coinlore.net/api/ticker/"
        )
        components?.queryItems = [
            URLQueryItem(name: "id", value: identity.id)
        ]
        guard let url = components?.url else {
            throw providerFailure(provider, .invalidURL)
        }
        let response: [CoinLoreQuote] = try await request(
            url,
            provider: provider,
            session: session
        )
        guard let quote = response.first,
              quote.id == identity.id,
              quote.nameID == identity.nameID else {
            throw providerFailure(provider, .identityMismatch)
        }
        guard let price = quote.priceUSD?.value, price > 0 else {
            throw providerFailure(provider, .missingPrice)
        }
        return price
    }

    static func krakenPrice(
        symbol: String,
        session: URLSession
    ) async throws -> Decimal {
        let provider = "kraken"
        let base = normalizedSymbol(symbol) == "BTC"
            ? "XBT"
            : normalizedSymbol(symbol)
        var components = URLComponents(
            string: "https://api.kraken.com/0/public/Ticker"
        )
        components?.queryItems = [
            URLQueryItem(name: "pair", value: base + "USD")
        ]
        guard let url = components?.url else {
            throw providerFailure(provider, .invalidURL)
        }
        let response: KrakenEnvelope = try await request(
            url,
            provider: provider,
            session: session
        )
        guard response.error.isEmpty,
              let quote = response.result.values.first,
              let rawPrice = quote.close.first,
              let price = decimal(rawPrice),
              price > 0 else {
            throw providerFailure(provider, .missingPrice)
        }
        return price
    }

    static func coinGeckoID(for asset: WalletAsset) -> String? {
        guard
            let network = asset.network,
            let networkID = ReceiveNetworkCatalog.catalogNetwork(
                for: network
            )?.id
        else {
            return nil
        }
        if let remoteID = ReceiveAssetCatalog.marketDataID(
            for: AssetIdentityKey.make(
                networkID: networkID,
                contractAddress: priceContractAddress(for: asset)
            )
        ) {
            return remoteID
        }
        guard priceContractAddress(for: asset) == nil else {
            return nil
        }
        return nativeCoinGeckoID(for: network)
    }

    /// Native market identities are operational pricing configuration. They
    /// remain available before the first remote catalog sync, while an exact
    /// catalog market ID still takes precedence whenever present.
    static func nativeCoinGeckoID(
        for network: WalletBlockchain
    ) -> String {
        switch network {
        case .aptos: "aptos"
        case .stellar: "stellar"
        case .xrp: "ripple"
        case .near: "near"
        case .sui: "sui"
        case .ton: "the-open-network"
        case .solana: "solana"
        case .tron: "tron"
        case .bitcoin: "bitcoin"
        case .bitcoincash: "bitcoin-cash"
        case .litecoin: "litecoin"
        case .dogecoin: "dogecoin"
        case .ethereum, .arbitrum, .optimism, .base,
             .scroll, .linea, .taiko:
            "ethereum"
        case .smartchain: "binancecoin"
        case .polygon: "polygon-ecosystem-token"
        case .avalanchec: "avalanche-2"
        case .xdai: "xdai"
        case .telos: "telos"
        case .xlayer: "okb"
        case .arc: "usd-coin"
        }
    }

    static func coinGeckoPlatformID(
        _ network: WalletBlockchain
    ) -> String? {
        switch network {
        case .aptos: "aptos"
        case .stellar, .xrp, .ton,
             .bitcoin, .bitcoincash, .litecoin, .dogecoin:
            nil
        case .near: "near-protocol"
        case .sui: "sui"
        case .solana: "solana"
        case .tron: "tron"
        case .ethereum: "ethereum"
        case .smartchain: "binance-smart-chain"
        case .polygon: "polygon-pos"
        case .arbitrum: "arbitrum-one"
        case .avalanchec: "avalanche"
        case .optimism: "optimistic-ethereum"
        case .base: "base"
        case .xdai: "xdai"
        case .scroll: "scroll"
        case .linea: "linea"
        case .taiko: "taiko"
        case .telos: "telos"
        case .xlayer: "x-layer"
        case .arc: "arc"
        }
    }
}

extension AssetPriceClient {
    struct DexPriceCandidate: Sendable {
        let price: Decimal
        let liquidityUSD: Decimal
    }

    static func nativePriceAttempts(
        asset: WalletAsset,
        marketID: String?,
        serviceID: String,
        session: URLSession
    ) -> [AdaptiveProviderAttempt<AssetUSDPrice>] {
        guard let network = asset.network, let marketID else { return [] }
        var attempts: [AdaptiveProviderAttempt<AssetUSDPrice>] = []
        attempts.append(priceAttempt(
            serviceID: serviceID,
            endpointURL: URL(
                string: "https://api.coinbase.com/v2/exchange-rates"
            )!,
            priority: 0,
            asset: asset,
            provider: "coinbase"
        ) {
            try await coinbasePrice(
                symbol: providerSymbol(for: asset),
                session: session
            )
        })
        attempts.append(priceAttempt(
            serviceID: serviceID,
            endpointURL: URL(
                string: "https://api.coingecko.com/api/v3/simple/price"
            )!,
            priority: 1,
            asset: asset,
            provider: "coingecko"
        ) {
            try await coinGeckoPrice(coinID: marketID, session: session)
        })
        attempts.append(priceAttempt(
            serviceID: serviceID,
            endpointURL: URL(
                string: "https://coins.llama.fi/prices/current"
            )!,
            priority: 2,
            asset: asset,
            provider: defiLlamaMarketPriceProvider
        ) {
            try await defiLlamaMarketPrice(
                marketID: marketID,
                session: session
            )
        })
        if coinLoreNativeIdentity(network) != nil {
            attempts.append(priceAttempt(
                serviceID: serviceID,
                endpointURL: URL(
                    string: "https://api.coinlore.net/api/ticker/"
                )!,
                priority: 3,
                asset: asset,
                provider: "coinlore-native-v1"
            ) {
                try await coinLoreNativePrice(
                    network: network,
                    session: session
                )
            })
        }
        if network == .ton {
            attempts.append(priceAttempt(
                serviceID: serviceID,
                endpointURL: URL(string: "https://tonapi.io/v2/rates")!,
                priority: 4,
                asset: asset,
                provider: "tonapi-native-v1"
            ) {
                try await tonAPIPrice(
                    token: "gram",
                    provider: "tonapi-native-v1",
                    session: session
                )
            })
        }
        attempts.append(priceAttempt(
            serviceID: serviceID,
            endpointURL: URL(
                string: "https://api.kraken.com/0/public/Ticker"
            )!,
            priority: 5,
            asset: asset,
            provider: "kraken"
        ) {
            try await krakenPrice(
                symbol: providerSymbol(for: asset),
                session: session
            )
        })
        return attempts
    }

    static func priceAttempt(
        serviceID: String,
        endpointURL: URL,
        priority: Int,
        asset: WalletAsset,
        provider: String,
        operation: @escaping @Sendable () async throws -> Decimal
    ) -> AdaptiveProviderAttempt<AssetUSDPrice> {
        let endpoint = AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: endpointURL,
            baselinePriority: priority
        )
        return AdaptiveProviderAttempt(endpoint: endpoint) {
            makePrice(
                asset: asset,
                price: try await operation(),
                provider: provider
            )
        }
    }

    static func priceProviderShouldFallback(_ error: Error) -> Bool {
        ProviderReliabilityClassification.isRetryableTransport(error)
            || error is AssetPriceError
    }

    static func request<Response: Decodable>(
        _ url: URL,
        provider: String,
        accept: String = "application/json",
        session: URLSession
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw providerFailure(provider, .httpStatus)
        }
        guard 200..<300 ~= http.statusCode else {
            throw providerFailure(
                provider,
                .httpStatus,
                statusCode: http.statusCode
            )
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw providerFailure(provider, .decoding)
        }
    }

    static func defiLlamaPrices(
        identifier: String,
        provider: String,
        session: URLSession
    ) async throws -> DefiLlamaEnvelope {
        guard let encoded = encodedPathComponent(identifier),
              let url = URL(
                  string: "https://coins.llama.fi/prices/current/\(encoded)"
              ) else {
            throw providerFailure(provider, .invalidURL)
        }
        return try await request(
            url,
            provider: provider,
            session: session
        )
    }

    static func tonAPIPrice(
        token: String,
        provider: String,
        session: URLSession
    ) async throws -> Decimal {
        var components = URLComponents(string: "https://tonapi.io/v2/rates")
        components?.queryItems = [
            URLQueryItem(name: "tokens", value: token),
            URLQueryItem(name: "currencies", value: "usd")
        ]
        guard let url = components?.url else {
            throw providerFailure(provider, .invalidURL)
        }
        let response: TonAPIRatesEnvelope = try await request(
            url,
            provider: provider,
            session: session
        )
        let requestedKey = token == "gram" ? "GRAM" : token
        guard let rate = response.rates.first(where: {
            $0.key == requestedKey
        })?.value,
              let entry = rate.prices.first(where: {
                  $0.key.caseInsensitiveCompare("USD") == .orderedSame
              }), let quote = entry.value, quote.value > 0 else {
            throw providerFailure(provider, .missingPrice)
        }
        return quote.value
    }

    static func robustDexPrice(
        _ candidates: [DexPriceCandidate]
    ) -> Decimal? {
        guard !candidates.isEmpty else { return nil }
        let sample = Array(candidates.sorted {
            if $0.liquidityUSD == $1.liquidityUSD {
                return $0.price < $1.price
            }
            return $0.liquidityUSD > $1.liquidityUSD
        }.prefix(9))
        let sortedPrices = sample.map(\.price).sorted()
        let median: Decimal
        if sortedPrices.count.isMultiple(of: 2) {
            let upper = sortedPrices.count / 2
            median = (sortedPrices[upper - 1] + sortedPrices[upper]) / 2
        } else {
            median = sortedPrices[sortedPrices.count / 2]
        }
        let lowerBound = median * Decimal(string: "0.8")!
        let upperBound = median * Decimal(string: "1.2")!
        let consensus = sample.filter {
            $0.price >= lowerBound && $0.price <= upperBound
        }
        return (consensus.isEmpty ? sample : consensus).max {
            $0.liquidityUSD < $1.liquidityUSD
        }?.price
    }

    static func assetIdentityMatches(
        providerValue: String,
        requestedValue: String,
        network: WalletBlockchain
    ) -> Bool {
        if networkUsesCaseInsensitiveContractIdentity(network) {
            return providerValue.caseInsensitiveCompare(requestedValue)
                == .orderedSame
        }
        return providerValue == requestedValue
    }

    static func defiLlamaIdentifierMatches(
        providerValue: String,
        chain: String,
        contract: String,
        network: WalletBlockchain
    ) -> Bool {
        let prefix = chain + ":"
        guard providerValue.hasPrefix(prefix) else { return false }
        return assetIdentityMatches(
            providerValue: String(providerValue.dropFirst(prefix.count)),
            requestedValue: contract,
            network: network
        )
    }

    static func networkUsesCaseInsensitiveContractIdentity(
        _ network: WalletBlockchain
    ) -> Bool {
        switch network {
        case .ethereum, .smartchain, .polygon, .arbitrum,
             .avalanchec, .optimism, .base, .xdai, .scroll,
             .linea, .taiko, .telos, .xlayer, .arc:
            true
        default:
            false
        }
    }

    static func encodedPathComponent(_ value: String) -> String? {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-._~")
            )
        )
    }

    static func providerFailure(
        _ provider: String,
        _ reason: AssetPriceProviderFailureReason,
        statusCode: Int? = nil
    ) -> AssetPriceError {
        .providerFailure(
            provider: provider,
            reason: reason,
            statusCode: statusCode
        )
    }

    static func makePrice(
        asset: WalletAsset,
        price: Decimal,
        provider: String
    ) -> AssetUSDPrice {
        AssetUSDPrice(
            assetID: asset.id,
            price: price,
            provider: provider,
            observedAt: Date()
        )
    }

    static func normalizedSymbol(_ symbol: String) -> String {
        symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func providerSymbol(for asset: WalletAsset) -> String {
        if asset.network == .ton,
           priceContractAddress(for: asset) == nil {
            return TONConstants.providerRateSymbol
        }
        return asset.symbol
    }

    static func decimal(_ value: String) -> Decimal? {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }
}
