import Foundation

/// Provider IDs are curated identities, never resolved by ambiguous ticker symbols.
struct MarketCoin: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let paprikaID: String
    let exchangeSymbol: String?
    let networks: [WalletBlockchain]
    var ownedAsset: WalletAsset? = nil
    var discoveryImage: String? = nil

    var geckoID: String? { id.hasPrefix("asset:") ? nil : id }

    /// Opens the same market from an asset detail row or the market catalog.
    /// Unlisted tokens keep their exact chain/contract identity for price lookup.
    static func forAsset(_ asset: WalletAsset) -> Self {
        let known = all.first { $0.asset(in: [asset]) != nil }
        let id = known?.id ?? AssetPriceClient.coinGeckoMarketID(for: asset)
            ?? "asset:" + AssetIdentityKey.canonical(asset.id)
        var coin = known ?? all.first { $0.id == id }
            ?? Self(id: id, name: asset.name, symbol: asset.symbol,
                    paprikaID: "", exchangeSymbol: nil, networks: [])
        coin.ownedAsset = asset
        return coin
    }

    /// Visibility, not balance, defines ownership here. Provider identities are
    /// resolved from the exact catalog asset/contract, never its display symbol.
    static func catalog(for assets: [WalletAsset]) -> [Self] {
        var result = all
        var positions = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
        for asset in assets {
            let coin = forAsset(asset)
            if let index = positions[coin.id] {
                if result[index].ownedAsset == nil { result[index].ownedAsset = asset }
            } else {
                positions[coin.id] = result.count
                result.append(coin)
            }
        }
        // Put the user's visible assets ahead of the broader discovery catalog.
        return result.filter { $0.ownedAsset != nil } + result.filter { $0.ownedAsset == nil }
    }

    var ethereumContract: String? {
        switch id {
        case "usd-coin": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
        case "tether": "0xdac17f958d2ee523a2206206994597c13d831ec7"
        case "chainlink": "0x514910771af9ca656af840dff83e8264ecf986ca"
        case "uniswap": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
        default: nil
        }
    }

    func asset(in assets: [WalletAsset]) -> WalletAsset? {
        if let ownedAsset {
            return assets.first { AssetIdentityKey.canonical($0.id) == AssetIdentityKey.canonical(ownedAsset.id) }
        }
        if let contract = ethereumContract, let token = assets.first(where: {
            $0.network == .ethereum && $0.logoSource.checksummedContractAddress?.lowercased() == contract
        }) { return token }
        for network in networks {
            if let asset = assets.first(where: {
                guard $0.network == network, AssetPriceClient.priceContractAddress(for: $0) == nil else { return false }
                if case .nativeCoin = $0.logoSource { return true }
                return false
            }) { return asset }
        }
        return nil
    }

    private static let core: [Self] = [
        .init(id: "bitcoin", name: "Bitcoin", symbol: "BTC", paprikaID: "btc-bitcoin", exchangeSymbol: "BTC", networks: [.bitcoin]),
        .init(id: "ethereum", name: "Ethereum", symbol: "ETH", paprikaID: "eth-ethereum", exchangeSymbol: "ETH", networks: [.ethereum, .base, .arbitrum, .optimism, .scroll, .linea, .taiko]),
        .init(id: "solana", name: "Solana", symbol: "SOL", paprikaID: "sol-solana", exchangeSymbol: "SOL", networks: [.solana]),
        .init(id: "binancecoin", name: "BNB", symbol: "BNB", paprikaID: "bnb-binance-coin", exchangeSymbol: nil, networks: [.smartchain]),
        .init(id: "ripple", name: "XRP", symbol: "XRP", paprikaID: "xrp-xrp", exchangeSymbol: "XRP", networks: [.xrp]),
        .init(id: "tron", name: "TRON", symbol: "TRX", paprikaID: "trx-tron", exchangeSymbol: "TRX", networks: [.tron]),
        .init(id: "the-open-network", name: "Toncoin", symbol: "TON", paprikaID: "ton-toncoin", exchangeSymbol: "TON", networks: [.ton]),
        .init(id: "polygon-ecosystem-token", name: "Polygon", symbol: "POL", paprikaID: "pol-polygon-ecosystem-token", exchangeSymbol: "POL", networks: [.polygon]),
        .init(id: "avalanche-2", name: "Avalanche", symbol: "AVAX", paprikaID: "avax-avalanche", exchangeSymbol: "AVAX", networks: [.avalanchec]),
        .init(id: "dogecoin", name: "Dogecoin", symbol: "DOGE", paprikaID: "doge-dogecoin", exchangeSymbol: "DOGE", networks: [.dogecoin]),
        .init(id: "bitcoin-cash", name: "Bitcoin Cash", symbol: "BCH", paprikaID: "bch-bitcoin-cash", exchangeSymbol: "BCH", networks: [.bitcoincash]),
        .init(id: "litecoin", name: "Litecoin", symbol: "LTC", paprikaID: "ltc-litecoin", exchangeSymbol: "LTC", networks: [.litecoin]),
        .init(id: "sui", name: "Sui", symbol: "SUI", paprikaID: "sui-sui", exchangeSymbol: "SUI", networks: [.sui]),
        .init(id: "near", name: "NEAR", symbol: "NEAR", paprikaID: "near-near-protocol", exchangeSymbol: "NEAR", networks: [.near]),
        .init(id: "aptos", name: "Aptos", symbol: "APT", paprikaID: "apt-aptos", exchangeSymbol: "APT", networks: [.aptos]),
        .init(id: "stellar", name: "Stellar", symbol: "XLM", paprikaID: "xlm-stellar", exchangeSymbol: "XLM", networks: [.stellar]),
        .init(id: "xdai", name: "xDAI", symbol: "XDAI", paprikaID: "xdai-xdai", exchangeSymbol: nil, networks: [.xdai]),
        .init(id: "telos", name: "Telos", symbol: "TLOS", paprikaID: "tlos-telos", exchangeSymbol: nil, networks: [.telos]),
        .init(id: "okb", name: "OKB", symbol: "OKB", paprikaID: "okb-okb", exchangeSymbol: nil, networks: [.xlayer]),
        .init(id: "usd-coin", name: "USDC", symbol: "USDC", paprikaID: "usdc-usd-coin", exchangeSymbol: "USDC", networks: [.arc]),
        .init(id: "tether", name: "Tether", symbol: "USDT", paprikaID: "usdt-tether", exchangeSymbol: "USDT", networks: []),
        .init(id: "cardano", name: "Cardano", symbol: "ADA", paprikaID: "ada-cardano", exchangeSymbol: "ADA", networks: []),
        .init(id: "chainlink", name: "Chainlink", symbol: "LINK", paprikaID: "link-chainlink", exchangeSymbol: "LINK", networks: []),
        .init(id: "polkadot", name: "Polkadot", symbol: "DOT", paprikaID: "dot-polkadot", exchangeSymbol: "DOT", networks: []),
        .init(id: "uniswap", name: "Uniswap", symbol: "UNI", paprikaID: "uni-uniswap", exchangeSymbol: "UNI", networks: [])
    ]
    // CoinGecko market identities verified against the public top-250 response
    // on 2026-09-19. Core entries retain curated exchange/network mappings.
    static let all: [Self] = core + expanded.filter { candidate in
        !core.contains { $0.id == candidate.id }
    }
    private static let expanded: [Self] = [
        .init(id: "bitcoin", name: "Bitcoin", symbol: "BTC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ethereum", name: "Ethereum", symbol: "ETH", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "tether", name: "Tether", symbol: "USDT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "binancecoin", name: "BNB", symbol: "BNB", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ripple", name: "XRP", symbol: "XRP", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "usd-coin", name: "USDC", symbol: "USDC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "solana", name: "Solana", symbol: "SOL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "tron", name: "TRON", symbol: "TRX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "zcash", name: "Zcash", symbol: "ZEC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "figure-heloc", name: "Figure Heloc", symbol: "FIGR_HELOC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "hyperliquid", name: "Hyperliquid", symbol: "HYPE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "dogecoin", name: "Dogecoin", symbol: "DOGE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "monero", name: "Monero", symbol: "XMR", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "rain", name: "Rain", symbol: "RAIN", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "whitebit", name: "WhiteBIT Coin", symbol: "WBT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "usds", name: "USDS", symbol: "USDS", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "chainlink", name: "Chainlink", symbol: "LINK", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "cardano", name: "Cardano", symbol: "ADA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "leo-token", name: "LEO Token", symbol: "LEO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "stellar", name: "Stellar", symbol: "XLM", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "uniswap", name: "Uniswap", symbol: "UNI", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "bitcoin-cash", name: "Bitcoin Cash", symbol: "BCH", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ethena-usde", name: "Ethena USDe", symbol: "USDE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "near", name: "NEAR Protocol", symbol: "NEAR", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "dai", name: "Dai", symbol: "DAI", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "litecoin", name: "Litecoin", symbol: "LTC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "canton-network", name: "Canton", symbol: "CC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "usd1-wlfi", name: "USD1", symbol: "USD1", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "avalanche-2", name: "Avalanche", symbol: "AVAX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "the-open-network", name: "Gram (prev. Toncoin)", symbol: "GRAM", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "hedera-hashgraph", name: "Hedera", symbol: "HBAR", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "sui", name: "Sui", symbol: "SUI", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "global-dollar", name: "Global Dollar", symbol: "USDG", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "shiba-inu", name: "Shiba Inu", symbol: "SHIB", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "bittensor", name: "Bittensor", symbol: "TAO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "crypto-com-chain", name: "Cronos", symbol: "CRO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "memecore", name: "MemeCore", symbol: "M", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "paypal-usd", name: "PayPal USD", symbol: "PYUSD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "tether-gold", name: "Tether Gold", symbol: "XAUT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "okb", name: "OKB", symbol: "OKB", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "hashnote-usyc", name: "Circle USYC", symbol: "USYC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ripple-usd", name: "Ripple USD", symbol: "RLUSD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "blackrock-usd-institutional-digital-liquidity-fund", name: "BlackRock USD Institutional Digital Liquidity Fund", symbol: "BUIDL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ondo-us-dollar-yield", name: "Ondo US Dollar Yield", symbol: "USDY", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "aave", name: "Aave", symbol: "AAVE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "aster-2", name: "Aster", symbol: "ASTER", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "mantle", name: "Mantle", symbol: "MNT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ondo-finance", name: "Ondo", symbol: "ONDO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ethena", name: "Ethena", symbol: "ENA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "pump-fun", name: "Pump.fun", symbol: "PUMP", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "polkadot", name: "Polkadot", symbol: "DOT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "pax-gold", name: "PAX Gold", symbol: "PAXG", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "morpho", name: "Morpho", symbol: "MORPHO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "world-liberty-financial", name: "World Liberty Financial", symbol: "WLFI", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "sky", name: "Sky", symbol: "SKY", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "internet-computer", name: "Internet Computer", symbol: "ICP", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "pepe", name: "Pepe", symbol: "PEPE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "bitway", name: "Bitway", symbol: "BTW", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "worldcoin-wld", name: "Worldcoin", symbol: "WLD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "htx-dao", name: "HTX DAO", symbol: "HTX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "usdd", name: "USDD", symbol: "USDD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "arbitrum", name: "Arbitrum", symbol: "ARB", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "bitget-token", name: "Bitget Token", symbol: "BGB", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "akedo", name: "Akedo", symbol: "AKE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "spiko-amundi-overnight-swap-fund-eur", name: "Spiko Amundi Overnight Swap Fund (EUR)", symbol: "EURSAFO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "united-stables", name: "United Stables", symbol: "U", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "usdgo", name: "USDGO", symbol: "USDGO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "falcon-finance", name: "Falcon USD", symbol: "USDF", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ethereum-classic", name: "Ethereum Classic", symbol: "ETC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "venice-token", name: "Venice Token", symbol: "VVV", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "bfusd", name: "BFUSD", symbol: "BFUSD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "lighter", name: "Lighter", symbol: "LIT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "polygon-ecosystem-token", name: "POL (ex-MATIC)", symbol: "POL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "gatechain-token", name: "Gate", symbol: "GT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "kaspa", name: "Kaspa", symbol: "KAS", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "kucoin-shares", name: "KuCoin", symbol: "KCS", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "blockchain-capital", name: "Blockchain Capital", symbol: "BCAP", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "just", name: "JUST", symbol: "JST", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "pi-network", name: "Pi Network", symbol: "PI", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "quant-network", name: "Quant", symbol: "QNT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "cosmos", name: "Cosmos Hub", symbol: "ATOM", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "jupiter-exchange-solana", name: "Jupiter", symbol: "JUP", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "algorand", name: "Algorand", symbol: "ALGO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "pancakeswap-token", name: "PancakeSwap", symbol: "CAKE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "nexo", name: "NEXO", symbol: "NEXO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "render-token", name: "Render", symbol: "RENDER", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "filecoin", name: "Filecoin", symbol: "FIL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "eutbl", name: "Spiko EU T-Bills Money Market Fund", symbol: "EUTBL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "janus-henderson-anemoy-aaa-clo-fund", name: "Janus Henderson Anemoy AAA CLO Fund", symbol: "JAAA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "dash", name: "Dash", symbol: "DASH", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "injective-protocol", name: "Injective", symbol: "INJ", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "superstate-short-duration-us-government-securities-fund-ustb", name: "Invesco Short Duration US Government Securities Fund", symbol: "USTB", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "vechain", name: "VeChain", symbol: "VET", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ether-fi", name: "Ether.fi", symbol: "ETHFI", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "gho", name: "GHO", symbol: "GHO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "stable-2", name: "​​Stable", symbol: "STABLE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "aerodrome-finance", name: "Aerodrome Finance", symbol: "AERO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "aptos", name: "Aptos", symbol: "APT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "blockstack", name: "Stacks", symbol: "STX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "beldex", name: "Beldex", symbol: "BDX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "flare-networks", name: "Flare", symbol: "FLR", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "xdce-crowd-sale", name: "XDC Network", symbol: "XDC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "official-trump", name: "Official Trump", symbol: "TRUMP", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "usual-usd", name: "Usual USD", symbol: "USD0", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "magic-hash", name: "Magic Hash", symbol: "MHA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "curve-dao-token", name: "Curve DAO", symbol: "CRV", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ylds", name: "YLDS", symbol: "YLDS", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "bianrensheng", name: "币安人生 (BinanceLife)", symbol: "币安人生", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "pudgy-penguins", name: "Pudgy Penguins", symbol: "PENGU", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "true-usd", name: "TrueUSD", symbol: "TUSD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "raydium", name: "Raydium", symbol: "RAY", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "usdtb", name: "USDtb", symbol: "USDTB", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "pyth-network", name: "Pyth Network", symbol: "PYTH", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "pendle", name: "Pendle", symbol: "PENDLE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "a7a5", name: "A7A5", symbol: "A7A5", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "euro-coin", name: "EURC", symbol: "EURC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "spx6900", name: "SPX6900", symbol: "SPX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "virtual-protocol", name: "Virtuals Protocol", symbol: "VIRTUAL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "pons", name: "Pons", symbol: "PONS", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "pieverse", name: "Pieverse", symbol: "PIEVERSE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "fetch-ai", name: "Artificial Superintelligence Alliance", symbol: "FET", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "hash-2", name: "Provenance Blockchain", symbol: "HASH", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "midnight-3", name: "Midnight", symbol: "NIGHT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "layerzero", name: "LayerZero", symbol: "ZRO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "celestia", name: "Celestia", symbol: "TIA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "falcon-finance-ff", name: "Falcon Finance", symbol: "FF", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "derive", name: "Derive", symbol: "DRV", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "tezos", name: "Tezos", symbol: "XTZ", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "bitcoin-cash-sv", name: "Bitcoin SV", symbol: "BSV", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "unibase", name: "Unibase", symbol: "UB", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "janus-henderson-anemoy-treasury-fund", name: "Janus Henderson Anemoy Treasury Fund", symbol: "JTRSY", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "kinesis-gold", name: "Kinesis Gold", symbol: "KAU", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "lido-dao", name: "Lido DAO", symbol: "LDO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "starknet", name: "Starknet", symbol: "STRK", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "sei-network", name: "Sei", symbol: "SEI", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "sun-token", name: "Sun Token", symbol: "SUN", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "bittorrent", name: "BitTorrent", symbol: "BTT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ousg", name: "Ondo Short-Term U.S. Government Bond Fund", symbol: "OUSG", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "sofiusd", name: "SoFiUSD", symbol: "SOFID", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "first-digital-usd", name: "First Digital USD", symbol: "FDUSD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "apxusd", name: "apxUSD", symbol: "APXUSD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "gnosis", name: "Gnosis", symbol: "GNO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "decred", name: "Decred", symbol: "DCR", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "arweave", name: "Arweave", symbol: "AR", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "usdai", name: "USDai", symbol: "USDAI", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "olympus", name: "Olympus", symbol: "OHM", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "bedrock-token", name: "Bedrock", symbol: "BR", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "monad", name: "Monad", symbol: "MON", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "artificial-inu-3", name: "Artificial Inu", symbol: "AI", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "optimism", name: "Optimism", symbol: "OP", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "terra-luna", name: "Terra Luna Classic", symbol: "LUNC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "pearl-2", name: "Pearl", symbol: "PRL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "re-protocol-reusd", name: "Re Protocol reUSD", symbol: "REUSD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "kite-2", name: "Kite", symbol: "KITE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "useless-3", name: "Useless Coin", symbol: "USELESS", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ethereum-name-service", name: "Ethereum Name Service", symbol: "ENS", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "bonk", name: "Bonk", symbol: "BONK", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "conflux-token", name: "Conflux", symbol: "CFX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "syrup", name: "Maple Finance", symbol: "SYRUP", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ape-and-pepe", name: "Ape and Pepe", symbol: "APEPE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "plasma", name: "Plasma", symbol: "XPL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "floki", name: "FLOKI", symbol: "FLOKI", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "kinesis-silver", name: "Kinesis Silver", symbol: "KAG", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "trust-wallet-token", name: "Trust Wallet", symbol: "TWT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "apenft", name: "AINFT", symbol: "NFT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "jito-governance-token", name: "Jito", symbol: "JTO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "agora-dollar", name: "AUSD", symbol: "AUSD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "grass", name: "Grass", symbol: "GRASS", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "usx", name: "USX", symbol: "USX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "bnb48-club-token", name: "KOGE", symbol: "KOGE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "the-graph", name: "The Graph", symbol: "GRT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "lobster-2", name: "龙虾 (Lobster)", symbol: "龙虾", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "eigenlayer", name: "EigenCloud (prev. EigenLayer)", symbol: "EIGEN", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "iota", name: "IOTA", symbol: "IOTA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "theta-token", name: "Theta Network", symbol: "THETA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "frax", name: "Legacy Frax Dollar", symbol: "FRAX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ribbita-by-virtuals", name: "Ribbita by Virtuals", symbol: "TIBBIR", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "crvusd", name: "crvUSD", symbol: "CRVUSD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "compound-governance-token", name: "Compound", symbol: "COMP", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "cash-cat", name: "Cash Cat", symbol: "CASHCAT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "dogwifcoin", name: "dogwifhat", symbol: "WIF", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "stonk-3", name: "STONK", symbol: "STONK", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "build-on", name: "BUILDon", symbol: "B", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "tradable-na-rent-financing-platform-sstn", name: "Tradable NA Rent Financing Platform SSTN", symbol: "PC0000031", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "railgun", name: "Railgun", symbol: "RAIL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "edgex", name: "edgeX", symbol: "EDGE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "grx-chain", name: "GRX Chain", symbol: "GRX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "jasmycoin", name: "JasmyCoin", symbol: "JASMY", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "kaia", name: "Kaia", symbol: "KAIA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "societe-generale-forge-eurcv", name: "EUR CoinVertible", symbol: "EURCV", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "non-playable-coin", name: "Non-Playable Coin", symbol: "NPC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "zama", name: "Zama", symbol: "ZAMA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "convex-finance", name: "Convex Finance", symbol: "CVX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "usa", name: "USAT", symbol: "USAT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "zebec-network", name: "Zebec Network", symbol: "ZBCN", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "safo", name: "Spiko Amundi Overnight Swap Fund", symbol: "SAFO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "thorchain", name: "THORChain", symbol: "RUNE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "axie-infinity", name: "Axie Infinity", symbol: "AXS", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "apyusd", name: "apyUSD", symbol: "APYUSD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "collector-crypt", name: "Collector Crypt", symbol: "CARDS", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "doublezero", name: "DoubleZero", symbol: "2Z", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "neo", name: "NEO", symbol: "NEO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "akash-network", name: "Akash Network", symbol: "AKT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "coco-2", name: "coco", symbol: "COCO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "btse-token", name: "BTSE Token", symbol: "BTSE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "swissborg", name: "SwissBorg", symbol: "BORG", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "spiko-us-t-bills-money-market-fund", name: "Spiko US T-Bills Money Market Fund", symbol: "USTBL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "mx-token", name: "MX", symbol: "MX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "chain-2", name: "Onyxcoin", symbol: "XCN", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ecash", name: "eCash", symbol: "XEC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "tradable-apac-diversified-finance-provider-sstn", name: "Tradable APAC Diversified Finance Provider SSTN", symbol: "PC0000033", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ultima", name: "Ultima", symbol: "ULTIMA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "fartcoin", name: "Fartcoin", symbol: "FARTCOIN", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "decentraland", name: "Decentraland", symbol: "MANA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "chiliz", name: "Chiliz", symbol: "CHZ", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "vision-3", name: "Vision", symbol: "VSN", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "kamino", name: "Kamino", symbol: "KMNO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "humanity", name: "Humanity", symbol: "H", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "antfun", name: "AntFun", symbol: "ANTFUN", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "strategy-pp-variable-xstock", name: "Strategy PP Variable xStock", symbol: "STRCX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "shuffle-2", name: "Shuffle", symbol: "SHFL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "telcoin", name: "Telcoin", symbol: "TEL", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "origintrail", name: "OriginTrail", symbol: "TRAC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "vaulta", name: "Vaulta", symbol: "A", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "gusd", name: "GUSD", symbol: "GUSD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "safepal", name: "SafePal", symbol: "SFP", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "zencash", name: "Horizen", symbol: "ZEN", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "gmt-token", name: "GoMining Token", symbol: "GOMINING", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "dgrid-ai", name: "DGrid AI", symbol: "DGAI", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "mina-protocol", name: "Mina Protocol", symbol: "MINA", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "backpack", name: "Backpack", symbol: "BP", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "meteora", name: "Meteora", symbol: "MET", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "apecoin", name: "ApeCoin", symbol: "APE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "1inch", name: "1INCH", symbol: "1INCH", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "stp-network", name: "AWE Network", symbol: "AWE", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "seeker", name: "Seeker", symbol: "SKR", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "tradable-latam-fintech-sstn", name: "Tradable LatAm Fintech SSTN", symbol: "PC0000097", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "jpycoin", name: "JPY Coin", symbol: "JPYC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "meta-2-2", name: "MetaDAO", symbol: "META", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "havven", name: "Synthetix", symbol: "SNX", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "sentient", name: "Sentient", symbol: "SENT", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "zano", name: "Zano", symbol: "ZANO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "cash-4", name: "CASH", symbol: "CASH", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "jpysc", name: "JPYSC", symbol: "JPYSC", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "elrond-erd-2", name: "MultiversX", symbol: "EGLD", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "rollbit-coin", name: "Rollbit Coin", symbol: "RLB", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "sonic-3", name: "Sonic", symbol: "S", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "ozone-chain", name: "Ozone Chain", symbol: "OZO", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "blorb", name: "BLORB", symbol: "BLORB", paprikaID: "", exchangeSymbol: nil, networks: []),
        .init(id: "immutable-x", name: "Immutable", symbol: "IMX", paprikaID: "", exchangeSymbol: nil, networks: [])
    ]

}

