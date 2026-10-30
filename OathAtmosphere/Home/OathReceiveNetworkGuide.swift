import Foundation
import OathDiagnostics
import OathAnkr

/// Receiving rules belong to the network, never to the token whose detail
/// screen opened Receive. The catalog is illustrative, not an allowlist.
struct OathReceiveNetworkGuide: Sendable {
    let chain: OathImportChain
    var robinhoodIndexAvailable = false
    var arcIndexAvailable = false

    var supportsTokens: Bool { chain.supportsTokens }

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
        case .polkadot: .receivePolkadotExplanation
        case .aptos: .receiveAptosExplanation
        case .sui: .receiveSuiExplanation
        case .ton: .receiveJettonExplanation
        case .tron: .receiveTronExplanation
        case .arbitrum, .arc, .avalanche, .base, .bnb, .ethereum, .fantom, .flare, .somnia, .story, .gnosis,
             .linea, .optimism, .polygon, .chiliz, .filecoin, .sei, .zerog, .iotex, .celo, .monad, .unichain, .hyperevm, .robinhood, .scroll, .taiko, .telos, .xlayer: .receiveEVMExplanation
        }
    }

    var trackingExplanation: OathStringKey {
        if chain == .arc && !arcIndexAvailable { return .receiveManualTracking }
        if chain == .robinhood && !robinhoodIndexAvailable { return .receiveManualTracking }
        if chain == .bitcoin { return .bitcoinReceiveTracking }
        if !supportsTokens { return .receiveNativeTracking }
        if chain.isEVM || chain == .solana || chain == .tron || chain == .ton || chain == .aptos || chain == .sui || chain == .thorchain || chain == .near || chain == .xrpl || chain == .stellar || chain == .polkadot { return .receiveIndexedTracking }
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
    let usesRedesignedArtwork: Bool?
}

struct OathReceiveExampleCatalog: Decodable, Sendable {
    let networks: [String: [OathReceiveExample]]
    private let redesigned: [String: String]

    private enum CodingKeys: String, CodingKey { case networks }

    init(networks: [String: [OathReceiveExample]]) {
        self.networks = networks
        var artwork: [String: String] = [:]
        for (network, examples) in networks {
            for example in examples where example.usesRedesignedArtwork == true {
                let prefix = network + ":"
                guard example.id.hasPrefix(prefix),
                      let key = Self.artworkKey(networkID: network, reference: String(example.id.dropFirst(prefix.count))) else { continue }
                artwork[key] = example.artwork
            }
        }
        redesigned = artwork
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(networks: try container.decode([String: [OathReceiveExample]].self, forKey: .networks))
    }

    static let bundled = load(from: Bundle.main.url(forResource: "ReceiveAssets", withExtension: "json"))

    static func load(from url: URL?) -> Self {
        OathDiagnostics.$operationID.withValue(UUID()) {
            do {
                guard let url else { throw DiagnosticFailure("receive_example_catalog_missing") }
                return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            } catch {
                OathDiagnostics.record(error, component: "receive", operation: "example_catalog_load")
                // The address and QR remain usable even if bundled artwork cannot load.
                return Self(networks: [:])
            }
        }
    }

    func examples(for chain: OathImportChain) -> [OathReceiveExample] {
        guard OathReceiveNetworkGuide(chain: chain).supportsTokens else { return [] }
        return Array((networks[chain.id] ?? []).prefix(10))
    }

    /// Bundled designs override provider images only for a verified network and
    /// token reference. Amount precision and ticker text never select artwork.
    func redesignedArtwork(networkID: String, reference: String) -> String? {
        guard let key = Self.artworkKey(networkID: networkID, reference: reference) else { return nil }
        return redesigned[key]
    }

    private static func artworkKey(networkID: String, reference: String) -> String? {
        guard let chain = OathImportChain(rawValue: networkID), reference.utf8.count <= 4_096 else { return nil }
        let canonical: String
        if reference == "native" { canonical = reference }
        else if chain.isEVM { canonical = reference.lowercased() }
        else {
            // Address-format alternatives are expected validation. Normalizing
            // the exact issuer/mint never permits matching by ticker or name.
            guard let value = try? TokenDiscoveryNetworks.canonical(reference, network: networkID) else { return nil }
            canonical = value
        }
        return networkID + ":" + canonical
    }
}
