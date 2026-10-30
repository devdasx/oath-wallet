import Foundation

/// Pinned issuer identities, never a symbol/name search. Mainnet only.
/// Sources and exclusions: Design/StablecoinRestrictions.md.
public struct StablecoinRestrictionToken: Hashable, Sendable {
    public let network: String
    public let symbol: String
    public let reference: String
    let method: String
    public var id: String { network + ":" + reference }
}

public enum StablecoinRestrictionRegistry {
    public static let tokens: [StablecoinRestrictionToken] = {
        var tokens: [StablecoinRestrictionToken] = []
        func add(_ network: String, _ symbol: String, _ reference: String, _ method: String) {
            tokens.append(.init(network: network, symbol: symbol, reference: reference, method: method))
        }
        for (network, address) in [
            ("ethereum", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"),
            ("arbitrum", "0xaf88d065e77c8cc2239327c5edb3a432268e5831"),
            ("arc", "0x3600000000000000000000000000000000000000"),
            ("avalanche", "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e"),
            ("base", "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"),
            ("celo", "0xceba9300f2b948710d2653dd7b07f33a8b32118c"),
            ("hyperevm", "0xb88339cb7199b77e23db6e890353e22632ba630f"),
            ("linea", "0x176211869ca2b568f2a7d4ee941e073a821ee1ff"),
            ("monad", "0x754704bc059f8c67012fed69bc8a327a5aafb603"),
            ("optimism", "0x0b2c639c533813f4aa9d7837caf62653d097ff85"),
            ("polygon", "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359"),
            ("unichain", "0x078d782b760474a361dda0af3839290b0ef57ad6"),
            ("xlayer", "0xb6ceceab302e2e4948951ee7843fc24e92933061")
        ] { add(network, "USDC", address, "isBlacklisted(address)") }
        add("ethereum", "USDT", "0xdac17f958d2ee523a2206206994597c13d831ec7", "isBlackListed(address)")
        add("avalanche", "USDT", "0x9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7", "isBlocked(address)")
        add("celo", "USDT", "0x48065fbbe25f71c9282ddf5e1cd6d6a887483d5e", "isBlocked(address)")
        for (network, address) in [
            ("arbitrum", "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9"),
            ("flare", "0xe7cd86e13ac4309349f30b3435a9d337750fc82d"),
            ("hyperevm", "0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb"),
            ("monad", "0xe7cd86e13ac4309349f30b3435a9d337750fc82d"),
            ("optimism", "0x01bff41798a0bcf287b996046ca68b395dbc1071"),
            ("polygon", "0xc2132d05d31c914a87c6611c10748aeb04b58e8f"),
            ("unichain", "0x9151434b16b9763660705744891fa906f660ecc5"),
            ("xlayer", "0x779ded0c9e1022225f8e0630b35a9b54be713736")
        ] { add(network, "USDT0", address, "isBlocked(address)") }
        add("tron", "USDT", "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "isBlackListed(address)")
        // Issuance was discontinued, but existing holders can still be blocked.
        add("tron", "USDC", "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8", "isBlacklisted(address)")
        add("solana", "USDT", "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", "frozen")
        add("solana", "USDC", "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", "frozen")
        add("near", "USDT", "usdt.tether-token.near", "get_blacklist_status")
        add("near", "USDC", "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1", "is_blocklisted")
        add("aptos", "USDT", "0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b",
            "0xf73e887a8754f540ee6e1a93bdc6dde2af69fc7ca5de32013e89dd44244473cb::usdt::is_frozen")
        add("aptos", "USDC", "0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b",
            "0xe5c5befe31ce06bc1f2fd31210988aac08af6d821b039935557a6f14c03471be::blocklistable::is_blocklisted")
        add("stellar", "USDC", "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN", "USDC")
        add("stellar", "USDT0", "GATISXX6BZ6NC7IKQBY37CJD4SOZL3CYZJWXEDG6JVIY4WBS6KXJHN6Q", "USDT0")
        add("sui", "USDC", "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC", "deny_list_v2")
        add("xrpl", "USDC", "rGm7WCVp9gb4jZHWTEtGUr4dd74z2XuWhE", "5553444300000000000000000000000000000000")
        add("ton", "USDT", TonIdentity.usdt, "get_status")
        return tokens
    }()
    public static func tokens(network: String) -> [StablecoinRestrictionToken] {
        tokens.filter { $0.network == network }
    }
    static let evmIDs: [String: UInt64] = [
        "ethereum": 1, "arbitrum": 42161, "arc": 5042, "avalanche": 43114,
        "base": 8453, "celo": 42220, "hyperevm": 999, "linea": 59144, "monad": 143,
        "optimism": 10, "polygon": 137, "unichain": 130, "xlayer": 196, "flare": 14
    ]
}

public struct StablecoinRestrictionAccount: Hashable, Sendable {
    public let network: String
    public let address: String
    public init(network: String, address: String) { self.network = network; self.address = address }
}

public enum StablecoinRestrictionOutcome: String, Codable, Sendable {
    case restricted, notDetected, unavailable
}

public struct StablecoinRestrictionResult: Sendable, Equatable {
    public let token: StablecoinRestrictionToken
    public let outcome: StablecoinRestrictionOutcome
    public init(token: StablecoinRestrictionToken, outcome: StablecoinRestrictionOutcome) {
        self.token = token; self.outcome = outcome
    }
}
