import Foundation

struct SendTransactionReceipt: Hashable, Sendable {
    let transactionHash: String
    let accountID: String
    let networkID: String
    let fromAddress: String
    let toAddress: String
    let assetID: String
    let assetSymbol: String
    let amount: String
    let amountAtomic: String
    let networkFee: String?
    let networkFeeAtomic: String?
    let networkFeeSymbol: String
    let submittedAt: Date
    /// Exact replay/consumption identifiers, persisted before network submission.
    var spendResources: Set<SendSpendResource> = []
}

struct SendResolvedSigningMaterial: Sendable {
    let walletID: String
    let account: DBWalletAccountRecord
    let privateKey: Data
    let bitcoinHDRecoveryCredential: WalletRecoveryCredential?
    let muunRecoveryKeyMaterial: MuunRecoveryKeyMaterial?
    let bitcoinImportedMaterial: BitcoinImportedWalletMaterial?

    init(
        walletID: String,
        account: DBWalletAccountRecord,
        privateKey: Data,
        bitcoinHDRecoveryCredential: WalletRecoveryCredential? = nil,
        muunRecoveryKeyMaterial: MuunRecoveryKeyMaterial? = nil,
        bitcoinImportedMaterial: BitcoinImportedWalletMaterial? = nil
    ) {
        self.walletID = walletID
        self.account = account
        self.privateKey = privateKey
        self.bitcoinHDRecoveryCredential = bitcoinHDRecoveryCredential
        self.muunRecoveryKeyMaterial = muunRecoveryKeyMaterial
        self.bitcoinImportedMaterial = bitcoinImportedMaterial
    }
}

enum SendSpendReservationState: String, Hashable, Sendable {
    case preparing
    case submissionStarted
}

struct SendSpendReservationEvidence: Hashable, Sendable {
    let reservationID: String
    let accountID: String
    let walletID: String
    let networkID: String
    let state: SendSpendReservationState
    let transactionHash: String?
    let fromAddress: String?
    let createdAt: Date

    var statusReceipt: SendTransactionReceipt? {
        guard state == .submissionStarted,
              let transactionHash,
              !transactionHash.isEmpty,
              let fromAddress,
              !fromAddress.isEmpty else {
            return nil
        }
        return SendTransactionReceipt(
            transactionHash: transactionHash,
            accountID: accountID,
            networkID: networkID,
            fromAddress: fromAddress,
            toAddress: "",
            assetID: "",
            assetSymbol: "",
            amount: "0",
            amountAtomic: "0",
            networkFee: nil,
            networkFeeAtomic: nil,
            networkFeeSymbol: "",
            submittedAt: createdAt
        )
    }
}

enum SendSpendReservationStoreError: Error, Sendable {
    case conflict(SendSpendReservationEvidence)
    case staleReservation
}

protocol SendSpendSubmissionReserving: Sendable {
    func pendingSpendResources() async throws -> Set<SendSpendResource>
    func markSubmissionStarted(
        receipt: SendTransactionReceipt
    ) async throws
}

struct SendSpendReservation: SendSpendSubmissionReserving {
    let reservationID: String
    let accountID: String
    let walletID: String
    let networkID: String
    private let database: WalletDatabase

    func pendingSpendResources() async throws -> Set<SendSpendResource> {
        try await database.pendingSendSpendResources(accountID: accountID)
    }

    init(
        reservationID: String,
        accountID: String,
        walletID: String,
        networkID: String,
        database: WalletDatabase
    ) {
        self.reservationID = reservationID
        self.accountID = accountID
        self.walletID = walletID
        self.networkID = networkID
        self.database = database
    }

    func markSubmissionStarted(
        receipt: SendTransactionReceipt
    ) async throws {
        do {
            try await database.markSendSpendSubmissionStarted(
                reservation: self,
                receipt: receipt
            )
        } catch let error as SendTransactionSubmissionError {
            throw error
        } catch {
            throw SendTransactionSubmissionError.persistence(
                code: SendTransactionSubmissionService.persistenceCode(
                    error
                )
            )
        }
    }
}

