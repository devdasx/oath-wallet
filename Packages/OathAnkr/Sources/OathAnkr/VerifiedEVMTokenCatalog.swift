import Foundation
import OathDiagnostics

/// Contract identities from CoinGecko's chain-specific token lists. A price,
/// ticker, logo, or appearance in an unfiltered transfer response is not trust.
public struct VerifiedEVMTokenCatalog: Codable, Sendable {
    public let networkID: String
    public let decimalsByReference: [String: Int]
    /// Some CoinGecko platform directories publish identity without precision.
    /// These entries never supply decimals or amounts; the chain remains authoritative.
    public var referencesWithoutDecimals: [String]? = nil

    static let independentLists: [AnkrChain: URL] = [
        .telos: URL(string: "https://raw.githubusercontent.com/telosnetwork/token-list/main/telosevm.tokenlist.json")!,
        .xlayer: URL(string: "https://raw.githubusercontent.com/okx/xlayer-tokenlist/main/xlayer.tokenlist.json")!
    ]
    static var independentURLs: Set<URL> { Set(independentLists.values) }
    public var source: String? = nil

    public func retainingVerifiedEntries(from previous: Self?) throws -> Self {
        guard source != nil, let previous, previous.networkID == networkID else { return self }
        var values = previous.decimalsByReference
        for (reference, decimals) in decimalsByReference {
            if let old = values[reference], old != decimals { throw AnkrError.invalidResponse }
            values[reference] = decimals
        }
        let references = Set((previous.referencesWithoutDecimals ?? []) + (referencesWithoutDecimals ?? []))
            .subtracting(values.keys)
        guard values.count + references.count <= 100_000 else { throw AnkrError.invalidResponse }
        return Self(networkID: networkID, decimalsByReference: values,
            referencesWithoutDecimals: references.sorted(), source: source)
    }

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

    public static func decode(_ data: Data, chain: AnkrChain, allowsOtherChains: Bool = false) throws -> Self {
        struct List: Decodable {
            struct Token: Decodable { let chainId: Int; let address: String; let decimals: Int }
            let tokens: [Token]
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        guard !list.tokens.isEmpty, list.tokens.count <= 100_000 else { throw AnkrError.invalidResponse }
        var values: [String: Int] = [:]
        for token in list.tokens {
            if allowsOtherChains && token.chainId != source(for: chain).chainID { continue }
            guard token.chainId == source(for: chain).chainID, AnkrQuantity.address(token.address),
                  (0...255).contains(token.decimals) else { throw AnkrError.invalidResponse }
            let reference = token.address.lowercased()
            if let previous = values[reference], previous != token.decimals { throw AnkrError.invalidResponse }
            values[reference] = token.decimals
        }
        guard !values.isEmpty else { throw AnkrError.invalidResponse }
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
        if chain != .taiko {
            do {
                let data = try await read(URL(string: "https://tokens.coingecko.com/\(source(for: chain).platform)/all.json")!, transport: transport)
                return try decode(data, chain: chain)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // Recover unavailable public lists only. Invalid identities or
                // precision in an otherwise successful response remain errors.
                let canFallback: Bool
                switch error as? AnkrError {
                case .transport, .http(403), .http(404), .http(408), .http(429),
                     .http(500), .http(502), .http(503), .http(504): canFallback = true
                default: canFallback = false
                }
                guard canFallback || error is DiagnosticDeferral else { throw error }
                OathDiagnostics.record(error, component: "token_catalog", operation: "directory_fallback",
                    context: ["chain": chain.networkID, "host": "tokens.coingecko.com"])
            }
        }
        // Shared public transport coalesces this directory across chains. Only
        // the requested platform's contracts establish identity, never a ticker;
        // absent decimals continue to come from the chain's own response.
        do {
            let data = try await read(URL(string: "https://api.coingecko.com/api/v3/coins/list?include_platform=true")!, transport: transport)
            return try decodeCoinList(data, chain: chain)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            guard Self.isUnavailable(error) else { throw error }
            if chain == .story {
                // No independent complete Story directory is available. Keep
                // the seven previously verified public contract identities as
                // a cold-start floor while both CoinGecko hosts are unavailable.
                // This contains no prices/precision and grants no new contracts
                // trust. Normal online refresh replaces this finite snapshot.
                OathDiagnostics.record(error, component: "token_catalog", operation: "bundled_directory_fallback",
                    context: ["chain": chain.networkID, "host": "api.coingecko.com"])
                guard let url = Bundle.module.url(forResource: "StoryVerifiedCatalog", withExtension: "json") else { throw AnkrError.invalidResponse }
                let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
                guard value.networkID == chain.networkID, value.decimalsByReference.isEmpty,
                      let references = value.referencesWithoutDecimals, !references.isEmpty,
                      references.allSatisfy(AnkrQuantity.address) else { throw AnkrError.invalidResponse }
                return value
            }
            guard let url = independentLists[chain] else { throw error }
            OathDiagnostics.record(error, component: "token_catalog", operation: "issuer_directory_fallback",
                context: ["chain": chain.networkID, "host": "api.coingecko.com"])
            var value = try decode(await read(url, transport: transport), chain: chain, allowsOtherChains: true)
            value.source = chain == .telos ? "Telos" : "OKX"
            return value
        }
    }

    static func isUnavailable(_ error: Error) -> Bool {
        if error is DiagnosticDeferral { return true }
        switch error as? AnkrError {
        case .transport, .http(403), .http(404), .http(408), .http(429),
             .http(500), .http(502), .http(503), .http(504): return true
        default: return false
        }
    }

    private static func read(_ url: URL, transport: any AnkrTransport) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await transport.send(request)
        try Task.checkCancellation()
        guard status == 200 else { throw AnkrError.http(status) }
        return data
    }
}
