import Foundation

/// Explicit chain identity and fee policies. Arc uses this adapter for Safe wallets; ordinary Arc wallets retain their adapter.
public enum EVMSendNetwork: String, Codable, CaseIterable, Sendable {
    case ethereum, arbitrum, avalanche, base, bnb, fantom, flare, somnia, story, gnosis
    case linea, optimism, polygon, chiliz, celo, monad, unichain, hyperevm, robinhood, scroll, taiko, telos, xlayer
    case filecoin, filecoinCalibration, sei, seiTestnet, zerog, zerogGalileo, iotex, iotexTestnet
    case arc, arbitrumSepolia, ethereumSepolia, celoSepolia, chilizSpicy
    public var isTestnet: Bool { self == .arbitrumSepolia || self == .ethereumSepolia || self == .celoSepolia || self == .chilizSpicy || self == .filecoinCalibration || self == .seiTestnet || self == .zerogGalileo || self == .iotexTestnet }
    var isIoTeX: Bool { self == .iotex || self == .iotexTestnet }
    var isFilecoin: Bool { self == .filecoin || self == .filecoinCalibration }
    var isZeroG: Bool { self == .zerog || self == .zerogGalileo }
    var isSei: Bool { self == .sei || self == .seiTestnet }
    public var chainID: UInt64 {
        switch self {
        case .iotex: 4689; case .iotexTestnet: 4690
        case .zerog: 16661; case .zerogGalileo: 16602
        case .sei: 1329; case .seiTestnet: 1328
        case .filecoin: 314; case .filecoinCalibration: 314159
        case .arc: 5042; case .ethereum: 1; case .arbitrum: 42161; case .avalanche: 43114; case .base: 8453
        case .bnb: 56; case .fantom: 250; case .flare: 14; case .somnia: 5031; case .story: 1514
        case .gnosis: 100; case .linea: 59144; case .optimism: 10; case .polygon: 137
        case .chiliz: 88888; case .celo: 42220; case .monad: 143; case .unichain: 130; case .hyperevm: 999; case .robinhood: 4663
        case .scroll: 534352; case .taiko: 167000; case .telos: 40; case .xlayer: 196
        case .chilizSpicy: 88882; case .celoSepolia: 11142220; case .arbitrumSepolia: 421614; case .ethereumSepolia: 11155111
        }
    }
    public var symbol: String {
        switch self {
        case .iotex, .iotexTestnet: "IOTX"
        case .zerog, .zerogGalileo: "0G"
        case .filecoin, .filecoinCalibration: "FIL"
        case .sei, .seiTestnet: "SEI"
        case .arc: "USDC"; case .avalanche: "AVAX"; case .bnb: "BNB"; case .fantom: "FTM"; case .flare: "FLR"
        case .somnia: "SOMI"; case .story: "IP"; case .gnosis: "xDAI"; case .polygon: "POL"
        case .chiliz, .chilizSpicy: "CHZ"; case .celo, .celoSepolia: "CELO"; case .monad: "MON"; case .hyperevm: "HYPE"; case .telos: "TLOS"; case .xlayer: "OKB"
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
    var minimumGas: UInt64 { isIoTeX ? 10_000 : 21_000 }
    var maximumGas: UInt64 { isFilecoin ? 10_000_000_000 : isIoTeX ? 1_000_000 : [.hyperevm,.arc].contains(self) ? 2_000_000 : 5_000_000 }

    func address(_ value: String) throws -> String {
        if isIoTeX { return try IoTeXIdentity.ethereum(value) }
        return isFilecoin ? try FilecoinIdentity.ethereum(value, testnet: isTestnet) : try EVMSendIdentity.address(value)
    }
}

public enum EVMSendIdentity {
    public static func address(_ value: String) throws -> String { try IndexedEVMIdentity.address(value) }
    public static func reference(_ value: String) throws -> String { value == "native" ? value : try address(value) }
    static let transferTopic = ArcIdentity.transferTopic
}
