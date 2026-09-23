import Foundation
import WalletCore

struct SendXRPTransactionService: Sendable {
    typealias QuoteLoader = @Sendable (String) async throws
        -> SendNetworkFeeQuote

    private let api: XRPAPIClient
    private let quoteLoader: QuoteLoader

    init(
        api: XRPAPIClient = .shared,
        quoteLoader: @escaping QuoteLoader =
            SendSubmissionNetworkFee.builtInQuote
    ) {
        self.api = api
        self.quoteLoader = quoteLoader
    }

    func submit(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        reservation: any SendSpendSubmissionReserving
    ) async throws -> SendTransactionReceipt {
        guard draft.asset.networkID == XRPConstants.networkID else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        guard let sender = XRPAddress.validatedClassic(
            material.account.address
        ),
              let requestedAmount = draft.amount
        else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        let explicitDestinationTag: UInt32?
        do {
            explicitDestinationTag = try XRPDestinationTag.parsed(
                draft.request.memo
            )
        } catch {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard let destination = XRPAddress.resolvedDestination(
            address: draft.recipient,
            explicitTag: explicitDestinationTag
        ) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        try SendSelfTransferPolicy.validate(draft: draft, sourceAddress: sender)
        let recipient = destination.classicAddress
        let destinationTag = destination.destinationTag
        let token = try Self.tokenIdentity(draft.asset.contractAddress)
        let resolvedFee: SendResolvedNetworkFee
        do {
            resolvedFee = try await SendSubmissionNetworkFee.resolve(
                draft: draft,
                quoteLoader: quoteLoader
            )
        } catch let error as SendNetworkFeeAPIError {
            throw SendTransactionSubmissionError.feeQuoteUnavailable(
                error.diagnosticCode
            )
        }

        async let senderStateValue = api.accountState(address: sender)
        async let recipientStateValue = api.optionalAccountState(
            address: recipient
        )
        async let reserveValue = api.reserveRequirements()
        async let ledgerValue = api.currentLedgerIndex()
        async let senderTrustLineValue = trustLineBalance(
            address: sender,
            token: token
        )
        async let recipientTrustLineValue = trustLineBalance(
            address: recipient,
            token: token
        )
        async let issuerStateValue = issuerAccountState(token: token)

        let senderState: XRPAccountState
        let recipientState: XRPAccountState?
        let reserve: XRPReserveRequirements
        let currentLedger: UInt32
        let senderTrustLine: XRPTrustLineState?
        let recipientTrustLine: XRPTrustLineState?
        let issuerState: XRPAccountState?
        do {
            (
                senderState,
                recipientState,
                reserve,
                currentLedger,
                senderTrustLine,
                recipientTrustLine,
                issuerState
            ) = try await (
                senderStateValue,
                recipientStateValue,
                reserveValue,
                ledgerValue,
                senderTrustLineValue,
                recipientTrustLineValue,
                issuerStateValue
            )
        } catch let error as XRPProviderError {
            throw Self.providerError(error)
        } catch {
            throw SendTransactionSubmissionError.provider(
                networkID: XRPConstants.networkID,
                code: SendTransactionSubmissionError
                    .sanitizedErrorType(error),
                message: WalletLocalization.string(
                    "send.submit.error.xrp_provider"
                )
            )
        }
        guard !senderState.masterKeyIsDisabled else {
            throw Self.preflightError(
                code: "sender_master_key_disabled",
                localizationKey: "send.submit.error.xrp_master_key_disabled"
            )
        }
        if recipientState?.requiresDestinationTag == true,
           destinationTag == nil {
            throw Self.preflightError(
                code: "destination_tag_required",
                localizationKey: "send.submit.error.xrp_destination_tag_required"
            )
        }

        guard resolvedFee.model == .xrpProtocol,
              let feeDrops = UInt64(resolvedFee.primaryValue),
              feeDrops >= 10,
              feeDrops <= UInt64(Int64.max)
        else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable(
                "wrong_xrp_fee_model"
            )
        }
        let ownerReserve: UInt64
        do {
            ownerReserve = try reserve.requiredDrops(
                ownerCount: senderState.ownerCount
            )
        } catch let error as XRPProviderError {
            throw Self.providerError(error)
        }

        let prepared = try Self.prepareAmount(
            draft: draft,
            requestedAmount: requestedAmount,
            sender: sender,
            recipient: recipient,
            senderState: senderState,
            recipientState: recipientState,
            ownerReserve: ownerReserve,
            destinationBaseReserve: reserve.baseDrops,
            feeDrops: feeDrops,
            token: token,
            issuerState: issuerState,
            senderTrustLine: senderTrustLine,
            recipientTrustLine: recipientTrustLine
        )
        if recipientState?.requiresDepositAuthorization == true,
           !Self.isDepositAuthorizationReserveException(
               prepared: prepared,
               recipientState: recipientState,
               baseReserveDrops: reserve.baseDrops
           ) {
            let authorized: Bool
            do {
                authorized = try await api.depositAuthorized(
                    source: sender,
                    destination: recipient
                )
            } catch let error as XRPProviderError {
                throw Self.providerError(error)
            } catch {
                throw SendTransactionSubmissionError.provider(
                    networkID: XRPConstants.networkID,
                    code: SendTransactionSubmissionError
                        .sanitizedErrorType(error),
                    message: WalletLocalization.string(
                        "send.submit.error.xrp_provider"
                    )
                )
            }
            guard authorized else {
                throw Self.preflightError(
                    code: "deposit_not_authorized",
                    localizationKey:
                        "send.submit.error.xrp_deposit_not_authorized"
                )
            }
        }
        let lastLedger = currentLedger.addingReportingOverflow(20)
        guard !lastLedger.overflow else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable(
                "xrp_ledger_overflow"
            )
        }

