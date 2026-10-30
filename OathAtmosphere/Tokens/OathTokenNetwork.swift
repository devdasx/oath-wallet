import OathAnkr
import OathTokenImages
import OathDiagnostics
import Foundation
import OathDatabase
import OathBitcoin

/// One registry for token metadata lookup and network identity verification.
struct OathTokenNetwork: Hashable, Sendable {
    let chain: OathImportChain
    let chainID: UInt64?
    let ankrPath: String
    let artworkDirectory: String
    var id: String { chain.id }

    static let all: [Self] = [
        .init(chain: .ethereum, chainID: 1, ankrPath: "eth", artworkDirectory: "ethereum"),
        .init(chain: .arbitrum, chainID: 42161, ankrPath: "arbitrum", artworkDirectory: "arbitrum"),
        .init(chain: .arc, chainID: 5042, ankrPath: "arc", artworkDirectory: "arc"),
        .init(chain: .avalanche, chainID: 43114, ankrPath: "avalanche", artworkDirectory: "avalanchec"),
        .init(chain: .base, chainID: 8453, ankrPath: "base", artworkDirectory: "base"),
        .init(chain: .bnb, chainID: 56, ankrPath: "bsc", artworkDirectory: "smartchain"),
        .init(chain: .fantom, chainID: 250, ankrPath: "fantom", artworkDirectory: "fantom"),
        .init(chain: .flare, chainID: 14, ankrPath: "flare", artworkDirectory: "flare"),
        .init(chain: .somnia, chainID: 5031, ankrPath: "somnia_mainnet", artworkDirectory: "somnia"),
        .init(chain: .story, chainID: 1514, ankrPath: "story_mainnet", artworkDirectory: "story"),
        .init(chain: .gnosis, chainID: 100, ankrPath: "gnosis", artworkDirectory: "xdai"),
        .init(chain: .linea, chainID: 59144, ankrPath: "linea", artworkDirectory: "linea"),
        .init(chain: .optimism, chainID: 10, ankrPath: "optimism", artworkDirectory: "optimism"),
        .init(chain: .polygon, chainID: 137, ankrPath: "polygon", artworkDirectory: "polygon"),
        .init(chain: .chiliz, chainID: 88888, ankrPath: "chiliz", artworkDirectory: "chiliz"),
        .init(chain: .iotex, chainID: 4689, ankrPath: "iotex", artworkDirectory: "iotex"),
        .init(chain: .zerog, chainID: 16661, ankrPath: "0g_mainnet_evm", artworkDirectory: "zerog"),
        .init(chain: .sei, chainID: 1329, ankrPath: "sei_evm", artworkDirectory: "sei"),
        .init(chain: .filecoin, chainID: 314, ankrPath: "filecoin", artworkDirectory: "filecoin"),
        .init(chain: .celo, chainID: 42220, ankrPath: "celo", artworkDirectory: "celo"),
        .init(chain: .monad, chainID: 143, ankrPath: "monad_mainnet", artworkDirectory: "monad"),
        .init(chain: .unichain, chainID: 130, ankrPath: "unichain_mainnet", artworkDirectory: "unichain"),
        .init(chain: .hyperevm, chainID: 999, ankrPath: "hyperevm", artworkDirectory: "hyperevm"),
        .init(chain: .robinhood, chainID: 4663, ankrPath: "robinhood_mainnet", artworkDirectory: "robinhood"),
        .init(chain: .scroll, chainID: 534352, ankrPath: "scroll", artworkDirectory: "scroll"),
        .init(chain: .taiko, chainID: 167000, ankrPath: "taiko", artworkDirectory: "taiko"),
        .init(chain: .telos, chainID: 40, ankrPath: "telos", artworkDirectory: "telos"),
        .init(chain: .xlayer, chainID: 196, ankrPath: "xlayer", artworkDirectory: "xlayer"),
        .init(chain: .tron, chainID: 728126428, ankrPath: "tron_jsonrpc", artworkDirectory: "tron"),
        .init(chain: .solana, chainID: nil, ankrPath: "solana", artworkDirectory: "solana"),
        .init(chain: .aptos, chainID: nil, ankrPath: "aptos", artworkDirectory: "aptos"),
        .init(chain: .near, chainID: nil, ankrPath: "near", artworkDirectory: "near"),
        .init(chain: .polkadot, chainID: nil, ankrPath: "polkadot", artworkDirectory: "polkadot"),
        .init(chain: .stellar, chainID: nil, ankrPath: "stellar", artworkDirectory: "stellar"),
        .init(chain: .sui, chainID: nil, ankrPath: "sui", artworkDirectory: "sui"),
        .init(chain: .ton, chainID: nil, ankrPath: "ton", artworkDirectory: "ton"),
        .init(chain: .xrpl, chainID: nil, ankrPath: "xrp", artworkDirectory: "xrp"),
        .init(chain: .thorchain, chainID: nil, ankrPath: "thorchain", artworkDirectory: "thorchain")
    ]

