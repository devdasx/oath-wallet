import Foundation

enum WalletSyncSource: String, Equatable, Hashable, Sendable {
    case aptos
    case stellar
    case xrp
    case evm
    case bitcoinFamily = "bitcoin_family"
    case tron
    case solana
    case ton
    case sui
    case near

    var localizedName: String {
        switch self {
        case .aptos:
            WalletLocalization.string("network.aptos.name")
        case .stellar:
            WalletLocalization.string("network.stellar.name")
        case .xrp:
            WalletLocalization.string("network.xrp.name")
        case .evm:
            WalletLocalization.string(
                "settings.wallets.private_key.export.chain.evm"
            )
        case .bitcoinFamily:
            [
                "network.bitcoin.name",
                "network.bitcoin_cash.name",
                "network.litecoin.name",
                "network.dogecoin.name"
            ]
            .map(WalletLocalization.string)
            .joined(separator: ", ")
        case .tron:
            WalletLocalization.string("network.tron.name")
        case .solana:
            WalletLocalization.string("network.solana.name")
        case .ton:
            WalletLocalization.string("network.ton.name")
        case .sui:
            WalletLocalization.string("network.sui.name")
        case .near:
            WalletLocalization.string("network.near.name")
        }
    }
}

extension WalletCapabilities {
    var walletSyncSources: Set<WalletSyncSource> {
        switch scope {
        case .fullWallet:
            [
                .evm, .bitcoinFamily, .tron, .solana, .ton, .sui,
                .xrp, .near, .aptos, .stellar
            ]
        case .privateKey(.evm):
            [.evm]
        case .privateKey(.bitcoin),
             .privateKey(.bitcoinCash),
             .privateKey(.litecoin),
             .privateKey(.dogecoin):
            [.bitcoinFamily]
        case .privateKey(.tron):
            [.tron]
        case .privateKey(.solana):
            [.solana]
        case .privateKey(.ton):
            [.ton]
        case .privateKey(.sui):
            [.sui]
        case .privateKey(.xrp):
            [.xrp]
        case .privateKey(.near):
            [.near]
        case .privateKey(.aptos):
            [.aptos]
        case .privateKey(.stellar):
            [.stellar]
        }
    }
}

enum WalletSyncFailureStage: String, Equatable, Sendable {
    case configuration
    case accountPreparation = "account_preparation"
    case trackedAssetRead = "tracked_asset_read"
    case providerRead = "provider_read"
    case persistence
    case historyEnrichment = "history_enrichment"
}

enum WalletSyncFailureKind: Equatable, Sendable {
    case configurationMissing
    case configurationInvalid
    case authentication
    case providerUnavailable
    case providerRejected
    case invalidResponse
    case persistence
    case unexpected
}

struct WalletChainSyncFailure: Equatable, Sendable {
    let source: WalletSyncSource
    let networkID: String?
    let stage: WalletSyncFailureStage
    let kind: WalletSyncFailureKind
    let publicCode: String

    init(
        source: WalletSyncSource,
        stage: WalletSyncFailureStage,
        error: Error,
        networkID: String? = nil
    ) {
        let descriptor = WalletSyncFailureDescriptor(
            error: error,
            stage: stage
        )
        self.init(
            source: source,
            stage: stage,
            kind: descriptor.kind,
            publicCode: descriptor.publicCode,
            networkID: networkID
        )
    }

    init(
        source: WalletSyncSource,
        stage: WalletSyncFailureStage,
        kind: WalletSyncFailureKind,
        publicCode: String,
        networkID: String? = nil
    ) {
        self.source = source
        self.networkID = networkID
        self.stage = stage
        self.kind = kind
        self.publicCode = publicCode
    }

    var localizedSourceName: String {
        switch networkID {
        case BitcoinFamilyChain.bitcoin.networkID:
            WalletLocalization.string("network.bitcoin.name")
        case BitcoinFamilyChain.bitcoinCash.networkID:
            WalletLocalization.string("network.bitcoin_cash.name")
        case BitcoinFamilyChain.litecoin.networkID:
            WalletLocalization.string("network.litecoin.name")
        case BitcoinFamilyChain.dogecoin.networkID:
            WalletLocalization.string("network.dogecoin.name")
        default:
            source.localizedName
        }
    }
}

