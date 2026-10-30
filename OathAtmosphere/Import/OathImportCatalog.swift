import Foundation

/// Shared network catalog for onboarding and local wallet address derivation.
public enum OathImportChain: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case aptos, arbitrum, arc, avalanche, base, bitcoin, bitcoincash, bnb, dogecoin
    case iotex, zerog, sei, chiliz, filecoin, ethereum, fantom, flare, gnosis, hyperevm, celo, monad, unichain, linea, litecoin, near, optimism, polygon, robinhood, scroll, solana, somnia, story
    case polkadot, stellar, sui, taiko, telos, thorchain, ton, tron, xlayer, xrpl

    public var id: String { rawValue }
    public var logoAsset: String { "network-" + rawValue }

    public var name: String {
        switch self {
        case .aptos: "Aptos"
        case .arbitrum: "Arbitrum"
        case .arc: "Arc"
        case .avalanche: "Avalanche C-Chain"
        case .base: "Base"
        case .bitcoin: "Bitcoin"
        case .bitcoincash: "Bitcoin Cash"
        case .bnb: "BNB Smart Chain"
        case .dogecoin: "Dogecoin"
        case .ethereum: "Ethereum"
        case .fantom: "Fantom"
        case .flare: "Flare"
        case .gnosis: "Gnosis"
        case .linea: "Linea"
        case .litecoin: "Litecoin"
        case .near: "NEAR Protocol"
        case .optimism: "Optimism"
        case .polygon: "Polygon"
        case .chiliz: "Chiliz"
        case .iotex: "IoTeX"
        case .zerog: "0G"
        case .sei: "Sei"
        case .filecoin: "Filecoin"
        case .celo: "Celo"
        case .monad: "Monad"
        case .unichain: "Unichain"
        case .hyperevm: "HyperEVM"
        case .robinhood: "Robinhood Chain"
        case .scroll: "Scroll"
        case .solana: "Solana"
        case .somnia: "Somnia"
        case .story: "Story"
        case .polkadot: "Polkadot"
        case .stellar: "Stellar"
        case .sui: "Sui Network"
        case .taiko: "Taiko"
        case .telos: "Telos"
        case .thorchain: "THORChain"
        case .ton: "Gram"
        case .tron: "TRON"
        case .xlayer: "X Layer"
        case .xrpl: "XRP Ledger"
        }
    }

    /// Token support available in Oath; shared by Receive guidance and action routing.
    public var supportsTokens: Bool {
        switch self {
        case .bitcoin, .bitcoincash, .dogecoin, .litecoin: false
        case .aptos, .arbitrum, .arc, .avalanche, .base, .bnb, .ethereum, .fantom, .flare, .somnia, .story,
             .gnosis, .linea, .near, .optimism, .polygon, .chiliz, .filecoin, .sei, .zerog, .iotex, .celo, .monad, .unichain, .hyperevm, .robinhood, .scroll, .solana,
             .polkadot, .stellar, .sui, .taiko, .telos, .thorchain, .ton, .tron, .xlayer, .xrpl: true
        }
    }


    public var isEVM: Bool {
        switch self {
        case .arbitrum, .arc, .avalanche, .base, .bnb, .ethereum, .fantom, .flare, .gnosis,
             .linea, .optimism, .polygon, .chiliz, .filecoin, .sei, .zerog, .iotex, .celo, .monad, .unichain, .hyperevm, .robinhood, .scroll, .somnia, .story, .taiko, .telos, .xlayer: true
        default: false
        }
    }

    var searchTerms: String {
        let aliases: String
        switch self {
        case .aptos: aliases = "APT"
        case .arbitrum: aliases = "ARB"
        case .arc: aliases = "USDC"
        case .avalanche: aliases = "AVAX C Chain"
        case .base: aliases = "ETH"
        case .bitcoin: aliases = "BTC"
        case .bitcoincash: aliases = "BCH"
        case .bnb: aliases = "BSC Binance"
        case .dogecoin: aliases = "DOGE"
        case .ethereum: aliases = "ETH"
        case .fantom: aliases = "FTM"
        case .flare: aliases = "FLR"
        case .gnosis: aliases = "GNO xDAI"
        case .linea: aliases = "ETH"
        case .litecoin: aliases = "LTC"
        case .near: aliases = "NEAR"
        case .optimism: aliases = "OP"
        case .polygon: aliases = "POL MATIC"
        case .chiliz: aliases = "CHZ Chiliz Chain"
        case .iotex: aliases = "IOTX IoTeX EVM"
        case .zerog: aliases = "0G A0GI Zero Gravity Aristotle"
        case .sei: aliases = "SEI Sei EVM Pacific"
        case .filecoin: aliases = "FIL FEVM FVM f410"
        case .celo: aliases = "CELO"
        case .monad: aliases = "MON"
        case .unichain: aliases = "ETH Uniswap"
        case .hyperevm: aliases = "HYPE Hyperliquid Hyper EVM"
        case .robinhood: aliases = "ETH Robinhood Chain"
        case .scroll: aliases = "SCR"
        case .solana: aliases = "SOL"
        case .somnia: aliases = "SOMI"
        case .story: aliases = "IP"
        case .polkadot: aliases = "DOT Asset Hub"
        case .stellar: aliases = "XLM"
        case .sui: aliases = "SUI"
        case .taiko: aliases = "TAIKO"
        case .telos: aliases = "TLOS Telos EVM"
        case .thorchain: aliases = "RUNE TCY RUJI Rujira THOR"
        case .ton: aliases = "GRAM TON Toncoin The Open Network"
        case .tron: aliases = "TRX"
        case .xlayer: aliases = "OKB OKX"
        case .xrpl: aliases = "XRP Ripple"
        }
        return "\(name) \(rawValue) \(aliases)"
    }
}