enum SendTransactionSubmissionError: Error, Hashable, Sendable {
    case authorizationExpired
    case walletUnavailable
    case accountUnavailable
    case watchOnlyAccount
    case secretUnavailable
    case derivedAddressMismatch
    case invalidRecipient
    case selfTransferNotSupported
    case invalidAmount
    case tokenMetadataMismatch
    case amountOutOfRange
    case insufficientAssetBalance
    case insufficientNetworkFeeBalance
    case spendAlreadyReserved(networkID: String, stateCode: String)
    case solanaRecipientRentMinimum(requiredAmount: String)
    case solanaSenderRentMinimum(requiredAmount: String)
    case feeQuoteUnavailable(String)
    case unsupportedNetwork
    case unsupportedAsset
    case provider(
        networkID: String,
        code: String,
        message: String
    )
    case signing(code: String, message: String)
    case broadcastRejected(
        code: String,
        message: String,
        receipt: SendTransactionReceipt? = nil
    )
    case broadcastExecutionFailed(
        code: String,
        message: String,
        receipt: SendTransactionReceipt
    )
    case broadcastOutcomeUnknown(
        networkID: String,
        code: String,
        receipt: SendTransactionReceipt? = nil
    )
    case persistence(code: String)

    var localizedMessage: String {
        switch self {
        case .authorizationExpired:
            WalletLocalization.string(
                "send.submit.error.authorization_expired"
            )
        case .walletUnavailable:
            WalletLocalization.string(
                "send.submit.error.wallet_unavailable"
            )
        case .accountUnavailable:
            WalletLocalization.string(
                "send.submit.error.account_unavailable"
            )
        case .watchOnlyAccount:
            WalletLocalization.string(
                "send.submit.error.watch_only"
            )
        case .secretUnavailable:
            WalletLocalization.string(
                "send.submit.error.secret_unavailable"
            )
        case .derivedAddressMismatch:
            WalletLocalization.string(
                "send.submit.error.derived_address_mismatch"
            )
        case .invalidRecipient:
            WalletLocalization.string(
                "send.submit.error.invalid_recipient"
            )
        case .selfTransferNotSupported:
            SendRecipientValidationIssue.selfTransferNotSupported.localizedMessage
        case .invalidAmount:
            WalletLocalization.string(
                "send.submit.error.invalid_amount"
            )
        case .tokenMetadataMismatch:
            WalletLocalization.string(
                "wallet.assets.add_token.invalid_metadata.message"
            )
        case .amountOutOfRange:
            WalletLocalization.string(
                "send.submit.error.amount_out_of_range"
            )
        case .insufficientAssetBalance:
            WalletLocalization.string(
                "send.submit.error.insufficient_asset_balance"
            )
        case .insufficientNetworkFeeBalance:
            WalletLocalization.string(
                "send.submit.error.insufficient_fee_balance"
            )
        case .spendAlreadyReserved:
            WalletLocalization.string(
                "send.submit.error.spend_reservation"
            )
        case let .solanaRecipientRentMinimum(requiredAmount):
            EnglishNumbers.localized(
                "send.submit.error.solana_recipient_rent",
                requiredAmount
            )
        case let .solanaSenderRentMinimum(requiredAmount):
            EnglishNumbers.localized(
                "send.submit.error.solana_sender_rent",
                requiredAmount
            )
        case let .feeQuoteUnavailable(code):
            if code == "custom_fee_budget_below_required"
                || code == "custom_fee_below_network_minimum" {
                WalletLocalization.string("send.network_fee.error.below_network_minimum")
            } else {
                WalletLocalization.string("send.submit.error.try_again")
            }
        case .unsupportedNetwork:
            WalletLocalization.string(
                "send.submit.error.unsupported_network"
            )
        case .unsupportedAsset:
            WalletLocalization.string(
                "send.submit.error.unsupported_asset"
            )
        case .provider, .signing, .persistence:
            WalletLocalization.string("send.submit.error.try_again")
        case let .broadcastRejected(code, message, _):
            SendTronProviderMessage.rejectionDescription(code: code, message: message)
        case .broadcastExecutionFailed:
            WalletLocalization.string("send.broadcast.execution_failed.detail")
        case .broadcastOutcomeUnknown:
            WalletLocalization.string("send.broadcast.warning.detail")
        }
    }

    /// Presentation only: preserve the original provider error and retry/evidence
    /// semantics. An uncertain or executed submission must never say "not sent".
    func localizedFailureMessage(networkID: String, isNative: Bool) -> String {
        guard let key = insufficientFundsMessageKey(networkID: networkID, isNative: isNative) else {
            return localizedMessage
        }
        return WalletLocalization.string(key)
    }