struct WalletChainSyncOutcome: Equatable, Sendable {
    let source: WalletSyncSource
    let didPersistData: Bool
    let failures: [WalletChainSyncFailure]

    static func success(
        _ source: WalletSyncSource,
        didPersistData: Bool = true
    ) -> WalletChainSyncOutcome {
        WalletChainSyncOutcome(
            source: source,
            didPersistData: didPersistData,
            failures: []
        )
    }

    static func failure(
        _ source: WalletSyncSource,
        stage: WalletSyncFailureStage,
        error: Error,
        networkID: String? = nil
    ) -> WalletChainSyncOutcome {
        WalletChainSyncOutcome(
            source: source,
            didPersistData: false,
            failures: [
                WalletChainSyncFailure(
                    source: source,
                    stage: stage,
                    error: error,
                    networkID: networkID
                )
            ]
        )
    }

    static func cancelled(
        _ source: WalletSyncSource
    ) -> WalletChainSyncOutcome {
        .success(source, didPersistData: false)
    }

    static func persistedEVM(
        providerFailures: [WalletChainSyncFailure],
        failedTrackedTokenCount: Int
    ) -> WalletChainSyncOutcome {
        var failures = providerFailures
        if failedTrackedTokenCount > 0 {
            failures.append(
                WalletChainSyncFailure(
                    source: .evm,
                    stage: .trackedAssetRead,
                    kind: .providerUnavailable,
                    publicCode:
                        "custom_token_queries_failed_\(failedTrackedTokenCount)"
                )
            )
        }
        return WalletChainSyncOutcome(
            source: .evm,
            didPersistData: true,
            failures: failures
        )
    }

    var diagnosticOutcome: String {
        if failures.isEmpty {
            return didPersistData ? "success" : "no_data"
        }
        return didPersistData ? "partial" : "failure"
    }
}

struct WalletSynchronizationReport: Equatable, Sendable {
    let outcomes: [WalletChainSyncOutcome]

    var failures: [WalletChainSyncFailure] {
        outcomes.flatMap(\.failures).sorted {
            if $0.source.rawValue != $1.source.rawValue {
                return $0.source.rawValue < $1.source.rawValue
            }
            if $0.stage.rawValue != $1.stage.rawValue {
                return $0.stage.rawValue < $1.stage.rawValue
            }
            return $0.publicCode < $1.publicCode
        }
    }

    var didPersistData: Bool {
        outcomes.contains(where: \.didPersistData)
    }

    var hasFailures: Bool {
        !failures.isEmpty
    }
}

struct WalletSynchronizationReportError: Error, Sendable {
    let report: WalletSynchronizationReport
}

private struct WalletSyncFailureDescriptor {
    let kind: WalletSyncFailureKind
    let publicCode: String

