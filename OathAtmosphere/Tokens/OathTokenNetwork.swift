import OathAnkr
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
        .init(chain: .monad, chainID: 143, ankrPath: "monad_mainnet", artworkDirectory: "monad"),
        .init(chain: .unichain, chainID: 130, ankrPath: "unichain_mainnet", artworkDirectory: "unichain"),
        .init(chain: .hyperevm, chainID: 999, ankrPath: "hyperevm", artworkDirectory: "hyperevm"),
        .init(chain: .robinhood, chainID: 4663, ankrPath: "robinhood_mainnet", artworkDirectory: "robinhood"),
        .init(chain: .scroll, chainID: 534352, ankrPath: "scroll", artworkDirectory: "scroll"),
        .init(chain: .taiko, chainID: 167000, ankrPath: "taiko", artworkDirectory: "taiko"),
        .init(chain: .telos, chainID: 40, ankrPath: "telos", artworkDirectory: "telos"),
        .init(chain: .xlayer, chainID: 196, ankrPath: "xlayer", artworkDirectory: "xlayer"),
        .init(chain: .tron, chainID: 728126428, ankrPath: "tron_jsonrpc", artworkDirectory: "tron"),
        .init(chain: .solana, chainID: nil, ankrPath: "solana", artworkDirectory: "solana")
    ]

    static func find(_ chain: OathImportChain) -> Self? { all.first { $0.chain == chain } }
}

struct OathTokenDefinition: Identifiable, Hashable, Sendable {
    let network: OathTokenNetwork
    let address: String
    let name: String
    let symbol: String
    let decimals: Int
    let standard: String
    let logoURL: URL?
    var isNativeRepresentation: Bool {
        network.chain == .arc && address.lowercased() == "0x3600000000000000000000000000000000000000"
    }
    var reference: String { network.chain.isEVM ? address.lowercased() : address }
    var id: String { network.id + ":" + (isNativeRepresentation ? "native" : reference) }
}

/// This value never enters SQL, logs, analytics, or source-controlled settings.
struct OathTokenRPCConfiguration: Sendable {
    private let ankrKey: String
    private let alchemyKey: String?
    private let aptosIndexerKey: String?
    private let envioKey: String?
    var hasArcIndex: Bool { envioKey?.isEmpty == false }
    private let blockscoutKey: String?
    var hasRobinhoodIndex: Bool { blockscoutKey?.isEmpty == false }
    init(ankrKey: String, aptosIndexerKey: String? = nil, blockscoutKey: String? = nil, envioKey: String? = nil,
         alchemyKey: String? = nil) {
        self.alchemyKey = alchemyKey
        self.envioKey = envioKey
        self.ankrKey = ankrKey
        self.blockscoutKey = blockscoutKey
        self.aptosIndexerKey = aptosIndexerKey.flatMap { $0.isEmpty ? nil : $0 }
    }
    func makeArcSynchronizer(database: OathDatabase) throws -> ArcSynchronizer {
        try ArcSynchronizer(database: database, indexKey: envioKey)
    }
    func makeIndexedEVMSynchronizer(database: OathDatabase, chain: IndexedEVMChain) throws -> IndexedEVMSynchronizer {
        try IndexedEVMSynchronizer(database: database, chain: chain, apiKey: ankrKey, alchemyAPIKey: alchemyKey)
    }
    func makeHyperEVMSynchronizer(database: OathDatabase) throws -> HyperEVMSynchronizer {
        try HyperEVMSynchronizer(database: database, apiKey: ankrKey)
    }
    func makeRobinhoodSynchronizer(database: OathDatabase) throws -> RobinhoodSynchronizer {
        try RobinhoodSynchronizer(database: database, apiKey: ankrKey, blockscoutKey: blockscoutKey)
    }
    func makeAccountSynchronizer(database: OathDatabase) throws -> AnkrSynchronizer {
        try AnkrSynchronizer(database: database, apiKey: ankrKey)
    }
    func makePermissionDiscovery() throws -> PermissionDiscovery { try PermissionDiscovery(apiKey:ankrKey) }

    func makeUTXOFeeProvider() -> UTXOFeeProvider {
        UTXOFeeProvider(ankrAPIKey: ankrKey, alchemyAPIKey: alchemyKey)
    }

    func makeUTXOBroadcastProvider() -> UTXOBroadcastProvider {
        UTXOBroadcastProvider(alchemyAPIKey: alchemyKey)
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
    func makeSolanaSendClient() throws -> SolanaSendClient { try SolanaSendClient(network:.mainnet,apiKey:ankrKey) }
    func makeEVMSendClient(network:EVMSendNetwork) throws -> EVMSendClient {
        guard !network.isTestnet,let chain=OathImportChain(rawValue:network.rawValue),
              let entry=OathTokenNetwork.find(chain),entry.chainID==network.chainID else { throw EVMSendError.wrongNetwork }
        var providers=endpoints(for:entry)
        // ANKR currently omits Linea's calldata-aware fee method. The official
        // mainnet node is a chain-checked fallback, not a guessed fee schedule.
        if network == .linea { providers.append(URL(string:"https://rpc.linea.build")!) }
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
        return Self(ankrKey: values?["AnkrAPIKey"] ?? "", aptosIndexerKey: values?["AptosIndexerAPIKey"], blockscoutKey: values?["BlockscoutAPIKey"], envioKey: values?["EnvioAPIKey"], alchemyKey: values?["AlchemyAPIKey"])
    }

    func endpoints(for network: OathTokenNetwork) -> [URL] {
        // Arc's official mainnet RPC is separate from its testnet. Never fall
        // back to a testnet merely because a mainnet provider rejects access.
        if network.chain == .arc {
            return [URL(string: "https://rpc.blockdaemon.mainnet.arc.io")!,
                    URL(string: "https://rpc.drpc.mainnet.arc.io")!,
                    URL(string: "https://rpc.mainnet.arc.io")!]
        }
        guard !ankrKey.isEmpty, ankrKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return [] }
        return [URL(string: "https://rpc.ankr.com")!.appendingPathComponent(network.ankrPath).appendingPathComponent(ankrKey)]
    }
}

enum OathTokenLookupError: Error, Equatable, Sendable {
    case invalidAddress, notToken, metadataUnavailable, unavailable, wrongNetwork, malformedResponse, configurationMissing
}
