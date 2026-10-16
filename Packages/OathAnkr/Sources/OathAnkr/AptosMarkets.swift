import OathArtworkSource
import Foundation

public struct AptosCatalog: Codable, Sendable {
    public let tokens:[String:AptosToken]
    public let aliases:[String:String]
    public func canonical(_ reference:String) -> String {aliases[reference] ?? reference}
    public func enrich(_ token:AptosToken) -> AptosToken {
        let ref=canonical(token.reference)
        guard let verified=tokens[ref],verified.decimals==token.decimals else {return .init(reference:ref,name:token.name,symbol:token.symbol,decimals:token.decimals,logo:token.logo,verified:token.reference=="native")}
        return verified
    }
    public static let empty = AptosCatalog(tokens:[:],aliases:[:])
}
public struct AptosMarkets: Sendable {
    private let transport:any AnkrTransport
    public init(transport:any AnkrTransport=AnkrHTTPTransport()) {self.transport=transport}
    private func read(_ url:URL,panora:Bool=false) async throws -> Data {
        var request=URLRequest(url:url);request.timeoutInterval=25;request.setValue("OathWallet/1.0",forHTTPHeaderField:"User-Agent")
        // Public access key published for client applications by Panora at
        // docs.panora.exchange/developer/token-prices. Not a user credential.
        if panora {request.setValue("a4^KV_EaTf4MW#ZdvgGKX#HUD^3IFEAOV_kzpIE^3BQGA8pDnrkT7JcIy#HNlLGi",forHTTPHeaderField:"x-api-key")}
        let (data,status)=try await transport.send(request)
        guard status==200 else {throw AptosError.http(status)};return data
    }
    public func catalog() async throws -> AptosCatalog {
        try Self.decodeCatalog(await read(URL(string:"https://raw.githubusercontent.com/PanoraExchange/Aptos-Tokens/main/token-list.json")!))
    }
    public static func decodeCatalog(_ data:Data) throws -> AptosCatalog {
        guard let rows=try JSONDecoder().decode(AptosJSON.self,from:data).array else {throw AptosError.malformed}
        var tokens:[String:AptosToken]=[:],aliases:[String:String]=[:]
        for row in rows {
            guard row["chainId"].integer==1,row["panoraTags"].array?.contains(.string("Verified"))==true,
                  let decimals=row["decimals"].integer,decimals<=255,
                  let name=row["name"].string,let symbol=row["symbol"].string else {continue}
            let coin=row["tokenAddress"].string.flatMap{try? AptosIdentity.reference($0)}
            let fa=row["faAddress"].string.flatMap{try? AptosIdentity.reference($0)}
            guard let ref=coin ?? fa else {continue}
            if let fa {aliases[fa]=ref};if let coin {aliases[coin]=ref}
            tokens[ref] = .init(reference:ref,name:(try? TronIdentity.clean(name)) ?? "Token",symbol:(try? TronIdentity.clean(symbol,limit:64)) ?? "TOKEN",decimals:Int(decimals),logo:ArtworkSource.normalized(row["logoUrl"].string),verified:true)
        }
        guard tokens["native"]?.decimals==8 else {throw AptosError.malformed}
        tokens["native"] = .native
        return .init(tokens:tokens,aliases:aliases)
    }
    public func nativePrice() async throws -> AptosPrice {
        let data=try await read(URL(string:"https://api.coinbase.com/v2/prices/APT-USD/spot")!)
        let row=try JSONDecoder().decode(AptosJSON.self,from:data)["data"]
        guard row["base"].string=="APT",row["currency"].string=="USD",let usd=TonMarkets.positive(row["amount"]) else {throw AptosError.malformed}
        return .init(reference:"native",usd:usd,source:"Coinbase",fetchedAt:.now)
    }
    public func prices(references:[String]) async throws -> [AptosPrice] {
        guard !references.isEmpty,references.count<=30 else {throw AptosError.malformed}
        let refs=try references.map{try AptosIdentity.reference($0)}
        var url=URLComponents(string:"https://api.panora.exchange/prices")!
        url.queryItems=[.init(name:"chainId",value:"1"),.init(name:"panoraUI",value:"false"),.init(name:"tokenAddress",value:refs.map{$0=="native" ? "0xa":$0}.joined(separator:","))]
        return try Self.decodePrices(await read(url.url!,panora:true),references:Set(refs))
    }
    public func dexPrices(references:[String]) async throws -> [AptosPrice] {
        guard !references.isEmpty,references.count<=30 else {throw AptosError.malformed}
        let refs=try references.map{try AptosIdentity.reference($0)}
        let url=URL(string:"https://api.dexscreener.com/tokens/v1/aptos")!.appendingPathComponent(refs.map{$0=="native" ? "0xa":$0}.joined(separator:","))
        return try Self.decodeDexPrices(await read(url),references:Set(refs))
    }
    public static func decodeDexPrices(_ data:Data,references:Set<String>) throws -> [AptosPrice] {
        guard let rows=try JSONDecoder().decode(AptosJSON.self,from:data).array else {throw AptosError.malformed}
        var best:[String:(Decimal,String)]=[:]
        for row in rows {
            guard row["chainId"].string=="aptos",let raw=row["baseToken"]["address"].string,
                  let ref=try? AptosIdentity.reference(raw),references.contains(ref),
                  let usd=TonMarkets.positive(row["priceUsd"]),let depth=TonMarkets.positive(row["liquidity"]["usd"]),
                  let liquidity=Decimal(string:depth),liquidity>=1000 else {continue}
            if liquidity>(best[ref]?.0 ?? 0) {best[ref]=(liquidity,usd)}
        }
        return best.map{.init(reference:$0.key,usd:$0.value.1,source:"DEX Screener",fetchedAt:.now)}
    }
    public static func decodePrices(_ data:Data,references:Set<String>) throws -> [AptosPrice] {
        guard let rows=try JSONDecoder().decode(AptosJSON.self,from:data).array else {throw AptosError.malformed}
        var prices:[String:AptosPrice]=[:]
        for row in rows {
            guard row["chainId"].integer==1,let usd=TonMarkets.positive(row["usdPrice"]) else {continue}
            for key in ["tokenAddress","faAddress"] {
                guard let ref=row[key].string.flatMap({try? AptosIdentity.reference($0)}),references.contains(ref) else {continue}
                prices[ref] = .init(reference:ref,usd:usd,source:"Powered by Panora",fetchedAt:.now)
            }
        }
        return Array(prices.values)
    }
}
