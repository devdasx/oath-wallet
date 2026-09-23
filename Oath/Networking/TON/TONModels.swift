import Foundation

struct TONAccountMaterial: Hashable, Sendable {
    let address: String
    let rawAddress: String
    let bounceableAddress: String
    let publicKey: String
    let derivationPath: String?
}

struct TONTokenDefinition: Hashable, Sendable {
    let address: String
    let name: String
    let symbol: String
    let decimals: Int
    let rank: Int
}

struct TONTokenBalance: Sendable {
    let definition: TONTokenDefinition
    let walletAddress: String
    let amountText: String
    let atomicAmount: String
    let usdPriceText: String?
}

struct TONHistoryItem: Sendable {
    let id: String
    let transactionHash: String
    let timestamp: Double
    let failed: Bool
    let from: String?
    let to: String?
    let assetAddress: String?
    let assetName: String
    let assetSymbol: String
    let decimals: Int
    let amountText: String
    let atomicAmount: String
}

struct TONWalletSnapshot: Sendable {
    let material: TONAccountMaterial
    let nativeAmountText: String
    let nativeAtomicAmount: String
    let nativeUSDPriceText: String?
    let tokens: [TONTokenBalance]
    let history: [TONHistoryItem]
    let jettonsAreAuthoritative: Bool
    let eventsAreAuthoritative: Bool
    let providerFailureCodes: [String]

    init(
        material: TONAccountMaterial,
        nativeAmountText: String,
        nativeAtomicAmount: String,
        nativeUSDPriceText: String?,
        tokens: [TONTokenBalance],
        history: [TONHistoryItem],
        jettonsAreAuthoritative: Bool = true,
        eventsAreAuthoritative: Bool = true,
        providerFailureCodes: [String] = []
    ) {
        self.material = material
        self.nativeAmountText = nativeAmountText
        self.nativeAtomicAmount = nativeAtomicAmount
        self.nativeUSDPriceText = nativeUSDPriceText
        self.tokens = tokens
        self.history = history
        self.jettonsAreAuthoritative = jettonsAreAuthoritative
        self.eventsAreAuthoritative = eventsAreAuthoritative
        self.providerFailureCodes = providerFailureCodes
    }
}

struct TONOptionalComponent<Value: Sendable>: Sendable {
    let value: Value
    let isComplete: Bool
    let failureCodes: [String]
}

enum TONProviderError: Error, Sendable {
    case missingConfiguration
    case invalidConfiguration
    case invalidResponse(String)
    case server(status: Int, code: String)
    case accountDerivationUnavailable
    case providerRejected(String)

    var diagnosticDescription: String {
        switch self {
        case .missingConfiguration: "ton_configuration_missing"
        case .invalidConfiguration: "ton_configuration_invalid"
        case let .invalidResponse(code): "ton_invalid_response_\(code)"
        case let .server(status, code): "ton_server_\(status)_\(code)"
        case .accountDerivationUnavailable: "ton_account_derivation_unavailable"
        case let .providerRejected(code): "ton_provider_rejected_\(code)"
        }
    }
}

enum TONSubmissionErrorClassifier {
    static func isDefinitivePreSubmission(
        _ error: TONProviderError
    ) -> Bool {
        switch error {
        case .missingConfiguration,
             .invalidConfiguration,
             .accountDerivationUnavailable,
             .providerRejected:
            return true
        case .invalidResponse:
            return false
        case let .server(status, code):
            if code == "ton_broadcast_rejected_seqno"
                || code == "ton_broadcast_rejected_exit_33" {
                return false
            }
            if code.hasPrefix("ton_preflight_rejected_")
                || code.hasPrefix("ton_broadcast_rejected_") {
                return true
            }
            return (400...499).contains(status)
                && status != 408
                && status != 425
                && status != 429
        }
    }
}