struct MarketQuote: Codable, Sendable, Equatable {
    let price: Double
    let change24h: Double?
    let marketCap: Double?
    let volume: Double?
    let high24h: Double?
    let low24h: Double?
    let supply: Double?
    let rank: Int?
    let image: String?
    let updatedAt: Date
    let source: String

    // Independent timestamp prevents price-only refreshes from making an old
    // percentage look fresh. Optional for compatibility with existing caches.
    var changeUpdatedAt: Date? = nil

    func merging(_ incoming: Self) -> Self {
        guard incoming.isValid else { return self }
        let latest = incoming.updatedAt >= updatedAt ? incoming : self
        let older = incoming.updatedAt >= updatedAt ? self : incoming
        let changeQuote = [self, incoming].filter {
            $0.change24h?.isFinite == true &&
            latest.updatedAt.timeIntervalSince($0.changeUpdatedAt ?? $0.updatedAt) <= 900
        }.max { ($0.changeUpdatedAt ?? $0.updatedAt) < ($1.changeUpdatedAt ?? $1.updatedAt) }
        return Self(price: latest.price, change24h: changeQuote?.change24h,
            marketCap: latest.marketCap, volume: latest.volume,
            high24h: latest.high24h, low24h: latest.low24h,
            supply: latest.supply, rank: latest.rank,
            image: latest.image ?? older.image, updatedAt: latest.updatedAt, source: latest.source,
            changeUpdatedAt: changeQuote.map { $0.changeUpdatedAt ?? $0.updatedAt })
    }