    func insufficientFundsMessageKey(networkID: String, isNative: Bool) -> String? {
        guard networkID == "arbitrum" else { return nil }
        switch self {
        case .insufficientNetworkFeeBalance:
            return isNative ? "send.submit.error.arbitrum_eth_total" : "send.submit.error.arbitrum_eth_fee"
        case .insufficientAssetBalance:
            // A token shortage is distinct from a shortage of the native gas coin.
            return isNative ? "send.submit.error.arbitrum_eth_total" : nil
        case let .provider(providerNetwork, code, message):
            guard providerNetwork == networkID, code.hasPrefix("rpc_"),
                  Self.isNativeFundsRejection(message) else { return nil }
        case let .broadcastRejected(code, message, receipt):
            guard code.hasPrefix("rpc_"),
                  receipt == nil || receipt?.networkID == networkID,
                  Self.isNativeFundsRejection(message) else { return nil }
        default:
            return nil
        }
        return isNative ? "send.submit.error.arbitrum_eth_total" : "send.submit.error.arbitrum_eth_fee"
    }

    static func isNativeFundsRejection(_ message: String) -> Bool {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Nitro's estimator can wrap the same node error with its gas probe.
        if let prefix = text.range(of: "^failed with [0-9]+ gas: *", options: .regularExpression) {
            text.removeSubrange(prefix)
        }
        // Scroll wraps estimator failures with this prefix. Do not strip
        // contract-revert prefixes, which can describe a token balance instead.
        if text.hasPrefix("err: ") { text.removeFirst(5) }
        // Match node affordability errors, not arbitrary ERC-20 revert reasons.
        return text == "insufficient funds"
            || text == "insufficient funds for transfer"
            || text.hasPrefix("insufficient funds for transfer:")
            || text == "insufficient funds for gas * price + value"
            || text.hasPrefix("insufficient funds for gas * price + value:")
            || text == "insufficient funds for gas * price + value + l1fees"
            || text.hasPrefix("insufficient funds for gas * price + value + l1fees:")
    }

    var diagnosticCode: String {
        switch self {
        case .authorizationExpired:
            "authorization_expired"
        case .walletUnavailable:
            "wallet_unavailable"
        case .accountUnavailable:
            "account_unavailable"
        case .watchOnlyAccount:
            "watch_only_account"
        case .secretUnavailable:
            "secret_unavailable"
        case .derivedAddressMismatch:
            "derived_address_mismatch"
        case .invalidRecipient:
            "invalid_recipient"
        case .selfTransferNotSupported:
            "self_transfer_not_supported"
        case .invalidAmount:
            "invalid_amount"
        case .tokenMetadataMismatch:
            "token_metadata_mismatch"
        case .amountOutOfRange:
            "amount_out_of_range"
        case .insufficientAssetBalance:
            "insufficient_asset_balance"
        case .insufficientNetworkFeeBalance:
            "insufficient_network_fee_balance"
        case let .spendAlreadyReserved(networkID, stateCode):
            "spend_reserved_\(Self.sanitized(networkID))_\(Self.sanitized(stateCode))"
        case .solanaRecipientRentMinimum:
            "solana_recipient_rent_minimum"
        case .solanaSenderRentMinimum:
            "solana_sender_rent_minimum"
        case let .feeQuoteUnavailable(code):
            "fee_quote_\(Self.sanitized(code))"
        case let .provider(networkID, code, _):
            "provider_\(Self.sanitized(networkID))_\(Self.sanitized(code))"
        case let .signing(code, _):
            "signing_\(Self.sanitized(code))"
        case let .broadcastRejected(code, _, _):
            "broadcast_\(Self.sanitized(code))"
        case let .broadcastExecutionFailed(code, _, receipt):
            "broadcast_failed_\(Self.sanitized(receipt.networkID))_\(Self.sanitized(code))"
        case let .broadcastOutcomeUnknown(networkID, code, _):
            "broadcast_unknown_\(Self.sanitized(networkID))_\(Self.sanitized(code))"
        case let .persistence(code):
            "persistence_\(Self.sanitized(code))"
        case .unsupportedNetwork:
            "unsupported_network"
        case .unsupportedAsset:
            "unsupported_asset"
        }
    }