    static func find(_ chain: OathImportChain) -> Self? { all.first { $0.chain == chain } }
}

struct OathTokenDefinition: Identifiable, Hashable, Sendable {
    let network: OathTokenNetwork
    let address: String
    let name: String
    let symbol: String
    let decimals: Int?
    let standard: String
    let logoURL: URL?
    var isNativeRepresentation: Bool {
        TokenDiscoveryNetworks.isNativeRepresentation(address, network: network.id)
    }
    var reference: String { network.chain.isEVM ? address.lowercased() : address }
    var id: String { network.id + ":" + (isNativeRepresentation ? "native" : reference) }

    /// Localize the generic description while preserving protocol standard names
    /// and the original discovery metadata used outside presentation.
    func standardText(strings: OathLocalizer) -> String {
        if network.chain == .thorchain && standard == "Bank token" {
            return strings.text(.tokenBankStandard)
        }
        return strings.invariant(standard)
    }

    static func discovery(_ entry: TokenDiscoveryEntry) -> Self? {
        guard let chain = OathImportChain(rawValue: entry.network), let network = OathTokenNetwork.find(chain) else { return nil }
        let standard: String
        switch chain {
        case .solana: standard = "SPL"
        case .tron: standard = "TRC20"
        case .aptos, .sui: standard = "Move"
        case .near: standard = "NEP-141"
        case .polkadot: standard = "Asset Hub"
        case .stellar: standard = "Stellar"
        case .xrpl: standard = "XRP Ledger"
        case .ton: standard = "Jetton"
        case .thorchain: standard = "Bank token"
        default: standard = "ERC20"
        }
        let artworkReference = chain.isEVM ? OathTokenAddress.checksum(entry.reference) : entry.reference
        let fallback = URL(string: "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/\(network.artworkDirectory)/assets/")?
            .appendingPathComponent(artworkReference).appendingPathComponent("logo.png")
        return .init(network: network, address: entry.reference, name: entry.name, symbol: entry.symbol,
            decimals: entry.decimals, standard: standard, logoURL: entry.logo.flatMap(URL.init(string:)) ?? fallback)
    }
}

extension OathTokenDefinition {
    var artworkIdentity: TokenArtworkIdentity? {
        guard !isNativeRepresentation else { return nil }
        return .init(networkID: network.id, reference: reference, decimals: decimals)
    }
}