    init(
        error: Error,
        stage: WalletSyncFailureStage
    ) {
        if let error = error as? AssetPriceError {
            switch error {
            case .unsupportedAsset:
                kind = .providerRejected
                publicCode = "price_unsupported_asset"
            case .unavailable:
                kind = .providerUnavailable
                publicCode = "price_unavailable"
            case .invalidResponse:
                kind = .invalidResponse
                publicCode = "price_invalid_response"
            case let .providerFailure(provider, reason, statusCode):
                let providerID = String(provider.prefix(64)).filter {
                    $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
                }
                publicCode = "price_\(providerID)_\(reason.rawValue)"
                    + (statusCode.map { "_\($0)" } ?? "")
                switch reason {
                case .invalidURL:
                    kind = .configurationInvalid
                case .decoding, .identityMismatch, .missingPrice:
                    kind = .invalidResponse
                case .httpStatus:
                    kind = statusCode == 401 || statusCode == 403
                        ? .authentication
                        : ((statusCode ?? 0) >= 500
                            ? .providerUnavailable : .providerRejected)
                }
            }
            return
        }
        if let error = error as? AnkrAPIError {
            switch error {
            case .missingConfiguration:
                kind = .configurationMissing
                publicCode = "missing_configuration"
            case .invalidProxyConfiguration:
                kind = .configurationInvalid
                publicCode = "invalid_proxy_configuration"
            case .invalidAPIKey:
                kind = .authentication
                publicCode = "invalid_api_key"
            case let .httpFailure(statusCode, _):
                kind = statusCode == 401 || statusCode == 403
                    ? .authentication
                    : (statusCode >= 500
                        ? .providerUnavailable
                        : .providerRejected)
                publicCode = "http_status_\(statusCode)"
            case let .rpcFailure(code, _):
                kind = .providerRejected
                publicCode = "rpc_error_\(code)"
            case .invalidResponse, .invalidTokenMetadata:
                kind = .invalidResponse
                publicCode = "invalid_response"
            case .developmentCredentialPersistenceFailure:
                kind = .persistence
                publicCode = "credential_storage_failed"
            case .invalidWalletAddress:
                kind = .providerRejected
                publicCode = "invalid_wallet_address"
            case .invalidContractAddress:
                kind = .providerRejected
                publicCode = "invalid_contract_address"
            case .unsupportedBlockchain:
                kind = .providerRejected
                publicCode = "unsupported_blockchain"
            case .tokenNotFound:
                kind = .providerRejected
                publicCode = "token_not_found"
            }
            return
        }
        if let error = error as? AnkrBalanceSnapshotError {
            kind = .invalidResponse
            publicCode = error.diagnosticDescription
            return
        }
        if let error = error as? PublicNodeEVMBalanceError {
            switch error {
            case .invalidWalletAddress,
                 .unsupportedNetwork,
                 .chainIDMismatch,
                 .invalidCatalogAsset:
                kind = .providerRejected
            case .invalidQuantity:
                kind = .invalidResponse
            case .providerRead:
                kind = .providerUnavailable
            }
            publicCode = error.diagnosticDescription
            return
        }
        if let error = error as? TronRPCError {
            kind = .providerRejected
            publicCode = "rpc_error_\(error.code)"
            return
        }
        if let error = error as? TronHistoryError {
            kind = .invalidResponse
            publicCode = "tron_history_\(error.diagnosticDescription)"
            return
        }
        if let error = error as? TronUInt256Error {
            kind = .invalidResponse
            publicCode = "tron_quantity_\(error.diagnosticDescription)"
            return
        }
        if let error = error as? BitcoinFamilySyncError {
            kind = .providerUnavailable
            publicCode = error.diagnosticDescription
            return
        }
        if let error = error as? BitcoinFamilyAPIError {
            kind = error == .invalidResponse
                ? .invalidResponse
                : .providerUnavailable
            publicCode = error.diagnosticDescription
            return
        }
        if let error = error as? BitcoinFamilyElectrumError {
            switch error {
            case .invalidResponse, .responseTooLarge:
                kind = .invalidResponse
            case .unavailable:
                kind = .providerUnavailable
            case .rpc:
                kind = .providerRejected
            case .submissionNotAttempted:
                kind = .providerUnavailable
            }
            publicCode = error.diagnosticDescription
            return
        }
        if error is HistoryPaginationError {
            kind = .invalidResponse
            publicCode = "invalid_history_pagination"
            return
        }
        if let error = error as? SolanaProviderError {
            kind = .invalidResponse
            publicCode = error.diagnosticDescription
            return
        }
        if let error = error as? NEARProviderError {
            switch error {
            case .missingConfiguration:
                kind = .configurationMissing
            case .invalidConfiguration:
                kind = .configurationInvalid
            case .http(status: 401, _), .http(status: 403, _):
                kind = .authentication
            case let .http(status, _) where status >= 500:
                kind = .providerUnavailable
            case .invalidResponse:
                kind = .invalidResponse
            default:
                kind = .providerRejected
            }
            publicCode = error.diagnosticDescription
            return
        }
        if let error = error as? SolanaTokenEligibilityError {
            kind = .invalidResponse
            publicCode = error.diagnosticDescription
            return
        }
        if let error = error as? WalletSnapshotPersistenceError {
            kind = .persistence
            publicCode = error.diagnosticDescription
            return
        }
        if let error = error as? SolanaSnapshotPersistenceError {
            kind = .persistence
            publicCode = error.diagnosticDescription
            return
        }
        if error is DecodingError {
            kind = .invalidResponse
            publicCode = "invalid_provider_response"
            return
        }
        if let error = error as? URLError {
            kind = .providerUnavailable
            publicCode = "transport_error_\(error.code.rawValue)"
            return
        }
        let nsError = error as NSError
        if stage == .persistence {
            kind = .persistence
            publicCode = "persistence_error_\(nsError.code)"
            return
        }
        kind = .unexpected
        publicCode = "unexpected_error_\(nsError.code)"
    }
}
