import Foundation

enum SendNetworkFeePreset: String, Codable, CaseIterable, Hashable, Sendable {
    case fastest
    case standard
    case economy
    case custom

    var titleKey: String {
        "send.network_fee.preset.\(rawValue).title"
    }

    var detailKey: String {
        "send.network_fee.preset.\(rawValue).detail"
    }
}

enum SendNetworkFeeQuoteModel: String, Codable, Hashable, Sendable {
    case evmEIP1559 = "evm_eip1559"
    case evmLegacy = "evm_legacy"
    case utxoPerVByte = "utxo_per_vbyte"
    case solanaPriority = "solana_priority"
    case tronProtocol = "tron_protocol"
    case tonProtocol = "ton_protocol"
    case suiProtocol = "sui_protocol"
    case xrpProtocol = "xrp_protocol"
    case aptosProtocol = "aptos_protocol"
    case nearProtocol = "near_protocol"
    case stellarProtocol = "stellar_protocol"
}

enum SendNetworkFeeCustomModel: String, Codable, Hashable, Sendable {
    case evmEIP1559 = "evm_eip1559"
    case evmLegacy = "evm_legacy"
    case utxoPerVByte = "utxo_per_vbyte"
    case solanaPriority = "solana_priority"
    case tronFeeLimit = "tron_fee_limit"

    static func model(for networkID: String) -> SendNetworkFeeCustomModel? {
        if ReceiveNetworkCatalog.network(for: networkID)?.chainID ?? 0 > 0 {
            return .evmEIP1559
        }
        if BitcoinFamilyChain.allCases.contains(where: {
            $0.networkID == networkID
        }) {
            return .utxoPerVByte
        }
        switch networkID {
        case SolanaConstants.networkID:
            return .solanaPriority
        case TronConstants.networkID:
            return .tronFeeLimit
        default:
            return nil
        }
    }
}

struct SendNetworkFeeCustomValue: Hashable, Codable, Sendable {
    let model: SendNetworkFeeCustomModel
    let primaryValue: String
    let secondaryValue: String?
    /// The exact native-atomic total entered by the user. `primaryValue`
    /// remains the chain-specific rate/cap required by the signer, while this
    /// value is the authoritative custom budget shown throughout Send.
    let totalBudgetAtomic: String?

    init(
        model: SendNetworkFeeCustomModel,
        primaryValue: String,
        secondaryValue: String?,
        totalBudgetAtomic: String? = nil
    ) {
        self.model = model
        self.primaryValue = primaryValue
        self.secondaryValue = secondaryValue
        self.totalBudgetAtomic = totalBudgetAtomic
    }

    func isValid(for networkID: String) -> Bool {
        guard Self.supports(model: model, networkID: networkID),
              Self.isBaseUnitInteger(primaryValue),
              let totalBudgetAtomic,
              Self.isBaseUnitInteger(totalBudgetAtomic),
              totalBudgetAtomic != "0"
        else {
            return false
        }
        switch model {
        case .evmEIP1559:
            guard
                let secondaryValue,
                Self.isBaseUnitInteger(secondaryValue),
                SendDecimalAmount.compare(
                    SendDecimalAmount.userUnits(
                        fromAtomicUnits: primaryValue,
                        decimals: 9
                    ),
                    SendDecimalAmount.userUnits(
                        fromAtomicUnits: secondaryValue,
                        decimals: 9
                    )
                ) != .orderedAscending
            else {
                return false
            }
        case .evmLegacy, .utxoPerVByte, .tronFeeLimit:
            guard primaryValue != "0", secondaryValue == nil else {
                return false
            }
        case .solanaPriority:
            guard secondaryValue == nil else { return false }
        }
        if model == .tronFeeLimit {
            return totalBudgetAtomic == primaryValue
                && UInt64(primaryValue).map { $0 > 0 } == true
        }
        return SendNetworkFeeValidation.isValid(
            SendNetworkFeeTier(
                preset: .custom, model: model.quoteModel,
                primaryValue: primaryValue, secondaryValue: secondaryValue
            ),
            networkID: networkID
        )
    }

    private static func supports(
        model: SendNetworkFeeCustomModel,
        networkID: String
    ) -> Bool {
        if ReceiveNetworkCatalog.network(for: networkID)?.chainID ?? 0 > 0 {
            return model == .evmEIP1559 || model == .evmLegacy
        }
        return model == SendNetworkFeeCustomModel.model(for: networkID)
    }

