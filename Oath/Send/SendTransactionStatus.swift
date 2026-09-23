import Foundation

enum SendTransactionNetworkStatus: String, Equatable, Sendable {
    case pending
    case confirmed
    case failed
    /// Successful exact lookup found no transaction; never an execution failure.
    case notFound
    /// A conflicting transaction is in the mempool; keep checking both outcomes.
    case replaced
    /// A conflicting transaction has confirmed, consuming the same input/nonce.
    case canceled

    var isTerminal: Bool {
        self == .confirmed || self == .failed || self == .canceled
    }

    var databaseStatus: String { self == .canceled ? "canceled" : (isTerminal ? rawValue : "pending") }
    var localizedKey: String {
        switch self {
        case .pending: "wallet.activity.status.pending"
        case .confirmed: "wallet.activity.status.confirmed"
        case .failed: "wallet.activity.status.failed"
        case .notFound: "wallet.activity.status.not_found"
        case .replaced, .canceled: "wallet.activity.status.replaced"
        }
    }
}

enum SendTransactionStatusRoute: Equatable, Sendable {
    case evm
    case bitcoinFamily(BitcoinFamilyChain)
    case solana
    case tron
    case ton
    case sui
    case xrp
    case near
    case aptos
    case stellar

    static func resolve(networkID: String) throws -> Self {
        if let chain = BitcoinFamilyChain(rawValue: networkID) {
            return .bitcoinFamily(chain)
        }
        switch networkID {
        case SolanaConstants.networkID:
            return .solana
        case TronConstants.networkID:
            return .tron
        case TONConstants.networkID:
            return .ton
        case SuiConstants.networkID:
            return .sui
        case XRPConstants.networkID:
            return .xrp
        case NEARConstants.networkID:
            return .near
        case AptosConstants.networkID:
            return .aptos
        case StellarConstants.networkID:
            return .stellar
        default:
            guard let network = ReceiveNetworkCatalog.network(
                for: networkID
            ), network.chainID > 0 else {
                throw SendTransactionStatusProviderError
                    .unsupportedNetwork(networkID)
            }
            return .evm
        }
    }
}

enum SendTransactionStatusProviderError: Error, Equatable, Sendable {
    case unsupportedNetwork(String)
    case invalidTransactionHash(networkID: String)
    case invalidAccount(networkID: String)
    case invalidResponse(networkID: String, code: String)
    case missingConfiguration(networkID: String)

    var diagnosticDescription: String {
        switch self {
        case let .unsupportedNetwork(networkID):
            "status_unsupported_network_\(networkID)"
        case let .invalidTransactionHash(networkID):
            "status_invalid_hash_\(networkID)"
        case let .invalidAccount(networkID):
            "status_invalid_account_\(networkID)"
        case let .invalidResponse(networkID, code):
            "status_invalid_response_\(networkID)_\(code)"
        case let .missingConfiguration(networkID):
            "status_configuration_missing_\(networkID)"
        }
    }
}

enum SendTransactionStatusPollingPolicy {
    static let interval: Duration = .seconds(4)

    static func interval(networkID: String, failures: Int = 0) -> Duration {
        // Small exact reads every two seconds on faster chains. Public TON
        // and TRON services and block-based UTXO chains retain four seconds.
        let seconds = BitcoinFamilyChain(rawValue: networkID) != nil
            || networkID == TONConstants.networkID || networkID == TronConstants.networkID ? 4 : 2
        return .seconds(min(30, seconds * (1 << min(max(failures, 0), 4))))
    }
}

