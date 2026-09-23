import Foundation

/// Each chain owns a complete sentence so translations can use natural grammar
/// and describe only formats accepted by its address validator and name parser.
/// Non-EVM prompts advertise chain-specific formats, not ENS cross-chain records.
/// These hints are intentionally narrower than the resolver's accepted inputs.
enum SendRecipientPlaceholder {
    static func key(for networkID: String) -> String {
        guard let blockchain = AssetNetworkSelectorOption.blockchain(for: networkID) else {
            return "send.recipient.placeholder"
        }
        switch blockchain {
        case .bitcoin: return "send.recipient.placeholder.bitcoin"
        case .bitcoincash: return "send.recipient.placeholder.bitcoin_cash"
        case .litecoin: return "send.recipient.placeholder.litecoin"
        case .dogecoin: return "send.recipient.placeholder.dogecoin"
        case .ethereum: return "send.recipient.placeholder.ethereum"
        case .smartchain: return "send.recipient.placeholder.bnb_smart_chain"
        case .polygon: return "send.recipient.placeholder.polygon"
        case .arbitrum: return "send.recipient.placeholder.arbitrum"
        case .avalanchec: return "send.recipient.placeholder.avalanche"
        case .optimism: return "send.recipient.placeholder.optimism"
        case .base: return "send.recipient.placeholder.base"
        case .xdai: return "send.recipient.placeholder.gnosis"
        case .scroll: return "send.recipient.placeholder.scroll"
        case .linea: return "send.recipient.placeholder.linea"
        case .taiko: return "send.recipient.placeholder.taiko"
        case .telos: return "send.recipient.placeholder.telos"
        case .xlayer: return "send.recipient.placeholder.x_layer"
        case .arc: return "send.recipient.placeholder.arc"
        case .tron: return "send.recipient.placeholder.tron"
        case .solana: return "send.recipient.placeholder.solana"
        case .ton: return "send.recipient.placeholder.ton"
        case .sui: return "send.recipient.placeholder.sui"
        case .aptos: return "send.recipient.placeholder.aptos"
        case .near: return "send.recipient.placeholder.near"
        case .xrp: return "send.recipient.placeholder.xrp"
        case .stellar: return "send.recipient.placeholder.stellar"
        }
    }
}