    var isValid: Bool { price.isFinite && price > 0 && updatedAt <= Date().addingTimeInterval(300) }
}

struct MarketPoint: Codable, Sendable, Equatable, Identifiable {
    let date: Date
    let price: Double
    var id: Date { date }

    static func normalized(_ values: [Self], since: Date) -> [Self] {
        var unique: [Date: Self] = [:]
        for point in values where point.price.isFinite && point.price > 0 && point.date >= since && point.date <= Date().addingTimeInterval(300) {
            unique[point.date] = point
        }
        return unique.values.sorted { $0.date < $1.date }
    }
}

struct MarketHistory: Codable, Sendable {
    let points: [MarketPoint]
    let source: String
    let updatedAt: Date
}
struct MarketInfo: Codable, Sendable {
    let description: String
    let website: String?
    let source: String
    let updatedAt: Date
}
struct MarketRecord: Codable, Sendable {
    var quote: MarketQuote?
    var info: MarketInfo?
    var histories: [String: MarketHistory] = [:]
    var previousStatistics: MarketQuote? = nil

    var statistics: MarketQuote? {
        if let quote, quote.marketCap != nil { return quote }
        return previousStatistics ?? quote
    }

    mutating func merge(_ other: Self) {
        if let incoming = other.previousStatistics, incoming.isValid,
           incoming.updatedAt >= (previousStatistics?.updatedAt ?? .distantPast) { previousStatistics = incoming }
        if let incoming = other.quote, incoming.isValid {
            for candidate in [quote, incoming].compactMap({ $0 }) where candidate.marketCap != nil {
                if candidate.updatedAt >= (previousStatistics?.updatedAt ?? .distantPast) {
                    previousStatistics = candidate
                }
            }
            quote = quote.map { $0.merging(incoming) } ?? incoming
        }
        if let incoming = other.info, incoming.updatedAt >= (info?.updatedAt ?? .distantPast) { info = incoming }
        for (range, history) in other.histories where history.updatedAt >= (histories[range]?.updatedAt ?? .distantPast) && !history.points.isEmpty {
            histories[range] = history
        }
    }
}
enum MarketRange: String, CaseIterable, Identifiable, Sendable {
    case day = "1D", week = "1W", month = "1M", year = "1Y"
    var id: String { rawValue }
    var days: Int { switch self { case .day: 1; case .week: 7; case .month: 30; case .year: 365 } }
    var seconds: TimeInterval { Double(days) * 86_400 }
    var granularity: Int { switch self { case .day: 900; case .week: 3600; case .month: 21600; case .year: 86400 } }
}


