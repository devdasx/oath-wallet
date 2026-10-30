import Foundation

/// Public DEX fallback for exact EVM token contracts. The provider belongs to
/// CoinGecko, but this public endpoint has a separate host quota. It is not an
/// independent provider against a CoinGecko-wide outage.
/// https://api.geckoterminal.com/docs/index.html
enum TokenPoolChart {
    struct Selection: Sendable {
        let network: String
        let pool: String
        let base: String
        let quote: String
    }

    static func network(for asset: MarketAsset) -> String? {
        guard !asset.isNative, asset.evm, address(asset.reference),
              (0...255).contains(asset.decimals) else { return nil }
        return ContractPriceRequest.terminalNetworks[asset.networkID]
    }
    private static func address(_ text: String) -> Bool {
        text.range(of: "^0x[0-9a-fA-F]{40}$", options: .regularExpression) != nil
    }
    private static func poolReference(_ text: String) -> Bool {
        // The pool list also includes 32-byte pool IDs (for singleton AMMs),
        // while token identities remain strictly 20-byte EVM addresses.
        text.range(of: "^0x(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$", options: .regularExpression) != nil
    }
    private static func matchesID(_ id: String, network: String, address: String) -> Bool {
        id.hasPrefix(network + "_") && id.dropFirst(network.count + 1).lowercased() == address.lowercased()
    }
    static func poolsURL(for asset: MarketAsset) throws -> URL {
        guard let network = network(for: asset) else { throw MarketDataError.notListed }
        return URL(string: "https://api.geckoterminal.com/api/v2/networks/\(network)/tokens/\(asset.reference)/pools?include=base_token,quote_token&page=1")!
    }
    static func candlesURL(for asset: MarketAsset, selection: Selection, at date: Date) throws -> URL {
        guard network(for: asset) == selection.network, poolReference(selection.pool),
              asset.matches(selection.base) || asset.matches(selection.quote),
              date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 > 0,
              date.timeIntervalSince1970 < Double(Int64.max) else { throw MarketDataError.invalidResponse }
        var url = URLComponents(string: "https://api.geckoterminal.com/api/v2/networks/\(selection.network)/pools/\(selection.pool)/ohlcv/hour")!
        url.queryItems = [.init(name: "aggregate", value: "1"), .init(name: "limit", value: "25"),
            .init(name: "before_timestamp", value: String(Int64(floor(date.timeIntervalSince1970 / 3600) * 3600))),
            .init(name: "currency", value: "usd"), .init(name: "token", value: asset.reference)]
        return url.url!
    }

    private struct Pools: Decodable {
        let data: [Pool]
        let included: [Token]?
    }
    private struct Pool: Decodable {
        let id: String
        let type: String
        let attributes: Attributes
        let relationships: Relationships
        struct Attributes: Decodable { let address: String; let reserve_in_usd: String? }
        struct Relationships: Decodable {
            let base_token: Relationship
            let quote_token: Relationship
            struct Relationship: Decodable {
                let data: Identity
                struct Identity: Decodable { let id: String; let type: String }
            }
        }
    }
    private struct Token: Decodable {
        let id: String
        let type: String
        let attributes: Attributes
        struct Attributes: Decodable { let address: String; let decimals: Int? }
    }
    static func select(_ data: Data, for asset: MarketAsset) throws -> Selection {
        guard data.count <= 2_000_000, let network = network(for: asset) else { throw MarketDataError.invalidResponse }
        let response = try JSONDecoder().decode(Pools.self, from: data)
        guard response.data.count <= 100, (response.included?.count ?? 0) <= 200 else { throw MarketDataError.invalidResponse }
        guard !response.data.isEmpty else { throw MarketDataError.notListed }
        let tokens = (response.included ?? []).filter { asset.matches($0.attributes.address) }
        guard tokens.count == 1, let token = tokens.first, token.type == "token",
              matchesID(token.id, network: network, address: token.attributes.address),
              token.attributes.decimals == asset.decimals else { throw MarketDataError.invalidResponse }
        var best: (depth: Decimal, selection: Selection)?
        var seen = Set<String>()
        for pool in response.data {
            guard pool.type == "pool", poolReference(pool.attributes.address),
                  matchesID(pool.id, network: network, address: pool.attributes.address),
                  seen.insert(pool.attributes.address.lowercased()).inserted else { throw MarketDataError.invalidResponse }
            let base = pool.relationships.base_token.data, quote = pool.relationships.quote_token.data
            guard base.type == "token", quote.type == "token", base.id.hasPrefix(network + "_"), quote.id.hasPrefix(network + "_") else {
                throw MarketDataError.invalidResponse
            }
            let baseAddress = String(base.id.dropFirst(network.count + 1)), quoteAddress = String(quote.id.dropFirst(network.count + 1))
            guard address(baseAddress), address(quoteAddress), baseAddress.lowercased() != quoteAddress.lowercased(),
                  asset.matches(baseAddress) || asset.matches(quoteAddress) else { throw MarketDataError.invalidResponse }
            // Avoid dust-pool charts and request only one bounded candidate.
            guard let depth = ContractPriceDecoding.positive(pool.attributes.reserve_in_usd), depth >= 10_000 else { continue }
            let selection = Selection(network: network, pool: pool.attributes.address, base: baseAddress, quote: quoteAddress)
            if best == nil || depth > best!.depth { best = (depth, selection) }
        }
        guard let best else { throw MarketDataError.notListed }
        return best.selection
    }