/// This value never enters SQL, logs, analytics, or source-controlled settings.
struct OathTokenRPCConfiguration: Sendable {
    private let ankrKey: String
    private let alchemyKey: String?
    private let alchemyUTXONetworks: Set<UTXONetwork>
    private let aptosIndexerKey: String?
    private let envioKey: String?
    var hasArcIndex: Bool { envioKey?.isEmpty == false || alchemyKey?.isEmpty == false }
    private let blockscoutKey: String?
    var hasRobinhoodIndex: Bool { blockscoutKey?.isEmpty == false || alchemyKey?.isEmpty == false }
    init(ankrKey: String, aptosIndexerKey: String? = nil, blockscoutKey: String? = nil, envioKey: String? = nil,
         alchemyKey: String? = nil, alchemyUTXONetworks: Set<UTXONetwork> = []) {
        self.alchemyKey = alchemyKey
        self.alchemyUTXONetworks = alchemyUTXONetworks
        self.envioKey = envioKey
        self.ankrKey = ankrKey
        self.blockscoutKey = blockscoutKey
        self.aptosIndexerKey = aptosIndexerKey.flatMap { $0.isEmpty ? nil : $0 }
    }
    /// Reuses the app's chain clients when optional directory metadata is absent
    /// or rate-limited. These reads never sign, submit, or change an account.
    func discoveryDecimals(network: OathTokenNetwork, reference: String, owner: String?) async throws -> Int {
        switch network.chain {
        case .near:
            let client = try NearClient(apiKey: ankrKey)
            return try await client.token(reference, block: client.finalBlock()).decimals
        case .sui:
            let client = try SuiClient(apiKey: ankrKey)
            guard let token = try await client.metadata(references: [reference])[reference] else { throw OathTokenLookupError.metadataUnavailable }
            return token.decimals
        case .aptos:
            return try await AptosSendClient(apiKey: ankrKey).tokenDecimals(reference: reference)
        case .ton:
            return try await TonClient(apiKey: ankrKey).tokenDecimals(reference: reference)
        case .polkadot:
            return try await PolkadotClient().currentMetadata(reference: reference).decimals
        case .stellar:
            guard let owner else { throw OathTokenLookupError.metadataUnavailable }
            return try await StellarClient(apiKey: ankrKey).metadata(reference: reference, owner: owner).decimals
        case .xrpl:
            let client = try XrplClient(apiKey: ankrKey)
            return try await client.token(reference, ledger: client.validatedLedger()).decimals
        case .thorchain:
            guard ThorchainIdentity.hasProtocolDecimals(reference) else { throw OathTokenLookupError.metadataUnavailable }
            return 8
        default: throw OathTokenLookupError.wrongNetwork
        }
    }
    func makeArcSynchronizer(database: OathDatabase) throws -> ArcSynchronizer {
        try ArcSynchronizer(database: database, indexKey: envioKey, alchemyAPIKey: alchemyKey)
    }
    func makeIndexedEVMSynchronizer(database: OathDatabase, chain: IndexedEVMChain) throws -> IndexedEVMSynchronizer {
        try IndexedEVMSynchronizer(database: database, chain: chain, apiKey: ankrKey, alchemyAPIKey: alchemyKey)
    }
    func makeHyperEVMSynchronizer(database: OathDatabase) throws -> HyperEVMSynchronizer {
        try HyperEVMSynchronizer(database: database, apiKey: ankrKey, alchemyAPIKey: alchemyKey)
    }
    func makeRobinhoodSynchronizer(database: OathDatabase) throws -> RobinhoodSynchronizer {
        try RobinhoodSynchronizer(database: database, apiKey: ankrKey, blockscoutKey: blockscoutKey, alchemyAPIKey: alchemyKey)
    }
    func makeAccountSynchronizer(database: OathDatabase) throws -> AnkrSynchronizer {
        try AnkrSynchronizer(database: database, apiKey: ankrKey)
    }
    func makePermissionDiscovery() throws -> PermissionDiscovery { try PermissionDiscovery(apiKey:ankrKey) }
    func makeReceiveActivationCheck() throws -> ReceiveActivationCheck {
        try ReceiveActivationCheck(endpoints: PublicCheckProviders.endpoints(ankrAPIKey: ankrKey))
    }
    func makePublicMultisigCheck() -> PublicMultisigCheck {
        var providers: [String: URL] = [:]
        if !ankrKey.isEmpty, ankrKey.count <= 256,
           ankrKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) {
            providers["xrpl"] = URL(string: "https://rpc.ankr.com/xrp_mainnet")!.appendingPathComponent(ankrKey)
        }
        return PublicMultisigCheck(endpoints: providers)
    }
    func makeStablecoinRestrictionCheck() -> StablecoinRestrictionCheck {
        var providers: [String: URL] = [:]
        for network in OathTokenNetwork.all where network.chain.isEVM {
            providers[network.id] = endpoints(for: network).first
        }
        // Public mainnet endpoints; every adapter also verifies chain identity.
        providers["tron"] = TronSendNetwork.mainnet.endpoint
        providers["solana"] = OathTokenNetwork.find(.solana).flatMap { endpoints(for: $0).first }
        providers["near"] = URL(string: "https://rpc.mainnet.near.org")
        providers["aptos"] = URL(string: "https://api.mainnet.aptoslabs.com/v1")
        providers["stellar"] = URL(string: "https://horizon.stellar.org")
        providers["xrpl"] = URL(string: "https://s1.ripple.com:51234")
        providers["sui"] = URL(string: "https://graphql.mainnet.sui.io/graphql")
        if !ankrKey.isEmpty, ankrKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) {
            providers["ton"] = URL(string: "https://rpc.ankr.com/ton_api_v2")!.appendingPathComponent(ankrKey)
            // Share the authenticated node used by TronClient. Public TronGrid
            // throttles parallel import/policy reads at only a few requests/sec.
            providers["tron"] = URL(string: "https://rpc.ankr.com/premium-http/tron")!.appendingPathComponent(ankrKey)
        }
        return StablecoinRestrictionCheck(endpoints: providers)
    }

    func makeUTXOFeeProvider() -> UTXOFeeProvider {
        UTXOFeeProvider(ankrAPIKey: ankrKey, alchemyAPIKey: alchemyKey, alchemyNetworks: alchemyUTXONetworks)
    }

    func makeUTXOBroadcastProvider() -> UTXOBroadcastProvider {
        UTXOBroadcastProvider(alchemyAPIKey: alchemyKey, alchemyNetworks: alchemyUTXONetworks)
    }

    func makeSolanaSynchronizer(database: OathDatabase) throws -> SolanaSynchronizer {
        try SolanaSynchronizer(database: database, apiKey: ankrKey)
    }

    func makeTronSynchronizer(database: OathDatabase) throws -> TronSynchronizer {
        try TronSynchronizer(database: database, apiKey: ankrKey)
    }
    func makeTonSynchronizer(database: OathDatabase) throws -> TonSynchronizer {
        try TonSynchronizer(database: database, apiKey: ankrKey)
    }
    func makeSolanaSendClient(network: SolanaSendNetwork = .mainnet) throws -> SolanaSendClient {
        try SolanaSendClient(network: network, apiKey: network == .testnet ? nil : ankrKey)
    }
    func makeEVMSendClient(network:EVMSendNetwork) throws -> EVMSendClient {
        guard !network.isTestnet,let chain=OathImportChain(rawValue:network.rawValue),
              let entry=OathTokenNetwork.find(chain),entry.chainID==network.chainID else { throw EVMSendError.wrongNetwork }
        var providers=endpoints(for:entry)
        // ANKR currently omits Linea's calldata-aware fee method. The official
        // mainnet node is a chain-checked fallback, not a guessed fee schedule.
        if network == .linea { providers.append(URL(string:"https://rpc.linea.build")!) }
        if network == .bnb { providers.append(URL(string:"https://bsc-dataseed.bnbchain.org")!) }
        // Preserve ANKR as primary; use Celo's independent mainnet node for
        // transport outages. EVMSendClient checks the selected chain on every reply.
        if network == .chiliz { providers.append(URL(string:"https://chiliz-rpc.publicnode.com")!) }
        if network == .celo { providers.append(URL(string:"https://forno.celo.org")!) }
        return try EVMSendClient(network:network,endpoints:providers)
    }
    func makeArcSendClient() -> ArcSendClient { ArcSendClient(network:.mainnet) }
    func makeAptosSendClient() throws -> AptosSendClient { try AptosSendClient(network:.mainnet,apiKey:ankrKey) }
    func makeNearSendClient() throws -> NearSendClient { try NearSendClient(network:.mainnet,apiKey:ankrKey) }
    func makeTronSendClient() throws -> TronSendClient { try TronSendClient(network:.mainnet,apiKey:ankrKey) }
    func makeStellarSendClient() throws -> StellarSendClient { try StellarSendClient(network:.mainnet,apiKey:ankrKey) }
    func makeXrplSendClient() throws -> XrplSendClient { try XrplSendClient(network:.mainnet,apiKey:ankrKey) }

    func makeSuiSendClient() throws -> SuiSendClient {
        try SuiSendClient(network:.mainnet,apiKey:ankrKey)
    }
    func makeTonSendClient() throws -> TonSendClient { try TonSendClient(network:.mainnet,apiKey:ankrKey) }
    func makeSuiSynchronizer(database: OathDatabase) throws -> SuiSynchronizer {
        try SuiSynchronizer(database: database, apiKey: ankrKey)
    }
    func makeXrplSynchronizer(database: OathDatabase) throws -> XrplSynchronizer {
        try XrplSynchronizer(database: database, apiKey: ankrKey)
    }
    func makePolkadotSynchronizer(database: OathDatabase) throws -> PolkadotSynchronizer {
        try PolkadotSynchronizer(database: database, client: PolkadotClient(ankrAPIKey: ankrKey))
    }
    func makeStellarSynchronizer(database: OathDatabase) throws -> StellarSynchronizer {
        try StellarSynchronizer(database: database, apiKey: ankrKey)
    }
    func makeNearSynchronizer(database: OathDatabase) throws -> NearSynchronizer {
        try NearSynchronizer(database: database, apiKey: ankrKey)
    }
    func makeAptosSynchronizer(database: OathDatabase) throws -> AptosSynchronizer {
        try AptosSynchronizer(database: database, apiKey: ankrKey, indexerKey: aptosIndexerKey)
    }

    static func bundled(in bundle: Bundle = .main) -> Self {
        let url = bundle.url(forResource: "TokenRPC", withExtension: "plist")
        let data = url.flatMap { url in OathDiagnostics.attempt("read_provider_configuration") { try Data(contentsOf: url) } }
        let values = data.flatMap { data in OathDiagnostics.attempt("decode_provider_configuration") { try PropertyListDecoder().decode([String: String].self, from: data) } }
        // Comma-separated network IDs, set only after enabling those exact
        // UTXO capabilities in the provider account. Other Alchemy uses are separate.
        let utxoNetworks = Set((values?["AlchemyUTXONetworks"] ?? "").split(separator: ",").compactMap {
            UTXONetwork(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        return Self(ankrKey: values?["AnkrAPIKey"] ?? "", aptosIndexerKey: values?["AptosIndexerAPIKey"], blockscoutKey: values?["BlockscoutAPIKey"], envioKey: values?["EnvioAPIKey"], alchemyKey: values?["AlchemyAPIKey"], alchemyUTXONetworks: utxoNetworks)
    }

    func endpoints(for network: OathTokenNetwork) -> [URL] {
        // Arc's official mainnet RPC is separate from its testnet. Never fall
        // back to a testnet merely because a mainnet provider rejects access.
        if network.chain == .arc {
            return [URL(string: "https://rpc.blockdaemon.mainnet.arc.io")!,
                    URL(string: "https://rpc.drpc.mainnet.arc.io")!,
                    URL(string: "https://rpc.mainnet.arc.io")!]
        }
        let fallback: [URL]
        switch network.chain {
        case .chiliz: fallback = [URL(string: "https://chiliz-rpc.publicnode.com")!]
        case .iotex: fallback = [URL(string: "https://babel-api.mainnet.iotex.io")!]
        case .zerog: fallback = [URL(string: "https://evmrpc.0g.ai")!]
        case .filecoin: fallback = [URL(string: "https://api.node.glif.io/rpc/v1")!]
        case .sei: fallback = [URL(string: "https://evm-rpc.sei-apis.com")!]
        default: fallback = []
        }
        guard !ankrKey.isEmpty, ankrKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return fallback }
        return [URL(string: "https://rpc.ankr.com")!.appendingPathComponent(network.ankrPath).appendingPathComponent(ankrKey)] + fallback
    }
}

enum OathTokenLookupError: Error, Equatable, Sendable {
    case invalidAddress, notToken, metadataUnavailable, unavailable, wrongNetwork, malformedResponse, configurationMissing
}