    var submissionMayHaveSucceeded: Bool {
        if case .broadcastOutcomeUnknown = self {
            return true
        }
        return false
    }

    var allowsRetry: Bool {
        switch self {
        case .broadcastOutcomeUnknown, .broadcastExecutionFailed:
            false
        default:
            true
        }
    }

    var wasExecutedOnNetwork: Bool {
        if case .broadcastExecutionFailed = self {
            return true
        }
        return false
    }

    var unconfirmedReceipt: SendTransactionReceipt? {
        guard case let .broadcastOutcomeUnknown(_, _, receipt) = self
        else {
            return nil
        }
        return receipt
    }

    var transactionEvidenceReceipt: SendTransactionReceipt? {
        switch self {
        case let .broadcastRejected(_, _, receipt):
            receipt
        case let .broadcastExecutionFailed(_, _, receipt):
            receipt
        case let .broadcastOutcomeUnknown(_, _, receipt):
            receipt
        default:
            nil
        }
    }

    func attachingTransactionEvidence(
        _ receipt: SendTransactionReceipt
    ) -> SendTransactionSubmissionError {
        switch self {
        case let .broadcastRejected(code, message, _):
            .broadcastRejected(
                code: code,
                message: message,
                receipt: receipt
            )
        case let .broadcastExecutionFailed(code, message, _):
            .broadcastExecutionFailed(
                code: code,
                message: message,
                receipt: receipt
            )
        case let .broadcastOutcomeUnknown(networkID, code, _):
            .broadcastOutcomeUnknown(
                networkID: networkID,
                code: code,
                receipt: receipt
            )
        default:
            self
        }
    }

    static func sanitizedErrorType(_ error: Error) -> String {
        sanitized(String(reflecting: type(of: error)))
    }

    static func sanitized(_ value: String) -> String {
        let output = value.lowercased().unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                ? Character(scalar)
                : "_"
        }
        return String(output).prefix(80).description
    }

    static func sanitizedMessage(_ value: String) -> String {
        let permitted = value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        let output = String(String.UnicodeScalarView(permitted))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty
            ? WalletLocalization.string(
                "send.submit.error.provider_no_message"
            )
            : String(output.prefix(300))
    }
}

struct SendResolvedNetworkFee: Hashable, Sendable {
    let model: SendNetworkFeeQuoteModel
    let primaryValue: String
    let secondaryValue: String?
    let totalBudgetAtomic: String?
    let provider: String?
    let expiresAt: Date?
    let tronParameters: SendTronProtocolParameters?

    init(
        model: SendNetworkFeeQuoteModel,
        primaryValue: String,
        secondaryValue: String?,
        totalBudgetAtomic: String? = nil,
        provider: String? = nil,
        expiresAt: Date? = nil,
        tronParameters: SendTronProtocolParameters? = nil
    ) {
        self.model = model
        self.primaryValue = primaryValue
        self.secondaryValue = secondaryValue
        self.totalBudgetAtomic = totalBudgetAtomic
        self.provider = provider
        self.expiresAt = expiresAt
        self.tronParameters = tronParameters
    }

    func withTronParameters(_ parameters: SendTronProtocolParameters?) -> Self {
        Self(model: model, primaryValue: primaryValue, secondaryValue: secondaryValue,
            totalBudgetAtomic: totalBudgetAtomic, provider: provider, expiresAt: expiresAt,
            tronParameters: parameters)
    }

