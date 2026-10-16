import Foundation

/// Explicit chain identity and fee policies. Arc retains its separate USDC-gas adapter.
public enum EVMSendNetwork: String, Codable, CaseIterable, Sendable {
    case ethereum, arbitrum, avalanche, base, bnb, fantom, flare, somnia, story, gnosis
    case linea, optimism, polygon, monad, unichain, hyperevm, robinhood, scroll, taiko, telos, xlayer
    case arbitrumSepolia, ethereumSepolia
    public var isTestnet: Bool { self == .arbitrumSepolia || self == .ethereumSepolia }
    public var chainID: UInt64 {
        switch self {
        case .ethereum: 1; case .arbitrum: 42161; case .avalanche: 43114; case .base: 8453
        case .bnb: 56; case .fantom: 250; case .flare: 14; case .somnia: 5031; case .story: 1514
        case .gnosis: 100; case .linea: 59144; case .optimism: 10; case .polygon: 137
        case .monad: 143; case .unichain: 130; case .hyperevm: 999; case .robinhood: 4663
        case .scroll: 534352; case .taiko: 167000; case .telos: 40; case .xlayer: 196
        case .arbitrumSepolia: 421614; case .ethereumSepolia: 11155111
        }
    }
    public var symbol: String {
        switch self {
        case .avalanche: "AVAX"; case .bnb: "BNB"; case .fantom: "FTM"; case .flare: "FLR"
        case .somnia: "SOMI"; case .story: "IP"; case .gnosis: "xDAI"; case .polygon: "POL"
        case .monad: "MON"; case .hyperevm: "HYPE"; case .telos: "TLOS"; case .xlayer: "OKB"
        default: "ETH"
        }
    }
    var opStack: Bool { [.base,.optimism,.unichain].contains(self) }
    var oracle: String? {
        if opStack { return "0x420000000000000000000000000000000000000f" }
        if self == .scroll { return "0x5300000000000000000000000000000000000002" }
        return nil // Arbitrum includes its parent-chain cost in eth_estimateGas.
    }
    var stateTag: String { "latest" }
    var nonceTag: String { self == .hyperevm ? "latest" : "pending" }
    // These networks expose immediate consensus finality via latest. Others use
    // finalized; never silently treat an unsupported finality query as success.
    var finalityTag: String { [.hyperevm,.fantom,.telos].contains(self) ? "latest" : "finalized" }
    var maximumGas: UInt64 { self == .hyperevm ? 2_000_000 : 5_000_000 }
}

public enum EVMSendIdentity {
    public static func address(_ value: String) throws -> String { try IndexedEVMIdentity.address(value) }
    public static func reference(_ value: String) throws -> String { value == "native" ? value : try address(value) }
    static let transferTopic = ArcIdentity.transferTopic
}
