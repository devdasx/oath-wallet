import Foundation

extension AssetPriceClient {
    struct CoinLoreIdentity: Sendable {
        let id: String
        let nameID: String
    }

    static func defiLlamaChainID(
        _ network: WalletBlockchain
    ) -> String? {
        switch network {
        case .aptos: "aptos"
        case .stellar, .xrp: nil
        case .near: "near"
        case .sui: "sui"
        case .ton: "ton"
        case .solana: "solana"
        case .tron: "tron"
        case .bitcoin, .bitcoincash, .litecoin, .dogecoin: nil
        case .ethereum: "ethereum"
        case .smartchain: "bsc"
        case .polygon: "polygon"
        case .arbitrum: "arbitrum"
        case .avalanchec: "avalanche"
        case .optimism: "optimism"
        case .base: "base"
        case .xdai: "gnosis"
        case .scroll: "scroll"
        case .linea: "linea"
        case .taiko: "taiko"
        case .telos: "telos"
        case .xlayer: "xlayer"
        case .arc: nil
        }
    }

    static func geckoTerminalNetworkID(
        _ network: WalletBlockchain
    ) -> String? {
        switch network {
        case .aptos: "aptos"
        case .stellar: "stellar"
        case .xrp: "xrpl"
        case .near: "near"
        case .sui: "sui-network"
        case .ton: "ton"
        case .solana: "solana"
        case .tron: "tron"
        case .bitcoin, .bitcoincash, .litecoin, .dogecoin: nil
        case .ethereum: "eth"
        case .smartchain: "bsc"
        case .polygon: "polygon_pos"
        case .arbitrum: "arbitrum"
        case .avalanchec: "avax"
        case .optimism: "optimism"
        case .base: "base"
        case .xdai: "xdai"
        case .scroll: "scroll"
        case .linea: "linea"
        case .taiko: "taiko"
        case .telos: "tlos"
        case .xlayer: nil
        case .arc: "arc"
        }
    }

    static func dexScreenerNetworkID(
        _ network: WalletBlockchain
    ) -> String? {
        switch network {
        case .aptos: "aptos"
        case .stellar: "stellar"
        case .xrp: "xrpl"
        case .near: "near"
        case .sui: "sui"
        case .ton: "ton"
        case .solana: "solana"
        case .tron: "tron"
        case .bitcoin, .bitcoincash, .litecoin, .dogecoin: nil
        case .ethereum: "ethereum"
        case .smartchain: "bsc"
        case .polygon: "polygon"
        case .arbitrum: "arbitrum"
        case .avalanchec: "avalanche"
        case .optimism: "optimism"
        case .base: "base"
        case .xdai: "gnosis"
        case .scroll: "scroll"
        case .linea: "linea"
        case .taiko: "taiko"
        case .telos: "telos"
        case .xlayer: "xlayer"
        case .arc: "arc"
        }
    }

    static func coinLoreNativeIdentity(
        _ network: WalletBlockchain
    ) -> CoinLoreIdentity? {
        switch network {
        case .aptos: .init(id: "111341", nameID: "aptos")
        case .stellar: .init(id: "89", nameID: "stellar")
        case .xrp: .init(id: "58", nameID: "ripple")
        case .near: .init(id: "48563", nameID: "near-protocol")
        case .sui: .init(id: "93845", nameID: "sui")
        case .ton: .init(id: "54683", nameID: "toncoin")
        case .solana: .init(id: "48543", nameID: "solana")
        case .tron: .init(id: "2713", nameID: "tron")
        case .bitcoin: .init(id: "90", nameID: "bitcoin")
        case .bitcoincash: .init(id: "2321", nameID: "bitcoin-cash")
        case .litecoin: .init(id: "1", nameID: "litecoin")
        case .dogecoin: .init(id: "2", nameID: "dogecoin")
        case .ethereum, .arbitrum, .optimism, .base,
             .scroll, .linea, .taiko:
            .init(id: "80", nameID: "ethereum")
        case .smartchain: .init(id: "2710", nameID: "binance-coin")
        case .polygon: nil
        case .avalanchec: .init(id: "44883", nameID: "avalanche")
        case .xdai: .init(id: "47739", nameID: "xdai")
        case .telos: .init(id: "36667", nameID: "telos")
        case .xlayer: .init(id: "33531", nameID: "okb")
        case .arc: nil
        }
    }

    struct CoinbaseEnvelope: Decodable {
        let data: CoinbaseData
    }

    struct CoinbaseData: Decodable {
        let currency: String
        let rates: [String: String]
    }

    struct CoinGeckoQuote: Decodable {
        let usd: AssetPriceJSONDecimal?
    }

    struct DefiLlamaEnvelope: Decodable {
        let coins: [String: DefiLlamaQuote]
    }

    struct DefiLlamaQuote: Decodable {
        let price: AssetPriceJSONDecimal
        let confidence: AssetPriceJSONDecimal?
        let symbol: String?
    }

    struct GeckoTerminalEnvelope: Decodable {
        let data: GeckoTerminalData
    }

    struct GeckoTerminalData: Decodable {
        let attributes: GeckoTerminalAttributes
    }

    struct GeckoTerminalAttributes: Decodable {
        let tokenPrices: [String: AssetPriceJSONDecimal?]

        private enum CodingKeys: String, CodingKey {
            case tokenPrices = "token_prices"
        }
    }

    struct DexScreenerPair: Decodable {
        let chainID: String
        let baseToken: DexScreenerToken
        let priceUSD: AssetPriceJSONDecimal?
        let liquidity: DexScreenerLiquidity?

        private enum CodingKeys: String, CodingKey {
            case chainID = "chainId"
            case baseToken
            case priceUSD = "priceUsd"
            case liquidity
        }
    }

    struct DexScreenerToken: Decodable {
        let address: String
    }

    struct DexScreenerLiquidity: Decodable {
        let usd: AssetPriceJSONDecimal?
    }

    struct TonAPIRatesEnvelope: Decodable {
        let rates: [String: TonAPIRate]
    }

    struct TonAPIRate: Decodable {
        let prices: [String: AssetPriceJSONDecimal?]
    }

    struct CoinLoreQuote: Decodable {
        let id: String
        let nameID: String
        let priceUSD: AssetPriceJSONDecimal?

        private enum CodingKeys: String, CodingKey {
            case id
            case nameID = "nameid"
            case priceUSD = "price_usd"
        }
    }

    struct KrakenEnvelope: Decodable {
        let error: [String]
        let result: [String: KrakenQuote]
    }

    struct KrakenQuote: Decodable {
        let close: [String]

        private enum CodingKeys: String, CodingKey {
            case close = "c"
        }
    }
}
