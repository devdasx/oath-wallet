import Foundation

struct NEARAccountMaterial: Hashable, Sendable {
    let address: String
    let publicKey: String
    let derivationPath: String?
}

struct NEARTokenMetadata: Hashable, Sendable {
    let contractID: String
    let name: String
    let symbol: String
    let decimals: Int
    let iconURL: URL?
    let isVerified: Bool
    let rank: Int

    var assetID: String { "near:\(contractID)" }
}

struct NEARAssetBalance: Hashable, Sendable {
    let metadata: NEARTokenMetadata?
    let amountText: String
    let atomicAmount: String

    var assetID: String {
        metadata?.assetID ?? NEARConstants.nativeAssetID
    }
}

struct NEARHistoryItem: Hashable, Sendable {
    let id: String
    let transactionHash: String
    let timestamp: Double
    let failed: Bool
    let sender: String
    let recipient: String
    let metadata: NEARTokenMetadata?
    let signedAmountText: String
    let networkFeeAtomic: String?
    let blockHeight: Int64?
    let nonce: Int64?
}

struct NEARWalletSnapshot: Sendable {
    let material: NEARAccountMaterial
    let balances: [NEARAssetBalance]
    let history: [NEARHistoryItem]
    let balanceFetchAuthority: WalletBalanceFetchAuthority
    let historyIsAuthoritative: Bool
    let providerFailureCodes: [String]

    var balancesAreAuthoritative: Bool {
        balanceFetchAuthority.inventoryIsAuthoritative
    }

    init(
        material: NEARAccountMaterial,
        balances: [NEARAssetBalance],
        history: [NEARHistoryItem],
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
                ?? Set(balances.map(\.assetID)),
            inventoryIsAuthoritative: balancesAreAuthoritative
        )
        self.historyIsAuthoritative = historyIsAuthoritative
        self.providerFailureCodes = providerFailureCodes
    }
}

struct NEARAccessKeyState: Sendable {
    let nonce: UInt64
    let blockHash: Data
    let isFullAccess: Bool
}

struct NEARAccountState: Sendable {
    let amount: String
    let locked: String
    let storageUsage: UInt64
}

struct NEARProtocolConfig: Sendable {
    let chainID: String
    let storageAmountPerByte: String
}

struct NEARSubmitResult: Sendable {
    let transactionHash: String
    let succeeded: Bool
    let providerStatus: String
}

enum NEARProviderError: Error, Sendable {
    case missingConfiguration
    case invalidConfiguration
    case invalidAddress
    case invalidContract
    case invalidResponse(String)
    case http(status: Int, code: String)
    case rpc(code: Int, message: String)
    case providerRejected(String)
    case insufficientFunds

    var diagnosticDescription: String {
        switch self {
        case .missingConfiguration: "near_configuration_missing"
        case .invalidConfiguration: "near_configuration_invalid"
        case .invalidAddress: "near_invalid_address"
        case .invalidContract: "near_invalid_contract"
        case let .invalidResponse(code): "near_invalid_response_\(code)"
        case let .http(status, code): "near_http_\(status)_\(code)"
        case let .rpc(code, message):
            "near_rpc_\(code)_\(NEARErrorCode.sanitize(message))"
        case let .providerRejected(code): "near_rejected_\(code)"
        case .insufficientFunds: "near_insufficient_funds"
        }
    }
}

enum NEARErrorCode {
    static func sanitize(_ value: String) -> String {
        String(
            value.lowercased().map {
                $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_"
            }
            .split(separator: "_")
            .prefix(8)
            .joined(separator: "_")
            .prefix(120)
        )
    }

    static func executionFailure(_ value: NEARJSONValue) -> String {
        let code = sanitize(executionFailurePath(value, depth: 0))
        return code.isEmpty ? "execution_failed" : code
    }

    private static func executionFailurePath(
        _ value: NEARJSONValue,
        depth: Int
    ) -> String {
        guard depth < 6 else { return "detail" }
        switch value {
        case let .object(object):
            let entries = object.sorted { lhs, rhs in
                let lhsStructured = lhs.value.objectValue != nil
                    || lhs.value.arrayValue != nil
                let rhsStructured = rhs.value.objectValue != nil
                    || rhs.value.arrayValue != nil
                if lhsStructured != rhsStructured {
                    return lhsStructured && !rhsStructured
                }
                return lhs.key < rhs.key
            }
            guard let entry = entries.first else { return "object" }
            guard entry.value.objectValue != nil
                    || entry.value.arrayValue != nil else {
                return entry.key
            }
            return entry.key + "_" + executionFailurePath(
                entry.value,
                depth: depth + 1
            )
        case let .array(values):
            guard let first = values.first else { return "array" }
            return executionFailurePath(first, depth: depth + 1)
        case let .string(value):
            return value
        case .integer:
            return "integer"
        case .unsignedInteger:
            return "unsigned_integer"
        case .decimal:
            return "decimal"
        case .boolean:
            return "boolean"
        case .null:
            return "null"
        }
    }
}