    private struct Candles: Decodable {
        let data: Body
        let meta: Metadata
        struct Body: Decodable {
            let type: String
            let attributes: Attributes
            struct Attributes: Decodable { let ohlcv_list: [[Double]] }
        }
        struct Metadata: Decodable {
            let base: TokenAddress
            let quote: TokenAddress
            struct TokenAddress: Decodable { let address: String }
        }
    }
    static func decode(_ data: Data, for asset: MarketAsset, selection: Selection, at now: Date) throws -> MarketChart {
        guard data.count <= 200_000, network(for: asset) == selection.network,
              asset.matches(selection.base) || asset.matches(selection.quote) else { throw MarketDataError.invalidResponse }
        let response = try JSONDecoder().decode(Candles.self, from: data)
        // With token=<address>, OHLCV metadata orients `base` to the requested
        // token even when it was the pool's quote side. Verify the actual chart
        // identity and its counter-asset rather than reusing pool orientation.
        let counterAsset = asset.matches(selection.base) ? selection.quote : selection.base
        guard response.data.type == "ohlcv_request_response",
              asset.matches(response.meta.base.address),
              response.meta.quote.address.lowercased() == counterAsset.lowercased() else { throw MarketDataError.invalidResponse }
        let rows = response.data.attributes.ohlcv_list
        guard rows.count <= 25 else { throw MarketDataError.invalidResponse }
        let end = floor(now.timeIntervalSince1970 / 3600) * 3600
        guard end.isFinite, end > 0 else { throw MarketDataError.invalidResponse }
        var previous = Double.infinity
        for row in rows {
            guard row.count == 6, row.allSatisfy(\.isFinite), row[0] > 0,
                  row[0].truncatingRemainder(dividingBy: 3600) == 0, row[0] <= end, row[0] < previous,
                  row[1...4].allSatisfy({ $0 > 0 }), row[5] >= 0,
                  row[2] >= max(row[1], row[4]), row[3] <= min(row[1], row[4]), row[2] >= row[3] else {
                throw MarketDataError.invalidResponse
            }
            previous = row[0]
        }
        // An in-progress hour is not a completed observation. Do not fill
        // missing trading intervals, or present stale prices as a fresh chart.
        let closed = rows.reversed().filter { $0[0] >= end - 86_400 && $0[0] < end }
        guard closed.count >= 2, let first = closed.first, let last = closed.last, last[0] + 3600 == end else {
            throw MarketDataError.notListed
        }
        let change = (last[4] / first[1] - 1) * 100
        guard change.isFinite else { throw MarketDataError.invalidResponse }
        return .init(points: closed.map { .init(time: $0[0] + 3600, close: $0[4]) },
                     changePercent: closed.count == 24 ? change : nil)
    }
}
