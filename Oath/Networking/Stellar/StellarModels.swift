import Foundation

struct StellarAccountMaterial: Hashable, Sendable {
    let address: String
    let publicKey: String
    let derivationPath: String?
}

struct StellarAssetIdentity: Hashable, Sendable {
    let code: String
    let issuer: String

    var contractAddress: String { "\(code.uppercased()):\(issuer)" }
    var assetID: String {
        AssetIdentityKey.make(
            networkID: StellarConstants.networkID,
            contractAddress: contractAddress
        )
    }

    static func validated(
        code: String,
        issuer: String
    ) -> StellarAssetIdentity? {
        let normalizedCode = code.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).uppercased()
        guard (1...12).contains(normalizedCode.utf8.count),
              normalizedCode.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 90)
              }),
              let normalizedIssuer = StellarAddress.validated(issuer)
        else { return nil }
        return StellarAssetIdentity(
            code: normalizedCode,
            issuer: normalizedIssuer
        )
    }

    static func validated(
        contractAddress: String
    ) -> StellarAssetIdentity? {
        let pieces = contractAddress.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard pieces.count == 2 else { return nil }
        return validated(
            code: String(pieces[0]),
            issuer: String(pieces[1])
        )
    }
}

struct StellarTokenMetadata: Hashable, Sendable {
    let identity: StellarAssetIdentity
    let name: String
    let symbol: String
    let decimals: Int
    let isVerified: Bool
    let rank: Int

    var assetID: String { identity.assetID }
}

struct StellarAssetBalance: Hashable, Sendable {
    let metadata: StellarTokenMetadata?
    let amountText: String
    let atomicAmount: String

    var assetID: String {
        metadata?.assetID ?? StellarConstants.nativeAssetID
    }
}

struct StellarHistoryItem: Hashable, Sendable {
    let id: String
    let transactionHash: String
    let timestamp: Double
    let failed: Bool
    let sender: String
    let recipient: String
    let metadata: StellarTokenMetadata?
    let signedAmountText: String
    let networkFeeStroops: String?
    let ledgerIndex: Int64?
    let sourceSequence: Int64?
    let memo: String?
}

struct StellarWalletSnapshot: Sendable {
    let material: StellarAccountMaterial
    let balances: [StellarAssetBalance]
    let history: [StellarHistoryItem]
    let balanceFetchAuthority: WalletBalanceFetchAuthority
    let historyIsAuthoritative: Bool
    let providerFailureCodes: [String]

    var balancesAreAuthoritative: Bool {
        balanceFetchAuthority.inventoryIsAuthoritative
    }

    init(
        material: StellarAccountMaterial,
        balances: [StellarAssetBalance],
        history: [StellarHistoryItem],
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

struct StellarAccountState: Sendable {
    let address: String
    let sequence: Int64
    let nativeBalanceStroops: String
    let nativeSellingLiabilitiesStroops: String
    let subentryCount: Int64
    let numSponsoring: Int64
    let numSponsored: Int64
    let trustlines: [StellarTrustlineState]
}

struct StellarTrustlineState: Sendable {
    let identity: StellarAssetIdentity
    let balanceStroops: String
    let sellingLiabilitiesStroops: String
    let buyingLiabilitiesStroops: String
    let limitStroops: String
    let authorized: Bool
}

struct StellarNetworkState: Sendable {
    let baseReserveStroops: String
    let recommendedFeeStroops: Int64
}

struct StellarSubmitResult: Sendable {
    let transactionHash: String
    let successful: Bool
    let ledger: Int64?
}

enum StellarProviderError: Error, Sendable {
    case invalidAddress
    case invalidAsset
    case invalidResponse(String)
    case http(status: Int, code: String)
    case providerRejected(String)
    case insufficientFunds

    var diagnosticDescription: String {
        switch self {
        case .invalidAddress: "stellar_invalid_address"
        case .invalidAsset: "stellar_invalid_asset"
        case let .invalidResponse(code):
            "stellar_invalid_response_\(StellarErrorCode.sanitize(code))"
        case let .http(status, code):
            "stellar_http_\(status)_\(StellarErrorCode.sanitize(code))"
        case let .providerRejected(code):
            "stellar_rejected_\(StellarErrorCode.sanitize(code))"
        case .insufficientFunds: "stellar_insufficient_funds"
        }
    }
}

enum StellarSubmissionErrorClassifier {
    static func isDefinitivePreSubmission(
        _ error: StellarProviderError
    ) -> Bool {
        if sequenceMayHaveBeenConsumed(error) { return false }
        return switch error {
        case let .http(status, _) where
            (400..<500).contains(status) && status != 408 && status != 429:
            true
        case .providerRejected, .invalidAddress, .invalidAsset,
             .insufficientFunds:
            true
        default:
            false
        }
    }

    static func sequenceMayHaveBeenConsumed(
        _ error: StellarProviderError
    ) -> Bool {
        let code: String
        switch error {
        case let .http(_, value), let .providerRejected(value):
            code = value
        default:
            return false
        }
        return StellarErrorCode.sanitize(code).contains("tx_bad_seq")
    }
}

enum StellarErrorCode {
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
}
