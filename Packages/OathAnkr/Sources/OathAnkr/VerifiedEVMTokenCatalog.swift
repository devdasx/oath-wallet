import Foundation

/// Contract identities from CoinGecko's chain-specific token lists. A price,
/// ticker, logo, or appearance in an unfiltered transfer response is not trust.
public struct VerifiedEVMTokenCatalog: Codable, Sendable {
    public let networkID: String
    public let decimalsByReference: [String: Int]
    /// Some CoinGecko platform directories publish identity without precision.
    /// These entries never supply decimals or amounts; the chain remains authoritative.
    public var referencesWithoutDecimals: [String]? = nil

    public static func source(for chain: AnkrChain) -> (platform: String, chainID: Int) {
        switch chain {
        case .eth: ("ethereum", 1)
        case .arbitrum: ("arbitrum-one", 42161)
        case .avalanche: ("avalanche", 43114)
        case .base: ("base", 8453)
        case .bsc: ("binance-smart-chain", 56)
        case .fantom: ("fantom", 250)
        case .flare: ("flare-network", 14)
        case .gnosis: ("xdai", 100)
        case .linea: ("linea", 59144)
        case .optimism: ("optimistic-ethereum", 10)
        case .polygon: ("polygon-pos", 137)
        case .scroll: ("scroll", 534352)
        case .somnia: ("somnia", 5031)
        case .story: ("story", 1514)
        case .taiko: ("taiko", 167000)
        case .telos: ("telos", 40)
        case .xlayer: ("x-layer", 196)
        }
    }

    public static func decode(_ data: Data, chain: AnkrChain) throws -> Self {
        struct List: Decodable {
            struct Token: Decodable { let chainId: Int; let address: String; let decimals: Int }
            let tokens: [Token]
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        guard !list.tokens.isEmpty, list.tokens.count <= 100_000 else { throw AnkrError.invalidResponse }
        var values: [String: Int] = [:]
        for token in list.tokens {
            guard token.chainId == source(for: chain).chainID, AnkrQuantity.address(token.address),
                  (0...255).contains(token.decimals) else { throw AnkrError.invalidResponse }
            let reference = token.address.lowercased()
            if let previous = values[reference], previous != token.decimals { throw AnkrError.invalidResponse }
            values[reference] = token.decimals
        }
        return Self(networkID: chain.networkID, decimalsByReference: values)
    }

    public static func decodeCoinList(_ data: Data, chain: AnkrChain) throws -> Self {
        struct Coin: Decodable { let platforms: [String: String?]? }
        let coins = try JSONDecoder().decode([Coin].self, from: data)
        guard coins.count <= 100_000 else { throw AnkrError.invalidResponse }
        let platform = source(for: chain).platform
        let references = Set(try coins.compactMap { coin -> String? in
            guard let value = coin.platforms?[platform] ?? nil, !value.isEmpty else { return nil }
            guard AnkrQuantity.address(value) else { throw AnkrError.invalidResponse }
            return value.lowercased()
        })
        guard !references.isEmpty else { throw AnkrError.invalidResponse }
        return Self(networkID: chain.networkID, decimalsByReference: [:], referencesWithoutDecimals: references.sorted())
    }

    public static func fetch(chain: AnkrChain, transport: any AnkrTransport = AnkrHTTPTransport()) async throws -> Self {
        // Taiko has a published CoinGecko platform directory but no downloadable
        // token-list endpoint (HTTP 403). Read its exact contract identities here.
        let url = URL(string: chain == .taiko
            ? "https://api.coingecko.com/api/v3/coins/list?include_platform=true"
            : "https://tokens.coingecko.com/\(source(for: chain).platform)/all.json")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await transport.send(request)
        guard status == 200 else { throw AnkrError.http(status) }
        return try chain == .taiko ? decodeCoinList(data, chain: chain) : decode(data, chain: chain)
    }
}
