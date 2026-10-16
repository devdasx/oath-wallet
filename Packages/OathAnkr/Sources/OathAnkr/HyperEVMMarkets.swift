import Foundation
import OathDiagnostics

public struct HyperEVMMarkets: Sendable {
    private let transport: any AnkrTransport
    public init(transport: any AnkrTransport = AnkrHTTPTransport()) { self.transport = transport }
    private func read(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 25
        for attempt in 0..<3 {
            do {
                let (data, status) = try await transport.send(request)
                guard status == 200 else { throw AnkrError.http(status) }
                guard data.count <= 32 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                try Task.checkCancellation(); return data
            } catch {
                OathDiagnostics.record(error, operation: "market_read", context: ["chain": "hyperevm"])
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let transient: Bool
                switch error {
                case AnkrError.http(let code): transient = (500...599).contains(code)
                case AnkrError.transport: transient = true
                default: transient = false
                }
                guard transient && attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw AnkrError.transport
    }

    public func catalog() async throws -> HyperEVMCatalog {
        try Self.decodeCatalog(await read(URL(string: "https://api.coingecko.com/api/v3/coins/list?include_platform=true")!))
    }
    public static func decodeCatalog(_ data: Data) throws -> HyperEVMCatalog {
        guard let rows = try JSONDecoder().decode(SolanaJSON.self, from: data).array else { throw AnkrError.invalidResponse }
        var ids: [String: String] = [:], ambiguous: Set<String> = []
        for row in rows {
            guard let contract = row["platforms"]["hyperevm"].string,
                  let reference = try? HyperEVMIdentity.address(contract), let id = row["id"].string, !id.isEmpty else { continue }
            if let old = ids[reference], old != id { ambiguous.insert(reference) }
            ids[reference] = id
        }
        for reference in ambiguous { ids[reference] = nil }
        guard !ids.isEmpty else { throw AnkrError.invalidResponse }
        return .init(ids: ids)
    }
    public func nativePrice() async throws -> HyperEVMPrice {
        do {
            let data = try await read(URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=hyperliquid&vs_currencies=usd&include_last_updated_at=true")!)
            guard let price = try Self.decodePrices(data, references: ["native"], catalog: .init(ids: ["native": "hyperliquid"])).first else { throw AnkrError.invalidResponse }
            return price
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error,component:"prices",operation:"native_price_fallback",context:["chain":"hyperevm","source":"CoinGecko"])
            let usd = try await NativePriceFallback.coinbase("HYPE",read:read)
            return .init(reference:"native",usd:usd,source:"Coinbase",fetchedAt:.now)
        }
    }
    public func prices(references: [String], catalog: HyperEVMCatalog) async throws -> [HyperEVMPrice] {
        guard references.count <= 30 else { throw AnkrError.invalidResponse }
        let refs = try Set(references.map { try HyperEVMIdentity.address($0) })
        let ids = Set(refs.compactMap { catalog.ids[$0] })
        guard !ids.isEmpty else { return [] }
        var url = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        url.queryItems = [.init(name: "ids", value: ids.sorted().joined(separator: ",")), .init(name: "vs_currencies", value: "usd"),
                          .init(name: "include_last_updated_at", value: "true")]
        return try Self.decodePrices(await read(url.url!), references: refs, catalog: catalog)
    }
    public static func decodePrices(_ data: Data, references: Set<String>, catalog: HyperEVMCatalog,
                                    now: Date = .now) throws -> [HyperEVMPrice] {
        let json = try JSONDecoder().decode(SolanaJSON.self, from: data)
        return references.compactMap { reference in
            guard let id = catalog.ids[reference], let usd = TonMarkets.positive(json[id]["usd"]),
                  let timestamp = json[id]["last_updated_at"].text.flatMap(Double.init), timestamp.isFinite,
                  timestamp <= now.timeIntervalSince1970 + 60, now.timeIntervalSince1970 - timestamp < 3600 else { return nil }
            return .init(reference: reference, usd: usd, source: "CoinGecko", fetchedAt: Date(timeIntervalSince1970: timestamp))
        }
    }
    public func dexPrices(references: [String]) async throws -> [HyperEVMPrice] {
        guard !references.isEmpty, references.count <= 30 else { throw AnkrError.invalidResponse }
        let refs = try Set(references.map { try HyperEVMIdentity.address($0) })
        let url = URL(string: "https://api.dexscreener.com/tokens/v1/hyperevm/" + refs.sorted().joined(separator: ","))!
        return try Self.decodeDEX(await read(url), references: refs)
    }
    public static func decodeDEX(_ data: Data, references: Set<String>, now: Date = .now) throws -> [HyperEVMPrice] {
        guard let pairs = try JSONDecoder().decode(SolanaJSON.self, from: data).array else { throw AnkrError.invalidResponse }
        var selected: [String: (Decimal, String)] = [:]
        for pair in pairs {
            guard pair["chainId"].string == "hyperevm", let address = pair["baseToken"]["address"].string,
                  let reference = try? HyperEVMIdentity.address(address), references.contains(reference),
                  let price = TonMarkets.positive(pair["priceUsd"]), let liquidity = TonMarkets.positive(pair["liquidity"]["usd"]),
                  let amount = Decimal(string: liquidity, locale: Locale(identifier: "en_US_POSIX")), amount >= 10_000 else { continue }
            if selected[reference].map({ $0.0 < amount }) ?? true { selected[reference] = (amount, price) }
        }
        return selected.map { .init(reference: $0.key, usd: $0.value.1, source: "DEX Screener", fetchedAt: now) }
    }
}
