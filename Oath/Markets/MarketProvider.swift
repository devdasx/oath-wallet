import Foundation

protocol MarketTransport: Sendable {
    func data(from url: URL) async throws -> Data
}
struct MarketHTTPFailure: Error, Sendable {
    let status: Int
    let retryAfter: TimeInterval
}
struct MarketHTTPTransport: MarketTransport {
    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw MarketHTTPFailure(status: http.statusCode, retryAfter: Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60)
        }
        guard data.count < 12_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}

/// No wallet addresses, balances or private data ever enter these requests.
actor MarketProvider {
    let transport: any MarketTransport
    private var cooldowns: [String: Date] = [:]
    private let ownedPrice: @Sendable (WalletAsset) async throws -> AssetUSDPrice
    init(transport: any MarketTransport = MarketHTTPTransport(),
         ownedPrice: @escaping @Sendable (WalletAsset) async throws -> AssetUSDPrice = { asset in
             // Reuse the exact-identity provider router, but not the wallet's
             // quote database or its asset/balance cache.
             try await AssetPriceClient.fetchPrice(for: asset, session: URLSession.shared)
         }) {
        self.transport = transport
        self.ownedPrice = ownedPrice
    }

    private func json(_ base: String, _ query: [String: String] = [:]) async throws -> Any {
        var components = URLComponents(string: base)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let host = components.host ?? ""
        guard Date() >= (cooldowns[host] ?? .distantPast) else { throw URLError(.resourceUnavailable) }
        do {
            let data = try await transport.data(from: components.url!)
            try Task.checkCancellation()
            return try JSONSerialization.jsonObject(with: data)
        } catch let failure as MarketHTTPFailure {
            if failure.status == 429 {
                cooldowns[host] = Date().addingTimeInterval(min(3600, max(60, failure.retryAfter)))
            }
            throw failure
        }
    }
    private func number(_ value: Any?) -> Double? {
        let result: Double? = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    private func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    func quotes(for coins: [MarketCoin], onUpdate: (@Sendable ([String: MarketQuote]) async -> Void)? = nil) async -> [String: MarketQuote] {
        var output: [String: MarketQuote] = [:]
        // Visible assets go first, including zero balances and unlisted tokens.
        // Bound concurrent provider work regardless of the number enabled.
        let owned = coins.filter { $0.ownedAsset != nil }
        for start in stride(from: 0, to: owned.count, by: 4) {
            guard !Task.isCancelled else { return output }
            let batch = Array(owned[start..<min(start + 4, owned.count)])
            let values = await withTaskGroup(of: (String, MarketQuote?).self) { group in
                for coin in batch { group.addTask { (coin.id, await self.quoteForOwnedAsset(coin)) } }
                var values: [String: MarketQuote] = [:]
                for await (id, quote) in group {
                    if let quote {
                        values[id] = quote
                        await onUpdate?([id: quote])
                    }
                }
                return values
            }
            output.merge(values) { old, new in old.merging(new) }
        }
        let listed = coins.filter { $0.geckoID != nil }
        for start in stride(from: 0, to: listed.count, by: 100) {
            guard !Task.isCancelled else { break }
            let values = await listedQuotes(for: Array(listed[start..<min(start + 100, listed.count)]), onUpdate: onUpdate)
            output.merge(values) { old, new in old.merging(new) }
        }
        return output
    }

    private func quoteForOwnedAsset(_ coin: MarketCoin) async -> MarketQuote? {
        guard let asset = coin.ownedAsset,
              let value = try? await ownedPrice(asset),
              AssetIdentityKey.canonical(value.assetID) == AssetIdentityKey.canonical(asset.id) else { return nil }
        let price = NSDecimalNumber(decimal: value.price).doubleValue
        let quote = MarketQuote(price: price, change24h: nil, marketCap: nil, volume: nil,
            high24h: nil, low24h: nil, supply: nil, rank: nil, image: nil,
            updatedAt: value.observedAt, source: value.provider)
        return quote.isValid ? quote : nil
    }

    private func listedQuotes(for coins: [MarketCoin], onUpdate: (@Sendable ([String: MarketQuote]) async -> Void)? = nil) async -> [String: MarketQuote] {
        var output: [String: MarketQuote] = [:]
        if let rows = try? await json("https://api.coingecko.com/api/v3/coins/markets", ["vs_currency": "usd", "ids": coins.map(\.id).joined(separator: ","), "per_page": "100"]) as? [[String: Any]] {
            for row in rows {
                guard let id = row["id"] as? String, coins.contains(where: { $0.id == id }), let price = number(row["current_price"]), let updated = date(row["last_updated"]) else { continue }
                let quote = MarketQuote(price: price, change24h: number(row["price_change_percentage_24h"]), marketCap: number(row["market_cap"]), volume: number(row["total_volume"]), high24h: number(row["high_24h"]), low24h: number(row["low_24h"]), supply: number(row["circulating_supply"]), rank: row["market_cap_rank"] as? Int, image: row["image"] as? String, updatedAt: updated, source: "CoinGecko")
                if quote.isValid { output[id] = output[id].map { $0.merging(quote) } ?? quote }
            }
        }
        if !output.isEmpty { await onUpdate?(output) }
        guard !Task.isCancelled else { return output }
        let missingIDs = coins.filter { output[$0.id] == nil }.map { "coingecko:" + $0.id }
        if !missingIDs.isEmpty,
           let row = try? await json("https://coins.llama.fi/prices/current/" + missingIDs.joined(separator: ",")) as? [String: Any],
           let prices = row["coins"] as? [String: [String: Any]] {
            for coin in coins where output[coin.id] == nil {
                guard let value = prices["coingecko:" + coin.id], let price = number(value["price"]),
                      let timestamp = number(value["timestamp"]),
                      Date().timeIntervalSince1970 - timestamp < 86_400,
                      (number(value["confidence"]) ?? 1) >= 0.5 else { continue }
                let quote = MarketQuote(price: price, change24h: nil, marketCap: nil, volume: nil,
                    high24h: nil, low24h: nil, supply: nil, rank: nil, image: nil,
                    updatedAt: Date(timeIntervalSince1970: timestamp), source: "DefiLlama")
                if quote.isValid { output[coin.id] = quote }
            }
        }
        if !output.isEmpty { await onUpdate?(output) }
        let missingChanges = coins.filter { output[$0.id] != nil && output[$0.id]?.change24h == nil }
        if !missingChanges.isEmpty,
           let response = try? await json("https://coins.llama.fi/percentage/" + missingChanges.map { "coingecko:" + $0.id }.joined(separator: ","), ["period": "24h", "lookForward": "false"]) as? [String: Any],
           let changes = response["coins"] as? [String: Any] {
            for coin in missingChanges {
                guard let value = number(changes["coingecko:" + coin.id]), let existing = output[coin.id] else { continue }
                let enriched = MarketQuote(price: existing.price, change24h: value,
                    marketCap: existing.marketCap, volume: existing.volume,
                    high24h: existing.high24h, low24h: existing.low24h, supply: existing.supply,
                    rank: existing.rank, image: existing.image, updatedAt: existing.updatedAt, source: existing.source,
                    changeUpdatedAt: Date())
                output[coin.id] = existing.merging(enriched)
            }
            await onUpdate?(output)
        }
        if coins.contains(where: { !$0.paprikaID.isEmpty && output[$0.id]?.change24h == nil }), let rows = try? await json("https://api.coinpaprika.com/v1/tickers") as? [[String: Any]] {
            let ids = Dictionary(coins.filter { !$0.paprikaID.isEmpty }.map { ($0.paprikaID, $0.id) }, uniquingKeysWith: { first, _ in first })
            for row in rows {
                guard let providerID = row["id"] as? String, let id = ids[providerID], output[id]?.change24h == nil,
                      let currencies = row["quotes"] as? [String: Any], let usd = currencies["USD"] as? [String: Any],
                      let price = number(usd["price"]), let updated = date(row["last_updated"]) else { continue }
                let quote = MarketQuote(price: price, change24h: number(usd["percent_change_24h"]), marketCap: number(usd["market_cap"]), volume: number(usd["volume_24h"]), high24h: nil, low24h: nil, supply: number(row["circulating_supply"]), rank: row["rank"] as? Int, image: nil, updatedAt: updated, source: "CoinPaprika")
                if quote.isValid { output[id] = output[id].map { $0.merging(quote) } ?? quote }
            }
        }
        if !output.isEmpty { await onUpdate?(output) }
        // CoinLore has an independent, keyless USD feed. IDs are curated,
        // never inferred from a ticker that another token could impersonate.
        let loreCoins = coins.filter { output[$0.id]?.change24h == nil && Self.coinLoreIDs[$0.id] != nil }
        if !loreCoins.isEmpty,
           let rows = try? await json("https://api.coinlore.net/api/ticker/", ["id": loreCoins.compactMap { Self.coinLoreIDs[$0.id] }.joined(separator: ",")]) as? [[String: Any]] {
            for row in rows {
                guard let providerID = row["id"] as? String,
                      let coin = loreCoins.first(where: { Self.coinLoreIDs[$0.id] == providerID }),
                      let price = number(row["price_usd"]) else { continue }
                let quote = MarketQuote(price: price, change24h: number(row["percent_change_24h"]),
                    marketCap: number(row["market_cap_usd"]), volume: number(row["volume24"]),
                    high24h: nil, low24h: nil, supply: number(row["csupply"]),
                    rank: row["rank"] as? Int, image: nil, updatedAt: Date(), source: "CoinLore")
                if quote.isValid { output[coin.id] = output[coin.id].map { $0.merging(quote) } ?? quote }
            }
            await onUpdate?(output)
        }
        let missing = coins.filter { output[$0.id]?.change24h == nil && $0.exchangeSymbol != nil }
        for start in stride(from: 0, to: missing.count, by: 4) {
            guard !Task.isCancelled else { break }
            let batch = Array(missing[start..<min(start + 4, missing.count)])
            let values = await withTaskGroup(of: (String, MarketQuote?).self) { group in
                for coin in batch { group.addTask { (coin.id, await self.coinbaseQuote(coin)) } }
                var result: [String: MarketQuote] = [:]
                for await (id, quote) in group { if let quote { result[id] = quote } }
                return result
            }
            output.merge(values) { old, new in old.merging(new) }
            if !values.isEmpty { await onUpdate?(values) }
        }
        return output
    }

    private static let coinLoreIDs: [String: String] = [
        "bitcoin": "90", "ethereum": "80", "tether": "518", "binancecoin": "2710",
        "ripple": "58", "usd-coin": "33285", "solana": "48543", "tron": "2713",
        "dogecoin": "2", "chainlink": "2751", "cardano": "257", "stellar": "89",
        "uniswap": "47305", "bitcoin-cash": "2321", "near": "48563", "litecoin": "1",
        "avalanche-2": "44883", "the-open-network": "54683", "sui": "93845",
        "okb": "33531", "polkadot": "45219"
    ]

    private func coinbaseQuote(_ coin: MarketCoin) async -> MarketQuote? {
        guard let symbol = coin.exchangeSymbol,
              let row = try? await json("https://api.exchange.coinbase.com/products/\(symbol)-USD/stats") as? [String: Any], let price = number(row["last"]) else { return nil }
        let opening = number(row["open"])
        let change = opening.flatMap { $0 > 0 ? (price / $0 - 1) * 100 : nil }
        let quote = MarketQuote(price: price, change24h: change, marketCap: nil, volume: nil, high24h: number(row["high"]), low24h: number(row["low"]), supply: nil, rank: nil, image: nil, updatedAt: Date(), source: "Coinbase")
        return quote.isValid ? quote : nil
    }

    func history(for coin: MarketCoin, range: MarketRange, now: Date = Date()) async -> MarketHistory? {
        guard let geckoID = coin.geckoID else { return nil }
        let since = now.addingTimeInterval(-range.seconds)
        if let row = try? await json("https://api.coingecko.com/api/v3/coins/\(geckoID)/market_chart", ["vs_currency": "usd", "days": String(range.days)]) as? [String: Any], let rows = row["prices"] as? [[Double]] {
            let points = MarketPoint.normalized(rows.compactMap { $0.count >= 2 ? MarketPoint(date: Date(timeIntervalSince1970: $0[0] / 1000), price: $0[1]) : nil }, since: since)
            if points.count > 1 { return MarketHistory(points: points, source: "CoinGecko", updatedAt: now) }
        }
        guard !Task.isCancelled else { return nil }
        if !coin.paprikaID.isEmpty, let rows = try? await json("https://api.coinpaprika.com/v1/tickers/\(coin.paprikaID)/historical", ["start": ISO8601DateFormatter().string(from: since), "interval": range == .day ? "1h" : "24h"]) as? [[String: Any]] {
            let values = rows.compactMap { row -> MarketPoint? in
                guard let time = date(row["timestamp"]), let price = number(row["price"]) else { return nil }
                return MarketPoint(date: time, price: price)
            }
            let normalized = MarketPoint.normalized(values, since: since)
            if normalized.count > 1 { return MarketHistory(points: normalized, source: "CoinPaprika", updatedAt: now) }
        }
        guard !Task.isCancelled, let symbol = coin.exchangeSymbol else { return nil }
        // Coinbase limits each response to 300 buckets; a year needs two pages.
        var points: [MarketPoint] = []
        var start = since
        var failed = false
        while start < now && !Task.isCancelled {
            let end = min(now, start.addingTimeInterval(Double(range.granularity * 299)))
            let query = ["granularity": String(range.granularity), "start": ISO8601DateFormatter().string(from: start), "end": ISO8601DateFormatter().string(from: end)]
            guard let rows = try? await json("https://api.exchange.coinbase.com/products/\(symbol)-USD/candles", query) as? [[Double]] else { failed = true; break }
            points += rows.compactMap { $0.count >= 5 ? MarketPoint(date: Date(timeIntervalSince1970: $0[0]), price: $0[4]) : nil }
            start = end
        }
        points = MarketPoint.normalized(points, since: since)
        if !failed && points.count > 1 { return MarketHistory(points: points, source: "Coinbase", updatedAt: now) }
        guard !Task.isCancelled else { return nil }
        // Kraken's 720-bucket limit covers every requested range at these intervals.
        let interval = range == .month ? 60 : range.granularity / 60
        if let response = try? await json("https://api.kraken.com/0/public/OHLC", ["pair": "\(symbol == "BTC" ? "XBT" : symbol)USD", "interval": String(interval), "since": String(Int(since.timeIntervalSince1970))]) as? [String: Any], let result = response["result"] as? [String: Any], let rows = result.first(where: { $0.key != "last" })?.value as? [[Any]] {
            let values = rows.compactMap { row -> MarketPoint? in
                guard row.count >= 5, let stamp = number(row[0]), let price = number(row[4]) else { return nil }
                return MarketPoint(date: Date(timeIntervalSince1970: stamp), price: price)
            }
            let normalized = MarketPoint.normalized(values, since: since)
            if normalized.count > 1 { return MarketHistory(points: normalized, source: "Kraken", updatedAt: now) }
        }
        return nil
    }

    func info(for coin: MarketCoin) async -> MarketInfo? {
        guard let geckoID = coin.geckoID else { return nil }
        if let row = try? await json("https://api.coingecko.com/api/v3/coins/\(geckoID)", ["localization": "false", "tickers": "false", "market_data": "false", "community_data": "false", "developer_data": "false"]) as? [String: Any], let descriptions = row["description"] as? [String: String], let description = descriptions["en"], !description.isEmpty {
            let links = row["links"] as? [String: Any]
            let website = (links?["homepage"] as? [String])?.first
            let plain = description.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&amp;", with: "&")
            return MarketInfo(description: plain, website: website, source: "CoinGecko", updatedAt: Date())
        }
        guard !Task.isCancelled else { return nil }
        if !coin.paprikaID.isEmpty, let row = try? await json("https://api.coinpaprika.com/v1/coins/\(coin.paprikaID)") as? [String: Any], let description = row["description"] as? String, !description.isEmpty {
            let links = row["links"] as? [String: Any]
            return MarketInfo(description: description, website: (links?["website"] as? [String])?.first, source: "CoinPaprika", updatedAt: Date())
        }
        return nil
    }
}