        guard let signingDestination = XRPAddress.signingDestination(
            classicAddress: recipient,
            destinationTag: destinationTag
        ) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        var payment = RippleOperationPayment()
        payment.destination = signingDestination
        if let destinationTag, destinationTag != 0 {
            payment.destinationTag = UInt64(destinationTag)
        }
        switch prepared.value {
        case let .native(drops):
            payment.amount = Int64(drops)
        case let .issued(value, token):
            payment.currencyAmount = .with {
                $0.currency = token.currency
                $0.value = value
                $0.issuer = token.issuer
            }
        }

        let sequence = try await SendAtomicAmount.uint64(
            reservation.nextSequence(networkValue: String(senderState.sequence))
        )
        guard sequence <= UInt32.max else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        let output: RippleSigningOutput = AnySigner.sign(
            input: RippleSigningInput.with {
                $0.account = sender
                $0.fee = Int64(feeDrops)
                $0.sequence = UInt32(sequence)
                $0.lastLedgerSequence = lastLedger.partialValue
                $0.privateKey = material.privateKey
                $0.opPayment = payment
            },
            coin: .xrp
        )
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SendTransactionSubmissionError.signing(
                code: String(output.error.rawValue),
                message: SendTransactionSubmissionError
                    .sanitizedMessage(output.errorMessage)
            )
        }
        let localHash = Self.transactionHash(output.encoded)
        var receipt = SendTransactionReceipt(
            transactionHash: localHash,
            accountID: material.account.id,
            networkID: XRPConstants.networkID,
            fromAddress: sender,
            toAddress: recipient,
            assetID: draft.asset.id,
            assetSymbol: draft.asset.symbol,
            amount: prepared.userUnits,
            amountAtomic: prepared.atomicUnits,
            networkFee: SendDecimalAmount.userUnits(
                fromAtomicUnits: String(feeDrops),
                decimals: XRPConstants.decimals
            ),
            networkFeeAtomic: String(feeDrops),
            networkFeeSymbol: XRPConstants.nativeSymbol,
            submittedAt: Date()
        )

        receipt.spendResources = [.sequence(String(sequence))]
        try await reservation.markSubmissionStarted(receipt: receipt)
        let result: XRPSubmitResult
        do {
            result = try await api.submit(
                transactionBlob: output.encoded.hexString.uppercased()
            )
        } catch let error as XRPProviderError {
            if XRPSubmissionErrorClassifier
                .isDefinitivePreSubmission(error) {
                throw SendTransactionSubmissionError.broadcastRejected(
                    code: error.diagnosticDescription,
                    message: WalletLocalization.string(
                        "send.submit.error.xrp_rejected"
                    ),
                    receipt: receipt
                )
            }
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: XRPConstants.networkID,
                code: error.diagnosticDescription,
                receipt: receipt
            )
        } catch {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: XRPConstants.networkID,
                code: SendTransactionSubmissionError
                    .sanitizedErrorType(error),
                receipt: receipt
            )
        }
        if result.mayHaveConsumedSequence {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: XRPConstants.networkID,
                code: XRPErrorCode.sanitize(result.engineResult),
                receipt: receipt
            )
        }
        guard result.wasAccepted else {
            throw SendTransactionSubmissionError.broadcastRejected(
                code: XRPErrorCode.sanitize(result.engineResult),
                message: WalletLocalization.string(
                    "send.submit.error.xrp_rejected"
                ),
                receipt: receipt
            )
        }
        if let providerHash = result.transactionHash,
           providerHash.caseInsensitiveCompare(localHash) != .orderedSame {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: XRPConstants.networkID,
                code: "broadcast_hash_mismatch",
                receipt: receipt
            )
        }
        return receipt
    }

    private func trustLineBalance(
        address: String,
        token: XRPTokenIdentity?
    ) async throws -> XRPTrustLineState? {
        guard let token, address != token.issuer else { return nil }
        return try await api.trustLineState(
            address: address,
            currency: token.currency,
            issuer: token.issuer
        )
    }

    private func issuerAccountState(
        token: XRPTokenIdentity?
    ) async throws -> XRPAccountState? {
        guard let token else { return nil }
        return try await api.accountState(address: token.issuer)
    }

    private static func tokenIdentity(
        _ value: String?
    ) throws -> XRPTokenIdentity? {
        guard let value, !value.isEmpty else { return nil }
        let pieces = value.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard pieces.count == 2 else {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        let currency = String(pieces[0]).uppercased()
        let issuer = String(pieces[1])
        let isStandardCurrency = currency.count == 3
            && currency.unicodeScalars.allSatisfy({ scalar in
                scalar.isASCII
                    && CharacterSet.alphanumerics.contains(scalar)
            })
            && currency != XRPConstants.nativeSymbol
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789ABCDEF"
        )
        let isHexCurrency = currency.count == 40
            && currency.unicodeScalars.allSatisfy {
                hexadecimal.contains($0)
            }
        guard (isStandardCurrency || isHexCurrency),
              let classicIssuer = XRPAddress.validatedClassic(issuer)
        else {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        return XRPTokenIdentity(
            currency: currency,
            issuer: classicIssuer
        )
    }

    private static func prepareAmount(
        draft: SendDraft,
        requestedAmount: String,
        sender: String,
        recipient: String,
        senderState: XRPAccountState,
        recipientState: XRPAccountState?,
        ownerReserve: UInt64,
        destinationBaseReserve: UInt64,
        feeDrops: UInt64,
        token: XRPTokenIdentity?,
        issuerState: XRPAccountState?,
        senderTrustLine: XRPTrustLineState?,
        recipientTrustLine: XRPTrustLineState?
    ) throws -> PreparedXRPAmount {
        guard let nativeBalance = UInt64(senderState.balanceDrops) else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        let reserveAndFee = ownerReserve.addingReportingOverflow(feeDrops)
        guard !reserveAndFee.overflow,
              nativeBalance >= reserveAndFee.partialValue
        else {
            throw SendTransactionSubmissionError
                .insufficientNetworkFeeBalance
        }

        if let token {
            guard recipientState != nil else {
                throw Self.preflightError(
                    code: "destination_account_not_found",
                    localizationKey:
                        "send.submit.error.xrp_token_destination_unfunded"
                )
            }
            guard let issuerState else {
                throw Self.preflightError(
                    code: "issuer_account_not_found",
                    localizationKey: "send.submit.error.xrp_provider"
                )
            }
            let requested: String
            do {
                requested = try XRPAmount.canonicalIssuedPayment(
                    requestedAmount
                )
            } catch {
                throw SendTransactionSubmissionError.invalidAmount
            }
            let amount: String
            if sender == token.issuer {
                guard !draft.usesMaximumBalance else {
                    throw SendTransactionSubmissionError.invalidAmount
                }
                amount = requested
            } else {
                guard let senderTrustLine,
                      XRPAmount.isPositive(senderTrustLine.balance)
                else {
                    throw SendTransactionSubmissionError
                        .insufficientAssetBalance
                }
                amount = draft.usesMaximumBalance
                    ? senderTrustLine.balance
                    : requested
                guard SendDecimalAmount.compare(
                    amount,
                    senderTrustLine.balance
                )
                        != .orderedDescending
                else {
                    throw SendTransactionSubmissionError
                        .insufficientAssetBalance
                }
            }
            try validateIssuedPayment(
                amount: amount,
                sender: sender,
                recipient: recipient,
                token: token,
                issuerState: issuerState,
                senderTrustLine: senderTrustLine,
                recipientTrustLine: recipientTrustLine
            )
            return PreparedXRPAmount(
                userUnits: amount,
                atomicUnits: amount,
                value: .issued(value: amount, token: token)
            )
        }

        let requestedDrops: UInt64
        do {
            requestedDrops = try SendAtomicAmount.uint64(
                SendAtomicAmount.fromUserUnits(
                    requestedAmount,
                    decimals: XRPConstants.decimals
                )
            )
        } catch {
            throw SendTransactionSubmissionError.invalidAmount
        }
        let amount = try SendNativeTransferAmountResolver.uint64(
            requestedAtomic: requestedDrops,
            balanceAtomic: nativeBalance,
            unavailableAtomic: reserveAndFee.partialValue,
            usesMaximumBalance: draft.usesMaximumBalance
        )
        guard amount > 0, amount <= UInt64(Int64.max) else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        if recipientState?.disallowsIncomingXRP == true {
            throw Self.preflightError(
                code: "destination_disallows_xrp",
                localizationKey: "send.submit.error.xrp_destination_disallows_xrp"
            )
        }
        if recipientState == nil, amount < destinationBaseReserve {
            throw Self.preflightError(
                code: "destination_reserve_required",
                localizationKey: "send.submit.error.xrp_destination_reserve"
            )
        }
        return PreparedXRPAmount(
            userUnits: SendDecimalAmount.userUnits(
                fromAtomicUnits: String(amount),
                decimals: XRPConstants.decimals
            ),
            atomicUnits: String(amount),
            value: .native(drops: amount)
        )
    }

    private static func validateIssuedPayment(
        amount: String,
        sender: String,
        recipient: String,
        token: XRPTokenIdentity,
        issuerState: XRPAccountState,
        senderTrustLine: XRPTrustLineState?,
        recipientTrustLine: XRPTrustLineState?
    ) throws {
        let issuer = token.issuer
        let isIssuance = sender == issuer
        let isRedemption = recipient == issuer

        if !isIssuance {
            guard senderTrustLine != nil else {
                throw SendTransactionSubmissionError
                    .insufficientAssetBalance
            }
        }
        if !isRedemption {
            guard let recipientTrustLine else {
                throw preflightError(
                    code: "destination_missing_trust_line",
                    localizationKey:
                        "send.submit.error.xrp_destination_trust_line"
                )
            }
            if issuerState.requiresAuthorization,
               !recipientTrustLine.authorizedByPeer {
                throw preflightError(
                    code: "destination_trust_line_unauthorized",
                    localizationKey:
                        "send.submit.error.xrp_trust_line_unauthorized"
                )
            }
            guard XRPAmount.canIncrease(
                balance: recipientTrustLine.balance,
                by: amount,
                through: recipientTrustLine.limit
            ) else {
                throw preflightError(
                    code: "destination_trust_line_limit",
                    localizationKey:
                        "send.submit.error.xrp_destination_limit"
                )
            }
        }

        // Issuance and redemption are direct interactions with the issuer.
        // XRPL explicitly exempts these paths from transfer fees and freezes.
        guard !isIssuance, !isRedemption,
              let senderTrustLine,
              let recipientTrustLine
        else {
            return
        }
        if issuerState.requiresAuthorization,
           !senderTrustLine.authorizedByPeer {
            throw preflightError(
                code: "sender_trust_line_unauthorized",
                localizationKey:
                    "send.submit.error.xrp_trust_line_unauthorized"
            )
        }
        if issuerState.hasGlobalFreeze
            || senderTrustLine.frozenByPeer
            || senderTrustLine.deepFrozenByPeer
            || senderTrustLine.deepFrozenByAccount
            || recipientTrustLine.frozenByAccount
            || recipientTrustLine.deepFrozenByAccount
            || recipientTrustLine.deepFrozenByPeer {
            throw preflightError(
                code: "trust_line_frozen",
                localizationKey: "send.submit.error.xrp_trust_line_frozen"
            )
        }
        if senderTrustLine.noRippleByPeer
            || recipientTrustLine.noRippleByPeer {
            throw preflightError(
                code: "issuer_rippling_disabled",
                localizationKey:
                    "send.submit.error.xrp_issuer_rippling_disabled"
            )
        }
        if !senderTrustLine.outgoingQualityIsNeutral
            || !recipientTrustLine.incomingQualityIsNeutral {
            throw preflightError(
                code: "trust_line_quality_unsupported",
                localizationKey:
                    "send.submit.error.xrp_trust_line_quality_unsupported"
            )
        }
        guard issuerState.transferRate == 1_000_000_000 else {
            // Wallet Core's XRP Payment protobuf has no SendMax field. Signing
            // without it would deterministically fail for a nonzero fee.
            throw preflightError(
                code: "transfer_fee_unsupported",
                localizationKey:
                    "send.submit.error.xrp_transfer_fee_unsupported"
            )
        }
    }

    private static func isDepositAuthorizationReserveException(
        prepared: PreparedXRPAmount,
        recipientState: XRPAccountState?,
        baseReserveDrops: UInt64
    ) -> Bool {
        guard case let .native(drops) = prepared.value,
              drops <= baseReserveDrops,
              let recipientState,
              let recipientBalance = UInt64(recipientState.balanceDrops),
              recipientBalance <= baseReserveDrops
        else {
            return false
        }
        return true
    }

    private static func preflightError(
        code: String,
        localizationKey: String
    ) -> SendTransactionSubmissionError {
        .provider(
            networkID: XRPConstants.networkID,
            code: code,
            message: WalletLocalization.string(localizationKey)
        )
    }

    static func transactionHash(_ encoded: Data) -> String {
        let prefix = Data([0x54, 0x58, 0x4E, 0x00])
        // XRPL's SHA-512Half predates and is different from SHA-512/256:
        // hash the TXN-prefixed signed blob with SHA-512, then keep its first
        // 256 bits. Using SHA-512/256 here makes a successful provider hash
        // look like a post-broadcast mismatch.
        return Hash.sha512(data: prefix + encoded)
            .prefix(32)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    private static func providerError(
        _ error: XRPProviderError
    ) -> SendTransactionSubmissionError {
        switch error {
        case .insufficientFunds:
            .insufficientAssetBalance
        default:
            .provider(
                networkID: XRPConstants.networkID,
                code: error.diagnosticDescription,
                message: WalletLocalization.string(
                    "send.submit.error.xrp_provider"
                )
            )
        }
    }
}

private struct XRPTokenIdentity: Hashable, Sendable {
    let currency: String
    let issuer: String
}

private struct PreparedXRPAmount: Sendable {
    enum Value: Sendable {
        case native(drops: UInt64)
        case issued(value: String, token: XRPTokenIdentity)
    }

    let userUnits: String
    let atomicUnits: String
    let value: Value
}