    func resolvedTronParameters(isCustom: Bool) throws -> SendTronProtocolParameters {
        if let tronParameters, tronParameters.isValid { return tronParameters }
        let defaults = SendTronProtocolParameters.defaults
        if isCustom { return defaults }
        guard model == .tronProtocol, let energy = UInt64(primaryValue), energy > 0,
              let secondaryValue, let bandwidth = UInt64(secondaryValue), bandwidth > 0 else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable("wrong_tron_fee_model")
        }
        return SendTronProtocolParameters(energyPrice: energy, bandwidthPrice: bandwidth,
            accountCreationFee: defaults.accountCreationFee,
            accountCreationBandwidthFee: defaults.accountCreationBandwidthFee,
            accountCreationBandwidthRate: defaults.accountCreationBandwidthRate)
    }

    var isFreshLiveQuote: Bool {
        guard let provider, !provider.isEmpty, let expiresAt else {
            return false
        }
        return expiresAt > Date()
    }

    static func resolve(
        policy: SendNetworkFeePolicy,
        quote: SendNetworkFeeQuote
    ) throws -> SendResolvedNetworkFee {
        if !policy.requiresLiveQuote {
            return try resolveCustom(
                policy: policy,
                networkID: quote.networkID
            ).withTronParameters(quote.tronParameters)
        }
        guard let tier = quote.tier(for: policy.preset) else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("missing_selected_tier")
        }
        guard SendNetworkFeeValidation.isValid(tier, networkID: quote.networkID) else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable("invalid_selected_tier")
        }
        let primaryValue = quote.networkID == BitcoinFamilyChain.bitcoin.networkID
            ? try SendBitcoinTransactionPolicy.automaticFeeRate(
                tier.primaryValue,
                isBuiltIn: quote.provider == SendNetworkFeeAPIClient.builtInDefaultProvider
            ) : tier.primaryValue
        return SendResolvedNetworkFee(
            model: tier.model,
            primaryValue: primaryValue,
            secondaryValue: tier.secondaryValue,
            provider: quote.provider,
            expiresAt: quote.expiresAt,
            tronParameters: quote.tronParameters
        )
    }

    static func resolveCustom(
        policy: SendNetworkFeePolicy,
        networkID: String
    ) throws -> SendResolvedNetworkFee {
        guard policy.preset == .custom,
              let custom = policy.customValue,
              custom.isValid(for: networkID) else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("invalid_custom_fee")
        }
        let model: SendNetworkFeeQuoteModel = switch custom.model {
        case .evmEIP1559: .evmEIP1559
        case .evmLegacy: .evmLegacy
        case .utxoPerVByte: .utxoPerVByte
        case .solanaPriority: .solanaPriority
        case .tronFeeLimit: .tronProtocol
        }
        return SendResolvedNetworkFee(
            model: model,
            primaryValue: custom.primaryValue,
            secondaryValue: custom.secondaryValue,
            totalBudgetAtomic: custom.totalBudgetAtomic
        )
    }
}

/// The Review screen binds the best fee available at the moment the user
/// continues. Submission consumes that immutable value and therefore never
/// waits for a second fee-provider request. A draft created outside Review
/// still receives the built-in mainnet default synchronously.
enum SendSubmissionNetworkFee {
    typealias QuoteLoader = @Sendable (String) async throws
        -> SendNetworkFeeQuote

    static func resolve(
        draft: SendDraft
    ) throws -> SendResolvedNetworkFee {
        if !draft.feePolicy.requiresLiveQuote {
            return try SendResolvedNetworkFee.resolveCustom(
                policy: draft.feePolicy,
                networkID: draft.asset.networkID
            ).withTronParameters(draft.preparedNetworkFee?.tronParameters)
        }
        if let prepared = draft.preparedNetworkFee {
            // Review commits the best available live or built-in fee. From that
            // point forward this exact fee is part of the authorization digest,
            // so submission must consume it unchanged even when the provider's
            // short cache TTL elapses during authentication or signing.
            return prepared
        }
        let quote = try SendNetworkFeeAPIClient.defaultQuote(
            for: draft.asset.networkID
        )
        return try SendResolvedNetworkFee.resolve(
            policy: draft.feePolicy,
            quote: quote
        )
    }

    static func resolve(
        draft: SendDraft,
        quoteLoader: QuoteLoader
    ) async throws -> SendResolvedNetworkFee {
        if !draft.feePolicy.requiresLiveQuote {
            return try SendResolvedNetworkFee.resolveCustom(
                policy: draft.feePolicy,
                networkID: draft.asset.networkID
            ).withTronParameters(draft.preparedNetworkFee?.tronParameters)
        }
        if let prepared = draft.preparedNetworkFee {
            // Do not replace an authorized fee with a later provider response.
            // The reviewed value is immutable once attached to the draft.
            return prepared
        }
        let quote = try await quoteLoader(draft.asset.networkID)
        return try SendResolvedNetworkFee.resolve(
            policy: draft.feePolicy,
            quote: quote
        )
    }

    static func builtInQuote(
        for networkID: String
    ) async throws -> SendNetworkFeeQuote {
        try SendNetworkFeeAPIClient.defaultQuote(for: networkID)
    }
}