/// EVM networks have one import identity and one callback, including shortcuts.
public struct OathPrivateKeyChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let networks: [OathImportChain]
    public var isEVM: Bool { id == "evm" }

    init(id: String, title: String, networks: [OathImportChain]) {
        self.id = id
        self.title = title
        self.networks = networks
    }

    public static let evm = Self(
        id: "evm", title: "Ethereum & EVM",
        networks: [.ethereum] + OathImportChain.allCases.filter { $0.isEVM && $0 != .ethereum }
    )
    public static let individual = OathImportChain.allCases.filter { !$0.isEVM }.map {
        Self(id: $0.id, title: $0.name, networks: [$0])
    }
    public static let all = [evm] + individual

    public var logoPreviewNetworks: [OathImportChain] {
        let preferred: [OathImportChain] = [.ethereum, .bnb, .base, .arbitrum, .polygon]
        let ordered = preferred.filter(networks.contains) + networks.filter { !preferred.contains($0) }
        return Array(ordered.prefix(5))
    }

    public var additionalNetworkCount: Int { networks.count - logoPreviewNetworks.count }

    public static func matching(_ query: String, localizedEVMTitle: String? = nil,
                                availableNetworks: [OathImportChain]? = nil) -> [Self] {
        let choices = availableNetworks.map { available in
            all.compactMap { choice -> Self? in
                let included = choice.networks.filter(available.contains)
                return included.isEmpty ? nil : Self(id: choice.id, title: choice.title, networks: included)
            }
        } ?? all
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return choices }
        return choices.filter { choice in
            if choice.isEVM, let title = localizedEVMTitle,
               words.allSatisfy({ title.localizedStandardContains($0) }) { return true }
            // Every search term must match the same network, rather than
            // combining unrelated names from two members of the EVM group.
            return choice.networks.contains { network in
                let text = choice.isEVM ? "EVM \(network.searchTerms)" : network.searchTerms
                return words.allSatisfy { text.localizedStandardContains($0) }
            } || words.allSatisfy { choice.title.localizedStandardContains($0) }
        }
    }
}
