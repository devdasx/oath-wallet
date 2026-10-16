import Foundation

/// Receiving rules belong to the network, never to the token whose detail
/// screen opened Receive. The catalog is illustrative, not an allowlist.
struct OathReceiveNetworkGuide: Sendable {
    let chain: OathImportChain
    var robinhoodIndexAvailable = false
    var arcIndexAvailable = false

    var supportsTokens: Bool {
        switch chain {
        case .bitcoin, .bitcoincash, .dogecoin, .litecoin: false
        case .aptos, .arbitrum, .arc, .avalanche, .base, .bnb, .ethereum, .fantom, .flare, .somnia, .story,
             .gnosis, .linea, .near, .optimism, .polygon, .monad, .unichain, .hyperevm, .robinhood, .scroll, .solana,
             .stellar, .sui, .taiko, .telos, .thorchain, .ton, .tron, .xlayer, .xrpl: true
        }
    }

    var notice: OathStringKey {
        switch chain {
        case .stellar, .xrpl: .receiveTrustlineNotice
        case .near: .receiveRegistrationNotice
        default: supportsTokens ? .receiveTokenNotice : .receiveNativeNotice
        }
    }

    var explanation: OathStringKey {
        switch chain {
        case .bitcoin, .bitcoincash, .dogecoin, .litecoin: .receiveNativeExplanation
        case .solana: .receiveSolanaExplanation
        case .stellar, .xrpl: .receiveTrustlineExplanation
        case .thorchain: .receiveThorchainExplanation
        case .near: .receiveNearExplanation
        case .aptos: .receiveAptosExplanation
        case .sui: .receiveSuiExplanation
        case .ton: .receiveJettonExplanation
        case .tron: .receiveTronExplanation
        case .arbitrum, .arc, .avalanche, .base, .bnb, .ethereum, .fantom, .flare, .somnia, .story, .gnosis,
             .linea, .optimism, .polygon, .monad, .unichain, .hyperevm, .robinhood, .scroll, .taiko, .telos, .xlayer: .receiveEVMExplanation
        }
    }

    var trackingExplanation: OathStringKey {
        if chain == .arc && !arcIndexAvailable { return .receiveManualTracking }
        if chain == .robinhood && !robinhoodIndexAvailable { return .receiveManualTracking }
        if chain == .bitcoin { return .bitcoinReceiveTracking }
        if !supportsTokens { return .receiveNativeTracking }
        if chain.isEVM || chain == .solana || chain == .tron || chain == .ton || chain == .aptos || chain == .sui || chain == .thorchain || chain == .near || chain == .xrpl || chain == .stellar { return .receiveIndexedTracking }
        if chain.isEVM { return .receiveManualTracking }
        return .receiveDeferredTracking
    }
}

struct OathReceiveExample: Decodable, Identifiable, Equatable, Sendable {
    /// Includes the network and exact contract/mint/issuer identity. Symbols
    /// alone cannot distinguish bridged tokens or assets with the same name.
    let id: String
    let name: String
    let symbol: String
    let artwork: String
}

struct OathReceiveExampleCatalog: Decodable, Sendable {
    let networks: [String: [OathReceiveExample]]

    static let bundled: Self = {
        guard let url = Bundle.main.url(forResource: "ReceiveAssets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Self.self, from: data) else {
            // An address and QR remain usable if optional artwork is missing.
            return Self(networks: [:])
        }
        return catalog
    }()

    func examples(for chain: OathImportChain) -> [OathReceiveExample] {
        guard OathReceiveNetworkGuide(chain: chain).supportsTokens else { return [] }
        return Array((networks[chain.id] ?? []).prefix(10))
    }
}