actor SendTransactionStatusService {
    private let bitcoinFamily = BitcoinFamilyTransactionStatusProvider()
    private let solana = SolanaTransactionStatusProvider(transport: SolanaRPCTransport(endpoints: [
        URL(string: "https://solana-rpc.publicnode.com")!, URL(string: "https://api.mainnet-beta.solana.com")!
    ]))
    private let tron = TronTransactionStatusProvider(transport: TronAPITransport(
        restBaseURLs: [URL(string: "https://api.trongrid.io")!]))
    private let ton = TONTransactionStatusProvider()
    private let stellar = StellarAPIClient(transport: StellarHorizonTransport(
        baseURL: StellarConstants.horizonFallbackBaseURL, readFallbackBaseURLs: []))
    private var evmClients: [String: SendEVMRPCClient] = [:]
    private var xrpProvider: XRPAPIClient?
    private var nearProvider: NEARTransactionStatusProvider?

    func status(
        for receipt: SendTransactionReceipt
    ) async throws -> SendTransactionNetworkStatus {
        switch try SendTransactionStatusRoute.resolve(
            networkID: receipt.networkID
        ) {
        case .evm:
            let client: SendEVMRPCClient
            if let cached = evmClients[receipt.networkID] {
                client = cached
            } else {
                client = try SendEVMRPCClient(
                    networkID: receipt.networkID
                )
                evmClients[receipt.networkID] = client
            }
            return try await client.transactionStatus(
                hash: receipt.transactionHash
            )
        case let .bitcoinFamily(chain):
            return try await bitcoinFamily.status(
                chain: chain,
                transactionHash: receipt.transactionHash,
                accountAddress: receipt.fromAddress
            )
        case .solana:
            return try await solana.status(
                signature: receipt.transactionHash
            )
        case .tron:
            return try await tron.status(
                transactionHash: receipt.transactionHash
            )
        case .ton:
            return try await ton.status(
                externalMessageHash: receipt.transactionHash
            )
        case .sui:
            return try await SuiAPIClient.shared.transactionStatus(
                digest: receipt.transactionHash
            )
        case .xrp:
            let client: XRPAPIClient
            if let xrpProvider { client = xrpProvider }
            else {
                guard let endpoint = XRPConstants.publicJSONRPCReadURLs.first else {
                    throw SendTransactionStatusProviderError.missingConfiguration(networkID: XRPConstants.networkID)
                }
                client = XRPAPIClient(transport: try XRPJSONRPCTransport(endpoint: endpoint,
                    fallbackEndpoints: Array(XRPConstants.publicJSONRPCReadURLs.dropFirst())))
                xrpProvider = client
            }
            return try await client.transactionStatus(hash: receipt.transactionHash)
        case .near:
            let provider: NEARTransactionStatusProvider
            if let nearProvider {
                provider = nearProvider
            } else {
                provider = try NEARTransactionStatusProvider(publicEndpoints: NEARConstants.publicJSONRPCEndpoints)
                nearProvider = provider
            }
            return try await provider.status(
                transactionHash: receipt.transactionHash,
                senderAccountID: receipt.fromAddress
            )
        case .aptos:
            return try await AptosAPIClient.shared.transactionStatus(
                hash: receipt.transactionHash
            )
        case .stellar:
            return try await stellar.transactionStatus(
                hash: receipt.transactionHash
            )
        }
    }

    nonisolated static func diagnosticCode(_ error: Error) -> String {
        let value: String
        switch error {
        case let error as SendTransactionStatusProviderError:
            value = error.diagnosticDescription
        case let error as SendTransactionSubmissionError:
            value = error.diagnosticCode
        case let error as BitcoinFamilyElectrumError:
            value = "bitcoin_electrum_\(error.diagnosticDescription)"
        case let error as SolanaProviderError:
            value = error.diagnosticDescription
        case let error as AnkrAPIError:
            value = "provider_\(error.diagnosticDescription)"
        case let error as TONProviderError:
            value = error.diagnosticDescription
        case let error as SuiProviderError:
            value = error.diagnosticDescription
        case let error as XRPProviderError:
            value = error.diagnosticDescription
        case let error as NEARProviderError:
            value = error.diagnosticDescription
        case let error as AptosProviderError:
            value = error.diagnosticDescription
        case let error as StellarProviderError:
            value = error.diagnosticDescription
        case let error as URLError:
            value = "url_error_\(error.errorCode)"
        default:
            value = SendTransactionSubmissionError
                .sanitizedErrorType(error)
        }
        return SendTransactionSubmissionError.sanitizedMessage(
            String(value.prefix(300))
        )
    }
}
