import Foundation

/// A public asset identity only. Never contains the user's wallet/account address.
public struct MarketAsset: Hashable, Sendable {
    public let id: String
    public let networkID: String
    public let reference: String
    public let decimals: Int
    public init(id: String, networkID: String, reference: String, decimals: Int) {
        self.id = id; self.networkID = networkID
        self.reference = reference; self.decimals = decimals
    }
    public var isNative: Bool { reference == "native" }
    var cacheIdentity: String { "\(id.count):\(id)|\(networkID)|\(reference)|\(decimals)" }
    var evm: Bool { !["solana", "tron", "ton", "aptos", "sui", "near", "thorchain", "xrpl", "stellar", "polkadot"].contains(networkID) }
    func matches(_ contract: String) -> Bool {
        evm ? reference.lowercased() == contract.lowercased() : reference == contract
    }
}

public struct MarketQuote: Codable, Equatable, Sendable {
    public let code: String
    public let usd: String
    public var decimal: Decimal? { Decimal(string: usd, locale: Locale(identifier: "en_US_POSIX")) }
}

public struct AssetInformation: Codable, Equatable, Sendable {
    public let providerID: String
    public let name: String
    public let symbol: String
    public let description: String
    public let imageURL: String?
    public let website: String?
    public let providerURL: String
    public let marketCaps: [String: Decimal]?
    public let totalSupply: Decimal?
    public let circulatingSupply: Decimal?

    public init(providerID: String, name: String, symbol: String, description: String,
                imageURL: String?, website: String?, providerURL: String,
                marketCaps: [String: Decimal]? = nil, totalSupply: Decimal? = nil,
                circulatingSupply: Decimal? = nil) {
        self.providerID = providerID; self.name = name; self.symbol = symbol
        self.description = description; self.imageURL = imageURL; self.website = website
        self.providerURL = providerURL; self.marketCaps = marketCaps
        self.totalSupply = totalSupply; self.circulatingSupply = circulatingSupply
    }
}

public struct MarketCandle: Codable, Equatable, Sendable, Identifiable {
    public let time: Double
    public let close: Double
    public var id: Double { time }
}

public struct MarketChart: Codable, Equatable, Sendable {
    public let points: [MarketCandle]
    public let changePercent: Double?
}

public struct CachedMarketValue<Value: Sendable>: Sendable {
    public let value: Value
    public let fetchedAt: Date
    public func isFresh(at date: Date = Date(), lifetime: TimeInterval) -> Bool {
        let age = date.timeIntervalSince(fetchedAt)
        return age >= -300 && age < lifetime
    }
}

public enum MarketDataError: Error, Sendable, Equatable {
    case unavailable, invalidResponse, notListed, rateLimited
}

/// Native gas assets are mapped by network, never by a user-editable symbol.
/// In particular ETH rollups are ETH (not ARB/OP/SCR/TAIKO governance tokens).
public enum MarketIdentity {
    public static let native: [String: (coinbase: String, gecko: String)] = [
        "bitcoin": ("BTC", "bitcoin"), "ethereum": ("ETH", "ethereum"),
        "arbitrum": ("ETH", "ethereum"), "base": ("ETH", "ethereum"),
        "linea": ("ETH", "ethereum"), "optimism": ("ETH", "ethereum"),
        "iotex": ("IOTX", "iotex"), "zerog": ("0G", "zero-gravity"), "sei": ("SEI", "sei-network"), "filecoin": ("FIL", "filecoin"), "chiliz": ("CHZ", "chiliz"), "celo": ("CELO", "celo"), "monad": ("MON", "monad"), "unichain": ("ETH", "ethereum"), "hyperevm": ("HYPE", "hyperliquid"), "robinhood": ("ETH", "ethereum"), "scroll": ("ETH", "ethereum"), "taiko": ("ETH", "ethereum"),
        "arc": ("USDC", "usd-coin"), "avalanche": ("AVAX", "avalanche-2"),
        "bnb": ("BNB", "binancecoin"), "polygon": ("POL", "polygon-ecosystem-token"),
        "fantom": ("FTM", "fantom"), "flare": ("FLR", "flare-networks"), "somnia": ("SOMI", "somnia"),
        "gnosis": ("XDAI", "xdai"), "solana": ("SOL", "solana"),
        "tron": ("TRX", "tron"), "ton": ("TON", "the-open-network"),
        "aptos": ("APT", "aptos"), "bitcoincash": ("BCH", "bitcoin-cash"),
        "dogecoin": ("DOGE", "dogecoin"), "litecoin": ("LTC", "litecoin"),
        "thorchain": ("RUNE", "thorchain"), "near": ("NEAR", "near"), "polkadot": ("DOT", "polkadot"), "stellar": ("XLM", "stellar"),
        "sui": ("SUI", "sui"), "telos": ("TLOS", "telos"),
        "xlayer": ("OKB", "okb"), "xrpl": ("XRP", "ripple")
    ]
    static let geckoPlatforms = [
        "ethereum": "ethereum", "arbitrum": "arbitrum-one", "arc": "arc",
        "avalanche": "avalanche", "base": "base", "bnb": "binance-smart-chain",
        "fantom": "fantom", "flare": "flare-network", "somnia": "somnia", "story": "story",
        "gnosis": "xdai", "linea": "linea", "optimism": "optimistic-ethereum",
        "iotex": "iotex", "zerog": "0g", "sei": "sei-v2", "filecoin": "filecoin", "chiliz": "chiliz", "celo": "celo", "monad": "monad", "unichain": "unichain", "hyperevm": "hyperevm", "robinhood": "robinhood", "polygon": "polygon-pos", "scroll": "scroll", "taiko": "taiko",
        "telos": "telos", "xlayer": "x-layer", "tron": "tron", "solana": "solana", "thorchain": "thorchain"
    ]
    static let coinbaseNetworks = ["avalanche": "avacchain", "bnb": "bsc", "xrpl": "ripple"]

    // Same exact denomination mapping used by the THORChain price catalog.
    // Never resolve a bank denomination by symbol/name alone. The response is
    // still checked against its THORChain denomination and decimals.
    static let thorchainProjects = ["x/ruji": "rujira"]

    // Coinbase's currency directory leaves some multi-network contract fields
    // empty. Explicit issuer contracts fill those omissions, never ticker guesses.
    static let issuerContracts: [String: [String: String]] = [
        "USDC": [
            "arbitrum": "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
            "base": "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
            "optimism": "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
            "tron": "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"
        ],
        "USDT": ["tron": "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"]
    ]

    public static func informationURL(for asset: MarketAsset) throws -> URL {
        var path: String
        if asset.isNative, let mapping = native[asset.networkID] { path = mapping.gecko }
        else if asset.networkID == "thorchain", let project = thorchainProjects[asset.reference] { path = project }
        else if let platform = geckoPlatforms[asset.networkID], validReference(asset.reference) {
            path = platform + "/contract/" + asset.reference
        } else { throw MarketDataError.notListed }
        return URL(string: "https://api.coingecko.com/api/v3/coins/" + path +
            "?localization=false&tickers=false&market_data=true&community_data=false&developer_data=false")!
    }
    static func validReference(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    static func chartURL(for asset: MarketAsset) throws -> URL {
        var url = URLComponents(url: try informationURL(for: asset), resolvingAgainstBaseURL: false)!
        url.path += "/market_chart"
        url.queryItems = [.init(name: "vs_currency", value: "usd"), .init(name: "days", value: "1")]
        return url.url!
    }
}
