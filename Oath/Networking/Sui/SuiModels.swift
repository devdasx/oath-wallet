import Foundation

struct SuiAccountMaterial: Hashable, Sendable {
    let address: String
    let publicKey: String
    let derivationPath: String?
}

struct SuiTokenMetadata: Hashable, Sendable {
    let coinType: String
    let name: String
    let symbol: String
    let decimals: Int
    let iconURL: URL?
    let isVerified: Bool
    let rank: Int
}

struct SuiAssetBalance: Hashable, Sendable {
    let metadata: SuiTokenMetadata
    let amountText: String
    let atomicAmount: String

    var assetID: String? {
        SuiCoinType.assetID(metadata.coinType)
    }
}

struct SuiHistoryItem: Hashable, Sendable {
    let id: String
    let transactionHash: String
    let timestamp: Double
    let failed: Bool
    let sender: String?
    let counterparty: String?
    let owner: String
    let metadata: SuiTokenMetadata
    let signedAtomicAmount: String
    let amountText: String
    let networkFeeText: String?
}

struct SuiWalletSnapshot: Sendable {
    let material: SuiAccountMaterial
    let balances: [SuiAssetBalance]
    let history: [SuiHistoryItem]
    let balanceFetchAuthority: WalletBalanceFetchAuthority
    let historyIsAuthoritative: Bool
    let providerFailureCodes: [String]

    var balancesAreAuthoritative: Bool {
        balanceFetchAuthority.inventoryIsAuthoritative
    }

    init(
        material: SuiAccountMaterial,
        balances: [SuiAssetBalance],
        history: [SuiHistoryItem],
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

struct SuiHistoryTransaction: Hashable, Sendable {
    let digest: String
    let sender: String?
    let status: String
    let timestamp: String?
    let balanceChanges: [SuiHistoryBalanceChange]
    let gasSummary: SuiGasCostSummary?
}

struct SuiHistoryBalanceChange: Hashable, Sendable {
    let owner: String?
    let coinType: String
    let amount: String
}

struct SuiGasCostSummary: Hashable, Sendable {
    let computationCost: UInt64
    let storageCost: UInt64
    let storageRebate: UInt64
    let nonRefundableStorageFee: UInt64

    var netFee: UInt64? {
        let computationAndStorage = computationCost.addingReportingOverflow(
            storageCost
        )
        guard !computationAndStorage.overflow,
              computationAndStorage.partialValue >= storageRebate
        else {
            return nil
        }
        return computationAndStorage.partialValue - storageRebate
    }
}

struct SuiCoinObject: Hashable, Sendable {
    let objectID: String
    let version: UInt64
    let digest: String
    let atomicBalance: UInt64
}

enum SuiProviderError: Error, Sendable {
    case invalidConfiguration
    case invalidAddress
    case invalidCoinType
    case invalidResponse(String)
    case http(status: Int, code: String)
    case graphQL(String)
    case grpc(status: Int)
    case submissionUnavailable(String)
    case insufficientFunds
    case providerRejected(String)
    case executionFailed(code: String, digest: String)

    var diagnosticDescription: String {
        switch self {
        case .invalidConfiguration:
            "sui_configuration_invalid"
        case .invalidAddress:
            "sui_invalid_address"
        case .invalidCoinType:
            "sui_invalid_coin_type"
        case let .invalidResponse(code):
            "sui_invalid_response_\(code)"
        case let .http(status, code):
            "sui_http_\(status)_\(code)"
        case let .grpc(status):
            "sui_grpc_status_\(status)"
        case let .submissionUnavailable(code):
            "sui_submission_unavailable_\(code)"
        case let .graphQL(code):
            "sui_graphql_\(code)"
        case .insufficientFunds:
            "sui_insufficient_funds"
        case let .providerRejected(code):
            "sui_provider_rejected_\(code)"
        case let .executionFailed(code, _):
            "sui_execution_failed_\(code)"
        }
    }
}