    private static func isBaseUnitInteger(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 100
            && value.allSatisfy { $0 >= "0" && $0 <= "9" }
            && (value == "0" || value.first != "0")
    }
}

struct SendNetworkFeePolicy: Hashable, Codable, Sendable {
    let preset: SendNetworkFeePreset
    let customValue: SendNetworkFeeCustomValue?

    static let fastest = SendNetworkFeePolicy(
        preset: .fastest,
        customValue: nil
    )

    static func preset(_ preset: SendNetworkFeePreset)
        -> SendNetworkFeePolicy {
        SendNetworkFeePolicy(
            preset: preset == .custom ? .fastest : preset,
            customValue: nil
        )
    }

    static func custom(_ value: SendNetworkFeeCustomValue)
        -> SendNetworkFeePolicy {
        SendNetworkFeePolicy(preset: .custom, customValue: value)
    }

    /// Selects automatic rates from the shared database cache; it does not authorize a network request.
    var requiresLiveQuote: Bool {
        preset != .custom || customValue == nil
    }
}

struct SendNetworkFeeTier: Hashable, Codable, Sendable {
    let preset: SendNetworkFeePreset
    let model: SendNetworkFeeQuoteModel
    let primaryValue: String
    let secondaryValue: String?
}

struct SendNetworkFeeQuote: Hashable, Codable, Sendable {
    let networkID: String
    let provider: String
    let fetchedAt: Date
    let expiresAt: Date
    let tiers: [SendNetworkFeeTier]
    let tronParameters: SendTronProtocolParameters?

    init(networkID: String, provider: String, fetchedAt: Date, expiresAt: Date,
         tiers: [SendNetworkFeeTier], tronParameters: SendTronProtocolParameters? = nil) {
        self.networkID = networkID
        self.provider = provider
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.tiers = tiers
        self.tronParameters = tronParameters
    }

    func tier(for preset: SendNetworkFeePreset) -> SendNetworkFeeTier? {
        tiers.first { $0.preset == preset }
    }
}

struct SendNetworkFeeQuoteEnvelope: Decodable, Sendable {
    let quote: SendNetworkFeeQuote
}

enum SendNetworkFeeBaseUnitConverter {
    static func baseUnits(
        from input: String,
        decimals: Int,
        permitsZero: Bool
    ) throws -> String {
        let parsed = try SendDecimalAmount.parseUserUnits(
            input,
            maximumFractionDigits: decimals
        )
        guard permitsZero || !parsed.isZero else {
            throw SendNetworkFeeInputError.zero
        }
        let parts = parsed.canonical.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        let integer = String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        let paddedFraction = fraction + String(
            repeating: "0",
            count: max(0, decimals - fraction.count)
        )
        let combined = (integer + paddedFraction)
            .drop(while: { $0 == "0" })
        let result = combined.isEmpty ? "0" : String(combined)
        guard result.utf8.count <= 100 else {
            throw SendNetworkFeeInputError.tooLarge
        }
        return result
    }
}

enum SendNetworkFeeInputError: Error, Hashable, Sendable {
    case required
    case invalid
    case zero
    case belowNetworkMinimum
    case priorityExceedsMaximum
    case tooLarge
    case exceedsBalance
    case balanceUnavailable

    var localizedMessage: String {
        switch self {
        case .required:
            WalletLocalization.string("send.network_fee.error.required")
        case .invalid:
            WalletLocalization.string("send.network_fee.error.invalid")
        case .zero:
            WalletLocalization.string("send.network_fee.error.zero")
        case .belowNetworkMinimum:
            WalletLocalization.string(
                "send.network_fee.error.below_network_minimum"
            )
        case .priorityExceedsMaximum:
            WalletLocalization.string(
                "send.network_fee.error.priority_exceeds_maximum"
            )
        case .tooLarge:
            WalletLocalization.string("send.network_fee.error.too_large")
        case .exceedsBalance:
            WalletLocalization.string(
                "send.network_fee.error.exceeds_balance"
            )
        case .balanceUnavailable:
            WalletLocalization.string(
                "send.network_fee.error.balance_unavailable"
            )
        }
    }
}
