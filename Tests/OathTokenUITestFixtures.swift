import Foundation

struct OathTokenUIFixture {
    let chain: String
    let address: String
    let name: String
    let symbol: String
    let decimals: Int
    static let all: [Self] = [
        .init(chain: "ethereum", address: "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", name: "USD Coin", symbol: "USDC", decimals: 6),
        .init(chain: "arbitrum", address: "0xaf88d065e77c8cc2239327c5edb3a432268e5831", name: "USD Coin", symbol: "USDC", decimals: 6),
        .init(chain: "arc", address: "0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1", name: "EURC", symbol: "EURC", decimals: 6),
        .init(chain: "avalanche", address: "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e", name: "USD Coin", symbol: "USDC", decimals: 6),
        .init(chain: "base", address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", name: "USD Coin", symbol: "USDC", decimals: 6),
        .init(chain: "bnb", address: "0x55d398326f99059fF775485246999027B3197955", name: "Tether USD", symbol: "USDT", decimals: 18),
        .init(chain: "gnosis", address: "0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d", name: "Wrapped XDAI", symbol: "WXDAI", decimals: 18),
        .init(chain: "linea", address: "0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f", name: "Wrapped Ether", symbol: "WETH", decimals: 18),
        .init(chain: "optimism", address: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", name: "USD Coin", symbol: "USDC", decimals: 6),
        .init(chain: "polygon", address: "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359", name: "USD Coin", symbol: "USDC", decimals: 6),
        .init(chain: "scroll", address: "0x5300000000000000000000000000000000000004", name: "Wrapped Ether", symbol: "WETH", decimals: 18),
        .init(chain: "taiko", address: "0xA51894664A773981C6C112C43ce576f315d5b1b6", name: "Wrapped Ether", symbol: "WETH", decimals: 18),
        .init(chain: "telos", address: "0xd102ce6a4db07d247fcc28f366a623df0938ca9e", name: "Wrapped TLOS", symbol: "WTLOS", decimals: 18),
        .init(chain: "xlayer", address: "0xe538905cf8410324e03a5a23c1c177a474d59b2b", name: "Wrapped OKB", symbol: "WOKB", decimals: 18),
        .init(chain: "tron", address: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", name: "Tether USD", symbol: "USDT", decimals: 6),
        .init(chain: "solana", address: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", name: "USD Coin", symbol: "USDC", decimals: 6),
    ]
}
