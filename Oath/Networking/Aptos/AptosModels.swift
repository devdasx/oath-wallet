import Foundation

struct AptosAccountMaterial: Hashable, Sendable {
    let address: String
    let publicKey: String
    let derivationPath: String?
}

struct AptosTokenMetadata: Hashable, Sendable {
    let assetType: String
    let metadataAddress: String?
    let name: String
    let symbol: String
    let decimals: Int
    let iconURL: URL?
    let tokenStandard: String
    let isVerified: Bool
    let rank: Int
}

struct AptosAssetBalance: Hashable, Sendable {
    let metadata: AptosTokenMetadata
    let amountText: String
    let atomicAmount: String

    var assetID: String? {
        AptosAssetType.assetID(metadata.assetType)
    }
}

struct AptosHistoryItem: Hashable, Sendable {
    let id: String
    let transactionVersion: Int64
    let transactionHash: String
    let timestamp: Double
    let failed: Bool
    let sender: String?
    let recipient: String?
    let owner: String
    let metadata: AptosTokenMetadata
    let signedAmountText: String
    let networkFeeText: String?
    let entryFunction: String?
}

struct AptosWalletSnapshot: Sendable {
    let material: AptosAccountMaterial
    let balances: [AptosAssetBalance]
    let history: [AptosHistoryItem]
    let balanceFetchAuthority: WalletBalanceFetchAuthority
    let historyIsAuthoritative: Bool
    let providerFailureCodes: [String]

    var balancesAreAuthoritative: Bool {
        balanceFetchAuthority.inventoryIsAuthoritative
    }

    init(
        material: AptosAccountMaterial,
        balances: [AptosAssetBalance],
        history: [AptosHistoryItem],
        balancesAreAuthoritative: Bool,
        historyIsAuthoritative: Bool,
        providerFailureCodes: [String],
        successfulBalanceAssetIDs: Set<String>? = nil
    ) {
        self.material = material
        self.balances = balances
        self.history = history
        balanceFetchAuthority = WalletBalanceFetchAuthority(
            successfulAssetIDs: successfulBalanceAssetIDs
                ?? Set(balances.compactMap(\.assetID)),
            inventoryIsAuthoritative: balancesAreAuthoritative
        )
        self.historyIsAuthoritative = historyIsAuthoritative
        self.providerFailureCodes = providerFailureCodes
    }
}

struct AptosAccountState: Hashable, Sendable {
    let sequenceNumber: UInt64
    let authenticationKey: String
}

struct AptosGasEstimate: Hashable, Sendable {
    let deprioritized: UInt64
    let standard: UInt64
    let prioritized: UInt64
}

struct AptosAssetSendState: Hashable, Sendable {
    let atomicAmount: String
    let isFrozen: Bool
}

struct AptosSubmitResult: Hashable, Sendable {
    let transactionHash: String
}

struct AptosTransactionStatusResponse: Decodable, Sendable {
    let type: String
    let hash: String
    let success: Bool?
}

struct AptosSimulationResult: Hashable, Sendable {
    let sender: String
    let sequenceNumber: UInt64
    let maximumGasAmount: UInt64
    let gasUnitPrice: UInt64
    let gasUsed: UInt64
    let succeeded: Bool
    let vmStatus: String
}

enum AptosProviderError: Error, Sendable {
    case invalidConfiguration
    case invalidAddress
    case invalidAssetType
    case invalidResponse(String)
    case http(status: Int, code: String)
    case indexer(String)
    case insufficientFunds
    case providerRejected(String)

    var diagnosticDescription: String {
        switch self {
        case .invalidConfiguration: "aptos_configuration_invalid"
        case .invalidAddress: "aptos_invalid_address"
        case .invalidAssetType: "aptos_invalid_asset_type"
        case let .invalidResponse(code): "aptos_invalid_response_\(code)"
        case let .http(status, code): "aptos_http_\(status)_\(code)"
        case let .indexer(code): "aptos_indexer_\(code)"
        case .insufficientFunds: "aptos_insufficient_funds"
        case let .providerRejected(code): "aptos_provider_rejected_\(code)"
        }
    }
}

enum AptosSubmissionErrorClassifier {
    static func isDefinitiveRejection(
        _ error: AptosProviderError
    ) -> Bool {
        switch error {
        case let .providerRejected(code):
            !mayRepresentPriorSubmission(code)
        case .invalidAddress, .invalidAssetType, .insufficientFunds:
            true
        case let .http(status, code):
            (400..<500).contains(status)
                && status != 408
                && status != 429
                && !mayRepresentPriorSubmission(code)
        case .invalidConfiguration, .invalidResponse, .indexer:
            false
        }
    }

    static func mayRepresentPriorSubmission(_ code: String) -> Bool {
        let normalized = AptosRESTTransport.publicCode(code)
        return normalized == "sequence_number_too_old"
            || normalized == "invalid_transaction_update"
    }
}
