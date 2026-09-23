import Foundation
import Observation

enum MarketCategory: String, Codable, CaseIterable, Identifiable {
    case trending, gainers, losers, favorites
    var id: Self { self }
    var localizationKey: String { "markets.category." + rawValue }

    func orderedIDs(candidates: [String], changes: [String: Double],
                    trending: [String], favorites: [String]) -> [String] {
        let available = Set(candidates)
        switch self {
        case .trending: return trending.filter { available.contains($0) }
        case .favorites: return favorites.filter { available.contains($0) }
        case .gainers, .losers:
            return candidates.filter {
                guard let change = changes[$0], change.isFinite else { return false }
                return self == .gainers ? change > 0 : change < 0
            }.sorted {
                let lhs = changes[$0]!, rhs = changes[$1]!
                if lhs == rhs { return $0 < $1 }
                return self == .gainers ? lhs > rhs : lhs < rhs
            }
        }
    }
}

/// Public coin identities and preferences, independent of the selected wallet.
struct MarketDiscoveryCoin: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let image: String?
    var price: Double? = nil
    var change24h: Double? = nil
}

struct MarketTrendingSnapshot: Codable, Sendable {
    let coins: [MarketDiscoveryCoin]
    let date: Date

    static func decode(_ data: Data, now: Date) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["coins"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        var seen = Set<String>()
        let ranked: [(Int, MarketDiscoveryCoin)] = rows.compactMap { row in
            guard let item = row["item"] as? [String: Any],
                  let id = item["id"] as? String, !id.isEmpty, id.count <= 200,
                  !id.hasPrefix("asset:"),
                  let name = item["name"] as? String, !name.isEmpty,
                  let symbol = item["symbol"] as? String, !symbol.isEmpty,
                  let score = item["score"] as? Int, score >= 0,
                  seen.insert(id).inserted else { return nil }
            let values = item["data"] as? [String: Any]
            let price = values?["price"] as? Double
            let change = (values?["price_change_percentage_24h"] as? [String: Any])?["usd"] as? Double
            let rawImage = (item["small"] ?? item["thumb"]) as? String
            let image = rawImage.flatMap { URL(string: $0)?.scheme == "https" ? $0 : nil }
            return (score, MarketDiscoveryCoin(id: id, name: name, symbol: symbol.uppercased(),
                image: image, price: price.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                change24h: change.flatMap { $0.isFinite ? $0 : nil }))
        }
        guard rows.isEmpty || !ranked.isEmpty else { throw URLError(.cannotParseResponse) }
        return Self(coins: ranked.sorted { $0.0 == $1.0 ? $0.1.id < $1.1.id : $0.0 < $1.0 }.map(\.1), date: now)
    }
}

@MainActor @Observable
final class MarketDiscoveryStore {
    static let shared = MarketDiscoveryStore()
    var category: MarketCategory {
        didSet { defaults.set(category.rawValue, forKey: "markets.category.v1") }
    }
    private(set) var favorites: [MarketDiscoveryCoin]
    private(set) var trending: MarketTrendingSnapshot?
    private(set) var isLoading = false
    private let defaults: UserDefaults
    private let transport: any MarketTransport
    private var retryAfter = Date.distantPast

    init(defaults: UserDefaults = .standard, transport: any MarketTransport = MarketHTTPTransport()) {
        self.defaults = defaults
        self.transport = transport
        category = defaults.string(forKey: "markets.category.v1").flatMap(MarketCategory.init(rawValue:)) ?? .trending
        favorites = defaults.data(forKey: "markets.favorites.v1")
            .flatMap { try? JSONDecoder().decode([MarketDiscoveryCoin].self, from: $0) } ?? []
        trending = defaults.data(forKey: "markets.trending.v1")
            .flatMap { try? JSONDecoder().decode(MarketTrendingSnapshot.self, from: $0) }
        if let trending, Date().timeIntervalSince(trending.date) > 3600 {
            self.trending = nil
        }
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }

    func toggleFavorite(_ coin: MarketDiscoveryCoin) {
        if isFavorite(coin.id) { favorites.removeAll { $0.id == coin.id } }
        else {
            // Favorite identity persists, never an obsolete price/change.
            favorites.append(MarketDiscoveryCoin(id: coin.id, name: coin.name, symbol: coin.symbol, image: coin.image))
        }
        if let data = try? JSONEncoder().encode(favorites) {
            defaults.set(data, forKey: "markets.favorites.v1")
        }
    }

    func refresh(now: Date = Date()) async {
        if let trending, now.timeIntervalSince(trending.date) > 3600 { self.trending = nil }
        guard !isLoading, now >= retryAfter,
              trending == nil || now.timeIntervalSince(trending!.date) >= 300 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await transport.data(from: URL(string: "https://api.coingecko.com/api/v3/search/trending")!)
            try Task.checkCancellation()
            let result = try MarketTrendingSnapshot.decode(data, now: now)
            trending = result
            defaults.set(try JSONEncoder().encode(result), forKey: "markets.trending.v1")
        } catch {
            retryAfter = now.addingTimeInterval(60)
        }
    }
}
