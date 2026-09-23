import Foundation

struct WalletAsset: Sendable {
    let id: String
    let name: String = "Token"
    let symbol: String = "SAND"
    let network: WalletBlockchain?
}
struct DBAssetPriceRecord { let assetID: String; let provider: String }
struct DBAssetRecord { let id: String; let assetType: String }
enum DatabaseAssetType: String { case native, fungibleToken }
enum AssetIdentityKey {
    static func contractAddress(from id: String) -> String? {
        let value = id.split(separator: ":", maxSplits: 1).last.map(String.init)
        return value == "native" ? nil : value
    }
    static func make(networkID: String, contractAddress: String?) -> String {
        networkID + ":" + (contractAddress ?? "native")
    }
}
enum ReceiveNetworkCatalog {
    struct Network { let id: String }
    static func catalogNetwork(for network: WalletBlockchain) -> Network? {
        let ids: [WalletBlockchain: String] = [
            .ethereum: "eth", .smartchain: "bsc", .avalanchec: "avalanche", .xdai: "gnosis"
        ]
        return Network(id: ids[network] ?? network.rawValue)
    }
}
enum ReceiveAssetCatalog {
    // Even a catalog match must never enable a token market-ID fallback.
    static func marketDataID(for _: String) -> String? { "the-sandbox" }
}
enum TONConstants { static let providerRateSymbol = "gram" }
extension AssetPriceClient {
    // Provider-address conversion is unchanged production code, covered by the
    // app's Stellar/XRP identity tests. This harness exercises EVM and mints.
    static func onChainProviderTokenAddress(for asset: WalletAsset) -> String? {
        priceContractAddress(for: asset)
    }
}

final class PriceFixtureProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case dex, fallback, reject, wrongChain, wrongMint, gecko }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode = .dex
    nonisolated(unsafe) private static var urls: [URL] = []
    static func install(_ value: Mode) {
        lock.lock(); defer { lock.unlock() }
        mode = value; urls = []
    }
    static func requests() -> [URL] {
        lock.lock(); defer { lock.unlock() }; return urls
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.urls.append(url); let mode = Self.mode; Self.lock.unlock()
        let contract = url.lastPathComponent
        var status = 200
        var body = "{}"
        switch url.host! {
        case "api.dexscreener.com":
            if mode == .dex || mode == .wrongChain || mode == .wrongMint {
                let chain = mode == .wrongChain ? "ethereum" : url.pathComponents.dropLast().last!
                let address = mode == .wrongMint ? contract.lowercased() : contract
                body = """
                [{"chainId":"\(chain)","baseToken":{"address":"\(address)"},
                  "priceUsd":"0.000000000003152","liquidity":{"usd":5406}}]
                """
            } else { status = 429 }
        case "api.geckoterminal.com":
            if mode == .gecko {
                body = """
                {"data":{"attributes":{"token_prices":{"\(contract)":"0.00000000000297101821340444"}}}}
                """
            } else { status = 503 }
        case "coins.llama.fi": status = 503
        case "api.coingecko.com":
            if mode == .fallback || mode == .wrongChain {
                let identity = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    .queryItems!.first { $0.name == "contract_addresses" }!.value!
                body = "{\"\(identity)\":{\"usd\":0.025}}"
            } else { status = 503 }
        case "api.coinbase.com": body = #"{"data":{"currency":"SAND","rates":{"USD":"1"}}}"#
        default: status = 503
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
