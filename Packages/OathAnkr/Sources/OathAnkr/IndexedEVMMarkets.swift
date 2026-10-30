import Foundation
import OathDiagnostics

public struct IndexedEVMMarkets: Sendable {
    public let chain: IndexedEVMChain
    private let transport: any AnkrTransport
    public init(chain: IndexedEVMChain, transport: any AnkrTransport = AnkrHTTPTransport()) { self.chain = chain; self.transport = transport }
    private func read(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 25
        if url.host == "dev.iotexscan.io" {
            request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for attempt in 0..<3 {
            do {
                let (data, status) = try await transport.send(request)
                guard status == 200 else { throw AnkrError.http(status) }
                guard data.count <= 32 * 1024 * 1024 else { throw AnkrError.responseTooLarge }
                try Task.checkCancellation(); return data
            } catch {
                OathDiagnostics.record(error, operation: "market_read", context: ["chain": chain.rawValue])
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

    public func catalog() async throws -> IndexedEVMCatalog {
        do { return try Self.decodeCatalog(await read(URL(string: "https://api.coingecko.com/api/v3/coins/list?include_platform=true")!), chain: chain) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            guard [.filecoin, .sei, .zerog, .iotex].contains(chain) else { throw error }
            OathDiagnostics.record(error, component: "prices", operation: "indexed_catalog_fallback", context: ["chain": chain.rawValue, "source": "CoinGecko"])
            struct Seed: Decodable { let entries: [TokenDiscoveryEntry] }
            guard let url = Bundle.module.url(forResource: "TokenDiscoverySeed", withExtension: "json") else { throw error }
            let seed = try JSONDecoder().decode(Seed.self, from: Data(contentsOf: url))
            let entries = try seed.entries.filter { $0.network == chain.rawValue }.map { (try IndexedEVMIdentity.address($0.reference), $0.coinID) }
            guard !entries.isEmpty, Set(entries.map(\.0)).count == entries.count else { throw AnkrError.invalidResponse }
            return .init(chain: chain, ids: Dictionary(uniqueKeysWithValues: entries))
        }
    }
    public static func decodeCatalog(_ data: Data, chain: IndexedEVMChain) throws -> IndexedEVMCatalog {
        guard let rows = try JSONDecoder().decode(SolanaJSON.self, from: data).array else { throw AnkrError.invalidResponse }
        var ids: [String: String] = [:], ambiguous: Set<String> = []
        for row in rows {
            guard let contract = row["platforms"][chain.catalogPlatform].string,
                  let reference = try? (chain == .iotex ? IoTeXIdentity.ethereum(contract) : IndexedEVMIdentity.address(contract)), let id = row["id"].string, !id.isEmpty else { continue }
            if let old = ids[reference], old != id { ambiguous.insert(reference) }
            ids[reference] = id
        }
        for reference in ambiguous { ids[reference] = nil }
        guard !ids.isEmpty else { throw AnkrError.invalidResponse }
        return .init(chain: chain, ids: ids)
    }
    public func nativePrice() async throws -> IndexedEVMPrice {
        do {
            // MON and ETH have direct native quotes. Requiring CoinGecko first
            // spent its shared catalog/chart quota on every refresh and kept
            // generating 429s before reaching an already-working provider.
            // The transport coalesces/caches these exact public quote URLs.
            let quote = try await NativePriceFallback.resolve(chain.symbol, read: read)
            return .init(chain: chain, reference: "native", usd: quote.usd, source: quote.source, fetchedAt: quote.date)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // Reject an unavailable or stale 0G primary quote before trying
            // the independent source. Replacement quotes are validated again.
            OathDiagnostics.record(error, component: "prices", operation: "native_price_fallback", context: ["chain": chain.rawValue, "source": "native_quote"])
            guard VerifiedEVMTokenCatalog.isUnavailable(error) || ([.zerog, .iotex].contains(chain) && error as? AnkrError == .invalidResponse) else { throw error }
            do {
                let data = try await read(URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=" + chain.nativeCoinID + "&vs_currencies=usd&include_last_updated_at=true")!)
                guard let price = try Self.decodePrices(data, references: ["native"], catalog: .init(chain: chain, ids: ["native": chain.nativeCoinID])).first else { throw AnkrError.invalidResponse }
                return price
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                guard chain == .iotex, VerifiedEVMTokenCatalog.isUnavailable(error) || error as? AnkrError == .invalidResponse else { throw error }
                OathDiagnostics.record(error, component: "prices", operation: "iotex_native_price_recovery", context: ["chain": "iotex", "source": "CoinGecko"])
                try await IoTeXIndex.permits.acquire()
                do {
                    try await Task.sleep(for: .milliseconds(1050))
                    let data = try await read(URL(string: "https://dev.iotexscan.io/api?module=stats&action=iotxprice")!)
                    let quote = try Self.decodeIoTeXNativePrice(data)
                    await IoTeXIndex.permits.release(); return quote
                } catch {
                    OathDiagnostics.record(error, component: "prices", operation: "iotex_native_price_validation", context: ["chain": "iotex", "source": "IoTeXScan"])
                    await IoTeXIndex.permits.release(); throw error
                }
            }
        }
    }
    static func decodeIoTeXNativePrice(_ data: Data, now: Date = .now) throws -> IndexedEVMPrice {
        let json = try JSONDecoder().decode(SolanaJSON.self, from: data)
        guard json["status"].text == "1", let price = TonMarkets.positive(json["result"]["ethusd"]),
              let timestamp = json["result"]["ethusd_timestamp"].text.flatMap(Double.init), timestamp.isFinite,
              timestamp > 0, timestamp <= now.timeIntervalSince1970 + 60 else { throw AnkrError.invalidResponse }
        // A valid but expired public quote is unavailable. Keep the same
        // freshness limit and let the caller preserve its cached-price policy.
        guard now.timeIntervalSince1970 - timestamp <= 900 else { throw DiagnosticDeferral.publicMarketQuoteUnavailable }
        return .init(chain: .iotex, reference: "native", usd: price, source: "IoTeXScan", fetchedAt: Date(timeIntervalSince1970: timestamp))
    }
    public func prices(references: [String], catalog: IndexedEVMCatalog) async throws -> [IndexedEVMPrice] {
        guard catalog.chain == chain, references.count <= 30 else { throw AnkrError.invalidResponse }
        let refs = try Set(references.map { try IndexedEVMIdentity.address($0) })
        let ids = Set(refs.compactMap { catalog.ids[$0] })
        guard !ids.isEmpty else { return [] }
        var url = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        url.queryItems = [.init(name: "ids", value: ids.sorted().joined(separator: ",")), .init(name: "vs_currencies", value: "usd"),
                          .init(name: "include_last_updated_at", value: "true")]
        if ![.filecoin, .sei, .zerog, .iotex].contains(chain) { return try Self.decodePrices(await read(url.url!), references: refs, catalog: catalog) }
        var prices: [IndexedEVMPrice] = []
        do { prices = try Self.decodePrices(await read(url.url!), references: refs, catalog: catalog) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error, component: "prices", operation: "indexed_token_price_fallback", context: ["chain": chain.rawValue, "source": "CoinGecko"])
        }
        let missing = refs.filter { ref in !prices.contains { $0.reference == ref } }
        let keys = Set(missing.compactMap { catalog.ids[$0] }.map { "coingecko:" + $0 }).sorted()
        if !keys.isEmpty {
            do {
                let json = try JSONDecoder().decode(SolanaJSON.self, from: await read(URL(string: "https://coins.llama.fi/prices/current/" + keys.joined(separator: ","))!))
                for reference in missing {
                    guard let id = catalog.ids[reference], !json["coins"]["coingecko:" + id].isNull else { continue }
                    do {
                        let quote = try NativePriceFallback.decodeLlama(json, key: "coingecko:" + id)
                        prices.append(.init(chain: chain, reference: reference, usd: quote.usd, source: quote.source, fetchedAt: quote.date))
                    } catch {
                        OathDiagnostics.record(error, component: "prices", operation: "indexed_quote_validation", context: ["chain": chain.rawValue, "source": "DefiLlama"])
                    }
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error, component: "prices", operation: "indexed_token_price_fallback", context: ["chain": chain.rawValue, "source": "DefiLlama"])
            }
        }
        if chain == .iotex, !prices.isEmpty {
            do {
                let url = URL(string: "https://api.geckoterminal.com/api/v2/networks/iotx/tokens/multi/" + prices.map(\.reference).sorted().joined(separator: ","))!
                let data = try await read(url)
                return try Self.corroborateIoTeXPrices(prices, data: data)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error, component: "prices", operation: "iotex_quote_corroboration", context: ["chain": "iotex", "source": "GeckoTerminal"])
                // An unavailable comparison is not evidence of a conflicting price.
            }
        }
        return prices
    }
    static func corroborateIoTeXPrices(_ prices: [IndexedEVMPrice], data: Data) throws -> [IndexedEVMPrice] {
        guard let rows = try JSONDecoder().decode(SolanaJSON.self, from: data)["data"].array, rows.count <= 30 else { throw AnkrError.invalidResponse }
        var compared: [String: Double] = [:]
        let references = Set(prices.map(\.reference))
        for row in rows {
            guard let ref = row["attributes"]["address"].string?.lowercased(), references.contains(ref),
                  row["id"].string == "iotx_" + ref, row["type"].string == "token", compared[ref] == nil else { throw AnkrError.invalidResponse }
            let value = row["attributes"]
            if let price = value["price_usd"].text.flatMap(Double.init), price.isFinite, price > 0,
               let liquidity = value["total_reserve_in_usd"].text.flatMap(Double.init), liquidity.isFinite, liquidity >= 1000 {
                compared[ref] = price
            }
        }
        return prices.filter { quote in
            guard let benchmark = compared[quote.reference], let price = Double(quote.usd) else { return true }
            guard abs(price / benchmark - 1) <= 0.15 else {
                OathDiagnostics.record(AnkrError.invalidResponse, component: "prices", operation: "iotex_quote_conflict", context: ["chain": "iotex", "source": "CoinGecko", "stage": "price_validation"])
                return false
            }
            return true
        }
    }
    public static func decodePrices(_ data: Data, references: Set<String>, catalog: IndexedEVMCatalog,
                                    now: Date = .now) throws -> [IndexedEVMPrice] {
        let json = try JSONDecoder().decode(SolanaJSON.self, from: data)
        return references.compactMap { reference in
            guard let id = catalog.ids[reference], let usd = TonMarkets.positive(json[id]["usd"]),
                  let timestamp = json[id]["last_updated_at"].text.flatMap(Double.init), timestamp.isFinite,
                  timestamp <= now.timeIntervalSince1970 + 60, now.timeIntervalSince1970 - timestamp < 3600 else { return nil }
            return .init(chain: catalog.chain, reference: reference, usd: usd, source: "CoinGecko", fetchedAt: Date(timeIntervalSince1970: timestamp))
        }
    }
    public func dexPrices(references: [String]) async throws -> [IndexedEVMPrice] {
        guard !references.isEmpty, references.count <= 30 else { throw AnkrError.invalidResponse }
        let refs = try Set(references.map { try IndexedEVMIdentity.address($0) })
        if chain == .chiliz || chain == .filecoin || chain == .sei || chain == .zerog || chain == .iotex {
            let network = chain == .iotex ? "iotx" : chain == .zerog ? "0g" : chain == .chiliz ? "chiliz-chain" : chain == .sei ? "sei-evm" : "filecoin"
            let url = URL(string: "https://api.geckoterminal.com/api/v2/networks/"+network+"/tokens/multi/" + refs.sorted().joined(separator: ","))!
            return try Self.decodeTerminalDEX(await read(url), chain: chain,  references: refs)
        }
        let url = URL(string: "https://api.dexscreener.com/tokens/v1/" + chain.dexNetwork + "/" + refs.sorted().joined(separator: ","))!
        return try Self.decodeDEX(await read(url), chain: chain, references: refs)
    }
    public static func decodeChilizDEX(_ data: Data, references: Set<String>, now: Date = .now) throws -> [IndexedEVMPrice] {
        try decodeTerminalDEX(data,chain: .chiliz, references: references, now: now)
    }
    public static func decodeTerminalDEX(_ data: Data, chain: IndexedEVMChain, references: Set<String>, now: Date = .now) throws -> [IndexedEVMPrice] {
        guard chain == .chiliz || chain == .filecoin || chain == .sei || chain == .zerog || chain == .iotex else { throw AnkrError.invalidResponse }
        let network = chain == .iotex ? "iotx" : chain == .zerog ? "0g" : chain == .chiliz ? "chiliz-chain" : chain == .sei ? "sei-evm" : "filecoin"
        guard let rows = try JSONDecoder().decode(SolanaJSON.self, from: data)["data"].array,
              rows.count <= 30 else { throw AnkrError.invalidResponse }
        var seen: Set<String> = []
        return try rows.compactMap { row in
            let value = row["attributes"]
            guard row["type"].string == "token", let address = value["address"].string,
                  let ref = try? IndexedEVMIdentity.address(address), references.contains(ref),
                  row["id"].string == network + "_" + ref,
                  seen.insert(ref).inserted else { throw AnkrError.invalidResponse }
            guard let usd = TonMarkets.positive(value["price_usd"]),
                  let reserve = TonMarkets.positive(value["total_reserve_in_usd"]),
                  let depth = Decimal(string: reserve, locale: Locale(identifier: "en_US_POSIX")), depth >= 10_000 else { return nil }
            if chain == .sei || chain == .zerog || chain == .iotex {
                guard let volume = value["volume_usd"]["h24"].text.flatMap(Double.init), volume.isFinite, volume >= 1_000 else { return nil }
            }
            return .init(chain: chain, reference: ref, usd: usd, source: "GeckoTerminal", fetchedAt: now)
        }
    }
    public static func decodeDEX(_ data: Data, chain: IndexedEVMChain, references: Set<String>, now: Date = .now) throws -> [IndexedEVMPrice] {
        guard let pairs = try JSONDecoder().decode(SolanaJSON.self, from: data).array else { throw AnkrError.invalidResponse }
        var selected: [String: (Decimal, String)] = [:]
        for pair in pairs {
            guard pair["chainId"].string == chain.dexNetwork, let address = pair["baseToken"]["address"].string,
                  let reference = try? IndexedEVMIdentity.address(address), references.contains(reference),
                  let price = TonMarkets.positive(pair["priceUsd"]), let liquidity = TonMarkets.positive(pair["liquidity"]["usd"]),
                  let amount = Decimal(string: liquidity, locale: Locale(identifier: "en_US_POSIX")), amount >= 10_000 else { continue }
            // Inactive Sei pools can retain pre-migration bridged-asset valuations.
            // Require current trading activity as well as reserve depth.
            if chain == .sei || chain == .zerog || chain == .iotex {
                guard let volume = pair["volume"]["h24"].text.flatMap(Double.init), volume.isFinite, volume >= 1_000 else { continue }
            }
            if selected[reference].map({ $0.0 < amount }) ?? true { selected[reference] = (amount, price) }
        }
        return selected.map { .init(chain: chain, reference: $0.key, usd: $0.value.1, source: "DEX Screener", fetchedAt: now) }
    }
}

/// Only explicitly registered native identities use this fallback. Never resolve
/// a user-entered symbol or an arbitrary token contract as a native coin.
enum NativePriceFallback {
    struct Quote: Sendable { let usd: String; let source: String; let date: Date }
    static func resolve(_ code: String, read: (URL) async throws -> Data) async throws -> Quote {
        guard let id = ["ETH": "ethereum", "MON": "monad", "HYPE": "hyperliquid", "CELO": "celo", "CHZ": "chiliz", "FIL": "filecoin", "SEI": "sei-network", "0G": "zero-gravity", "IOTX": "iotex"][code] else { throw AnkrError.invalidResponse }
        if code == "0G" || code == "IOTX" {
            let key = "coingecko:" + id
            let json = try JSONDecoder().decode(SolanaJSON.self, from: await read(URL(string: "https://coins.llama.fi/prices/current/" + key)!))
            return try decodeLlama(json, key: key)
        }
        do { return try await .init(usd: coinbase(code, read: read), source: "Coinbase", date: .now) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            guard VerifiedEVMTokenCatalog.isUnavailable(error) else { throw error }
            OathDiagnostics.record(error, component: "prices", operation: "native_price_fallback", context: ["source": "Coinbase"])
            let key = "coingecko:" + id
            let json = try JSONDecoder().decode(SolanaJSON.self, from: await read(URL(string: "https://coins.llama.fi/prices/current/" + key)!))
            return try decodeLlama(json, key: key)
        }
    }
    static func decodeLlama(_ json: SolanaJSON, key: String, now: Date = .now, maxAge: Double = 900) throws -> Quote {
        let row = json["coins"][key]
        guard let usd = TonMarkets.positive(row["price"]),
              let confidence = row["confidence"].text.flatMap(Double.init), confidence >= 0.9, confidence <= 1,
              let time = row["timestamp"].text.flatMap(Double.init), time.isFinite, time > 0,
              time <= now.timeIntervalSince1970 + 60 else { throw AnkrError.invalidResponse }
        // Expiry is provider availability, not malformed app data. Validate
        // identity, value, confidence and time before taking this exclusion.
        guard now.timeIntervalSince1970 - time <= maxAge else { throw DiagnosticDeferral.publicMarketQuoteUnavailable }
        return .init(usd: usd, source: "DefiLlama", date: Date(timeIntervalSince1970: time))
    }
    static func coinbase(_ code: String, read: (URL) async throws -> Data) async throws -> String {
        guard ["ETH", "MON", "HYPE", "CELO", "CHZ", "FIL", "SEI"].contains(code) else { throw AnkrError.invalidResponse }
        try Task.checkCancellation()
        let data = try await read(URL(string: "https://api.coinbase.com/v2/prices/\(code)-USD/spot")!)
        let quote = try JSONDecoder().decode(SolanaJSON.self, from: data)["data"]
        guard quote["base"].string == code, quote["currency"].string == "USD",
              let usd = TonMarkets.positive(quote["amount"]) else { throw AnkrError.invalidResponse }
        return usd
    }
}
