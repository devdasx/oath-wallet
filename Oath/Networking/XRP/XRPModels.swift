import Foundation

struct XRPAccountMaterial: Hashable, Sendable {
    let address: String
    let publicKey: String
    let derivationPath: String?
}

struct XRPTokenMetadata: Hashable, Sendable {
    let currency: String
    let issuer: String
    let name: String
    let symbol: String
    let decimals: Int
    let isVerified: Bool
    let rank: Int

    var identity: String {
        "\(currency.uppercased()):\(issuer)"
    }

    var assetID: String {
        "xrp:\(currency.uppercased()):\(issuer)"
    }
}

enum XRPTokenCatalog {
    static var receiveTokens: [ReceiveToken] {
        ReceiveAssetCatalog.tokens(for: XRPConstants.networkID).filter {
            $0.variants.contains {
                $0.networkID == XRPConstants.networkID
                    && $0.contractAddress != nil
            }
        }
    }

    static func metadata(
        currency: String,
        issuer: String
    ) -> XRPTokenMetadata? {
        let decodedCurrency = XRPAmount.decodedCurrency(currency)
        guard let validatedIssuer = XRPAddress.validatedClassic(issuer) else {
            return nil
        }
        let contractAddress = "\(decodedCurrency):\(validatedIssuer)"
        guard
            let selection = ReceiveAssetCatalog.selection(
                assetIdentity: AssetIdentityKey.make(
                    networkID: XRPConstants.networkID,
                    contractAddress: contractAddress
                )
            ),
            selection.variant.networkID == XRPConstants.networkID,
            selection.variant.contractAddress != nil
        else {
            return nil
        }
        return XRPTokenMetadata(
            currency: decodedCurrency,
            issuer: validatedIssuer,
            name: selection.token.name,
            symbol: selection.token.symbol,
            decimals: selection.variant.decimals,
            isVerified: selection.variant.isVerified,
            rank: selection.variant.networkRank ?? selection.token.rank
        )
    }

    static func canonicalIdentity(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let separator = trimmed.firstIndex(of: ":") else {
            return nil
        }
        let currency = String(trimmed[..<separator])
        let issuer = String(trimmed[trimmed.index(after: separator)...])
        guard XRPAddress.validatedClassic(issuer) != nil else {
            return nil
        }
        return "\(XRPAmount.decodedCurrency(currency)):\(issuer)"
    }
}

struct XRPAssetBalance: Hashable, Sendable {
    let metadata: XRPTokenMetadata?
    let amountText: String
    let atomicAmount: String?

    var isNative: Bool { metadata == nil }

    var assetID: String {
        metadata?.assetID ?? XRPConstants.nativeAssetID
    }
}

struct XRPHistoryItem: Hashable, Sendable {
    let id: String
    let transactionHash: String
    let timestamp: Double
    let failed: Bool
    let sender: String
    let recipient: String
    let destinationTag: UInt64?
    let metadata: XRPTokenMetadata?
    let signedAmountText: String
    let networkFeeDrops: String
    let ledgerIndex: Int64?
    let sequence: Int64?
}

struct XRPWalletSnapshot: Sendable {
    let material: XRPAccountMaterial
    let balances: [XRPAssetBalance]
    let history: [XRPHistoryItem]
    let balanceFetchAuthority: WalletBalanceFetchAuthority
    let historyIsAuthoritative: Bool
    let providerFailureCodes: [String]
    let historyLedgerWatermark: Int64?

    var balancesAreAuthoritative: Bool {
        balanceFetchAuthority.inventoryIsAuthoritative
    }

    init(
        material: XRPAccountMaterial,
        balances: [XRPAssetBalance],
        history: [XRPHistoryItem],
        balancesAreAuthoritative: Bool,
        historyIsAuthoritative: Bool,
        providerFailureCodes: [String],
        historyLedgerWatermark: Int64?,
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
        self.historyLedgerWatermark = historyLedgerWatermark
    }
}

enum XRPProviderError: Error, Sendable {
    case missingConfiguration
    case invalidConfiguration
    case invalidAddress
    case invalidResponse(String)
    case http(status: Int, code: String)
    case rpc(code: Int, message: String)
    case providerRejected(String)
    case insufficientFunds

    var diagnosticDescription: String {
        switch self {
        case .missingConfiguration: "xrp_configuration_missing"
        case .invalidConfiguration: "xrp_configuration_invalid"
        case .invalidAddress: "xrp_invalid_address"
        case let .invalidResponse(code): "xrp_invalid_response_\(code)"
        case let .http(status, code): "xrp_http_\(status)_\(code)"
        case let .rpc(code, message):
            "xrp_rpc_\(code)_\(XRPErrorCode.sanitize(message))"
        case let .providerRejected(code): "xrp_rejected_\(code)"
        case .insufficientFunds: "xrp_insufficient_funds"
        }
    }
}

extension XRPProviderError {
    var isAccountNotFound: Bool {
        guard case let .providerRejected(code) = self else { return false }
        return code == "account_not_found"
    }
}

enum XRPSubmissionErrorClassifier {
    static func isDefinitivePreSubmission(
        _ error: XRPProviderError
    ) -> Bool {
        switch error {
        case .missingConfiguration, .invalidConfiguration, .invalidAddress,
             .insufficientFunds:
            true
        case .invalidResponse:
            false
        case let .http(status, _):
            (400..<500).contains(status)
                && !ProviderReliabilityClassification
                    .isRetryableHTTPStatus(status)
        case let .rpc(code, _):
            code == -32_700
                || code == -32_600
                || code == -32_601
                || code == -32_602
        case let .providerRejected(code):
            !isReliabilityRejection(code)
        }
    }

    static func isReliabilityRejection(_ code: String) -> Bool {
        let normalized = code.lowercased()
        return normalized.contains("too_busy")
            || normalized.contains("toobusy")
            || normalized.contains("slow_down")
            || normalized.contains("slowdown")
            || normalized.contains("notsynced")
            || normalized.contains("not_synced")
            || normalized.contains("no_network")
            || normalized.contains("nonetwork")
    }
}

enum XRPErrorCode {
    static func sanitize(_ value: String) -> String {
        let pieces = value.lowercased().map {
            $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_"
        }
        return String(
            String(pieces)
                .split(separator: "_")
                .prefix(8)
                .joined(separator: "_")
                .prefix(120)
        )
    }
}