/// Limits tactile output to distinct samples and 20 ticks/sec. Strength is
/// relative to the visible range, so inexpensive coins feel as clear as BTC.
struct MarketScrubFeedback {
    private var previous: MarketPoint?
    private var lastTime = -Double.infinity

    mutating func reset() { previous = nil; lastTime = -.infinity }

    mutating func intensity(for point: MarketPoint, span: Double, endpoint: Bool, time: Double) -> Double? {
        guard point.price.isFinite, time.isFinite, previous?.id != point.id,
              time - lastTime >= 0.05 else { return nil }
        defer { previous = point; lastTime = time }
        guard let previous else { return 0.7 }
        if endpoint { return 1 }
        let movement = abs(point.price - previous.price) / max(span, 0.000000001)
        return min(1, 0.45 + movement * 5)
    }
}

/// Uses the current market quote, independently of chart scrubbing and wallet holdings.
enum MarketConversion {
    static func sanitizedAmount(_ input: String) -> String {
        let digits = input.map { character -> String in
            if let value = character.wholeNumberValue, (0...9).contains(value) { return String(value) }
            return String(character)
        }.joined()
        return CurrencyConverterEngine.sanitizedAmount(digits)
    }

    static func coinValue(amount: String, price: Double?, rate: Decimal) -> Decimal? {
        guard let price, price.isFinite, price > 0, rate > 0,
              let unitPrice = Decimal(string: String(price), locale: Locale(identifier: "en_US_POSIX")),
              let quantity = CurrencyConverterEngine.amount(from: sanitizedAmount(amount)), quantity >= 0 else { return nil }
        let localPrice = unitPrice * rate
        guard !localPrice.isNaN, localPrice > 0 else { return nil }
        let value = quantity / localPrice
        return value.isNaN ? nil : value
    }

    static func localValue(amount: String, price: Double?, rate: Decimal) -> Decimal? {
        guard let price, price.isFinite, price > 0, rate > 0,
              let unitPrice = Decimal(string: String(price), locale: Locale(identifier: "en_US_POSIX")),
              let quantity = CurrencyConverterEngine.amount(from: sanitizedAmount(amount)), quantity >= 0 else { return nil }
        let value = quantity * unitPrice * rate
        return value.isNaN ? nil : value
    }
}

extension MarketDiscoveryCoin {
    var marketCoin: MarketCoin {
        var coin = MarketCoin.all.first { $0.id == id }
            ?? MarketCoin(id: id, name: name, symbol: symbol, paprikaID: "", exchangeSymbol: nil, networks: [])
        coin.discoveryImage = image
        return coin
    }
}
