import Foundation
import OathDiagnostics

public struct TonMarkets: Sendable {
    private let transport: any AnkrTransport
    public init(transport: any AnkrTransport = AnkrHTTPTransport()) { self.transport = transport }
    static func positive(_ value: TonJSON) -> String? {
        guard let text = value.text, text.count <= 128, text.range(of:"^(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$",options:.regularExpression) != nil,
              let n = Decimal(string:text,locale:Locale(identifier:"en_US_POSIX")), !n.isNaN, n > 0 else { return nil }
        return NSDecimalNumber(decimal:n).stringValue
    }
    public func nativePrice() async throws -> TonPrice {
        try await OathDiagnostics.withChain("ton") {
            do {
                // Coinbase retains the historical TON product code. This route
                // refers to native Gram, never to a similarly named Jetton.
                let data = try await readNativeQuote(URL(string:"https://api.coinbase.com/v2/prices/TON-USD/spot")!)
                let value = try JSONDecoder().decode(TonJSON.self,from:data)["data"]
                guard ["TON","GRAM"].contains(value["base"].string ?? ""), value["currency"].string == "USD",
                      let price = Self.positive(value["amount"]) else { throw TonError.malformed }
                return .init(reference:"native",usd:price,source:"Coinbase",fetchedAt:.now)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                // Fail over only for availability. Never hide authorization,
                // malformed data, cancellation or a wrong native identity.
                switch error {
                case AnkrError.transport, TonError.transport, is DiagnosticDeferral: break
                case TonError.http(let status) where status == 408 || status == 429 || (500...599).contains(status): break
                case AnkrError.http(let status) where status == 408 || status == 429 || (500...599).contains(status): break
                default: throw error
                }
                OathDiagnostics.record(error, component:"prices", operation:"ton_native_fallback", context:["stage":"quote"])
                // The stable native-coin ID survives the TON/Gram rename.
                // Preserve the provider timestamp and require a fresh,
                // high-confidence quote through the existing shared decoder.
                let key = "coingecko:the-open-network"
                let data = try await readNativeQuote(URL(string:"https://coins.llama.fi/prices/current/"+key)!)
                let json = try JSONDecoder().decode(TonJSON.self,from:data)
                guard ["TON","GRAM"].contains(json["coins"][key]["symbol"].string ?? "") else { throw AnkrError.invalidResponse }
                let quote = try NativePriceFallback.decodeLlama(json,key:key)
                return .init(reference:"native",usd:quote.usd,source:quote.source,fetchedAt:quote.date)
            }
        }
    }
    private func readNativeQuote(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url:url)
        request.timeoutInterval = 20
        request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
        let (data,status) = try await transport.send(request)
        try Task.checkCancellation()
        guard status == 200 else { throw TonError.http(status) }
        return data
    }
    /// Keyless DEX fallback, exact mainnet master identity and most-liquid pool.
    public func prices(references: [String]) async throws -> [TonPrice] {
        guard !references.isEmpty, references.count <= 30 else { throw TonError.malformed }
        let refs = try references.map { try TonIdentity.raw($0) }
        let addresses = try refs.map { try TonIdentity.friendly($0) }.joined(separator:",")
        var request = URLRequest(url:URL(string:"https://api.dexscreener.com/tokens/v1/ton/"+addresses)!)
        request.timeoutInterval = 20; request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
        let (data,status) = try await transport.send(request)
        guard status == 200 else { throw TonError.http(status) }
        return try Self.decodePrices(data,references:Set(refs))
    }
    public static func decodePrices(_ data: Data, references: Set<String>) throws -> [TonPrice] {
        guard let pairs = try JSONDecoder().decode(TonJSON.self,from:data).array else { throw TonError.malformed }
        var best: [String:(Decimal,String)] = [:]
        for pair in pairs {
            guard pair["chainId"].string == "ton", let text = pair["baseToken"]["address"].string,
                  let ref = try? TonIdentity.raw(text), references.contains(ref),
                  let price = positive(pair["priceUsd"]), let depth = positive(pair["liquidity"]["usd"]),
                  let liquidity = Decimal(string:depth), liquidity >= 1000 else { continue }
            if liquidity > (best[ref]?.0 ?? 0) { best[ref] = (liquidity,price) }
        }
        return best.map { .init(reference:$0.key,usd:$0.value.1,source:"DEX Screener",fetchedAt:.now) }
    }

}
