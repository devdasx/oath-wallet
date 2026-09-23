import Foundation

struct SendStellarTransactionService: Sendable {
    typealias QuoteLoader = @Sendable (String) async throws
        -> SendNetworkFeeQuote

    private let api: StellarAPIClient
    private let quoteLoader: QuoteLoader

    init(
        api: StellarAPIClient = .shared,
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
        guard draft.asset.networkID == StellarConstants.networkID else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        guard let sender = StellarAddress.validated(material.account.address),
              let recipient = StellarAddress.validated(draft.recipient),
              let requestedAmount = draft.amount
        else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        let requestedAtomic = try SendAtomicAmount.int64(
            SendAtomicAmount.fromUserUnits(
                requestedAmount,
                decimals: StellarConstants.decimals
            )
        )
        let memo = try Self.memo(draft.request.memo)
        let token = try Self.tokenIdentity(draft.asset.contractAddress)
        let fee: SendResolvedNetworkFee
        do {
            fee = try await SendSubmissionNetworkFee.resolve(
                draft: draft,
                quoteLoader: quoteLoader
            )
        } catch let error as SendNetworkFeeAPIError {
            throw SendTransactionSubmissionError.feeQuoteUnavailable(
                error.diagnosticCode
            )
        }

        async let senderStateValue = api.accountState(address: sender)
        async let recipientStateValue = api.accountState(address: recipient)
        async let networkStateValue = api.networkState(usingSavedFee: fee.primaryValue)

        let senderState: StellarAccountState
        let recipientState: StellarAccountState?
        let networkState: StellarNetworkState
        do {
            guard let value = try await senderStateValue else {
                throw SendTransactionSubmissionError.provider(
                    networkID: StellarConstants.networkID,
                    code: "source_account_not_found",
                    message: WalletLocalization.string(
                        "send.submit.error.stellar_source_inactive"
                    )
                )
            }
            senderState = value
            (recipientState, networkState) = try await (
                recipientStateValue,
                networkStateValue
            )
        } catch let error as SendTransactionSubmissionError {
            throw error
        } catch let error as StellarProviderError {
            throw Self.providerError(error)
        } catch {
            throw SendTransactionSubmissionError.provider(
                networkID: StellarConstants.networkID,
                code: SendTransactionSubmissionError
                    .sanitizedErrorType(error),
                message: WalletLocalization.string(
                    "send.submit.error.stellar_provider"
                )
            )
        }

        guard fee.model == .stellarProtocol,
              let feeStroops = Int64(fee.primaryValue),
              feeStroops >= StellarConstants.minimumFeeStroops,
              feeStroops <= Int64(UInt32.max)
        else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable(
                "wrong_stellar_fee_model"
            )
        }

        let prepared = try Self.prepareAmount(
            draft: draft,
            requestedAtomic: requestedAtomic,
            senderState: senderState,
            recipientState: recipientState,
            networkState: networkState,
            feeStroops: feeStroops,
            token: token
        )
        let sequence = senderState.sequence.addingReportingOverflow(1)
        guard !sequence.overflow else {
            throw SendTransactionSubmissionError.provider(
                networkID: StellarConstants.networkID,
                code: "sequence_overflow",
                message: WalletLocalization.string(
                    "send.submit.error.stellar_provider"
                )
            )
        }

        let operation: StellarTransactionOperation
        switch prepared.operation {
        case .createAccount:
            operation = .createAccount(
                destination: recipient,
                amountStroops: prepared.atomicAmount
            )
        case .nativePayment:
            operation = .payment(
                destination: recipient,
                asset: nil,
                amountStroops: prepared.atomicAmount
            )
        case let .tokenPayment(identity):
            operation = .payment(
                destination: recipient,
                asset: identity,
                amountStroops: prepared.atomicAmount
            )
        }
        let signedTransaction: StellarSignedTransaction
        do {
            signedTransaction = try StellarTransactionXDRBuilder.signedTransaction(
                source: sender,
                sequence: sequence.partialValue,
                feeStroops: feeStroops,
                memo: memo,
                operation: operation,
                privateKeyData: material.privateKey
            )
        } catch let error as StellarTransactionXDRBuilderError {
            throw SendTransactionSubmissionError.signing(
                code: error.diagnosticCode,
                message: WalletLocalization.string(
                    "send.submit.error.stellar_signing"
                )
            )
        }

        var receipt = SendTransactionReceipt(
            transactionHash: signedTransaction.transactionHash,
            accountID: material.account.id,
            networkID: StellarConstants.networkID,
            fromAddress: sender,
            toAddress: recipient,
            assetID: draft.asset.id,
            assetSymbol: draft.asset.symbol,
            amount: prepared.userAmount,
            amountAtomic: String(prepared.atomicAmount),
            networkFee: SendDecimalAmount.userUnits(
                fromAtomicUnits: String(feeStroops),
                decimals: StellarConstants.decimals
            ),
            networkFeeAtomic: String(feeStroops),
            networkFeeSymbol: StellarConstants.nativeSymbol,
            submittedAt: Date()
        )

        receipt.spendResources = [.sequence(String(sequence.partialValue))]
        try await reservation.markSubmissionStarted(receipt: receipt)
        let result: StellarSubmitResult
        do {
            result = try await api.submit(xdr: signedTransaction.envelopeXDR)
        } catch let error as StellarProviderError {
            if StellarSubmissionErrorClassifier
                .isDefinitivePreSubmission(error) {
                throw SendTransactionSubmissionError.broadcastRejected(
                    code: error.diagnosticDescription,
                    message: WalletLocalization.string(
                        "send.submit.error.stellar_rejected"
                    ),
                    receipt: receipt
                )
            }
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: StellarConstants.networkID,
                code: error.diagnosticDescription,
                receipt: receipt
            )
        } catch {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: StellarConstants.networkID,
                code: SendTransactionSubmissionError
                    .sanitizedErrorType(error),
                receipt: receipt
            )
        }
        guard result.transactionHash.utf8.count == 64,
              result.transactionHash.allSatisfy(\.isHexDigit),
              result.transactionHash.caseInsensitiveCompare(
                  signedTransaction.transactionHash
              ) == .orderedSame
        else {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: StellarConstants.networkID,
                code: "invalid_or_mismatched_submission_result",
                receipt: receipt
            )
        }
        if !result.successful {
            guard result.ledger != nil else {
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: StellarConstants.networkID,
                        code: "unconfirmed_transaction_failure",
                        receipt: receipt
                    )
            }
            throw SendTransactionSubmissionError.broadcastExecutionFailed(
                code: "stellar_transaction_failed",
                message: WalletLocalization.string(
                    "send.submit.error.stellar_rejected"
                ),
                receipt: receipt
            )
        }
        return receipt
    }

    private static func memo(_ value: String?) throws -> String? {
        guard let normalized = StellarMemoTextValidator.normalized(value)
        else { return nil }
        guard let validated = StellarMemoTextValidator.validated(normalized)
        else {
            throw SendTransactionSubmissionError.provider(
                networkID: StellarConstants.networkID,
                code: "invalid_memo_text",
                message: WalletLocalization.string(
                    "send.stellar.memo.error"
                )
            )
        }
        return validated
    }

    private static func tokenIdentity(
        _ contractAddress: String?
    ) throws -> StellarAssetIdentity? {
        guard let contractAddress, !contractAddress.isEmpty else { return nil }
        guard let identity = StellarAssetIdentity.validated(
            contractAddress: contractAddress
        ) else {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        return identity
    }

    static func prepareAmount(
        draft: SendDraft,
        requestedAtomic: Int64,
        senderState: StellarAccountState,
        recipientState: StellarAccountState?,
        networkState: StellarNetworkState,
        feeStroops: Int64,
        token: StellarAssetIdentity?
    ) throws -> PreparedStellarAmount {
        guard requestedAtomic > 0,
              let nativeBalance = Int64(senderState.nativeBalanceStroops),
              let nativeLiabilities = Int64(
                  senderState.nativeSellingLiabilitiesStroops
              ),
              let baseReserve = Int64(networkState.baseReserveStroops),
              nativeBalance >= 0,
              nativeLiabilities >= 0,
              baseReserve > 0
        else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        let reserveEntries = try Self.reserveEntries(senderState)
        let reserve = baseReserve.multipliedReportingOverflow(
            by: reserveEntries
        )
        guard !reserve.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        let lockedNative = Self.checkedSum(
            reserve.partialValue,
            nativeLiabilities,
            feeStroops
        )
        guard let lockedNative, nativeBalance >= lockedNative else {
            throw SendTransactionSubmissionError
                .insufficientNetworkFeeBalance
        }

        if let token {
            guard let recipientState else {
                throw SendTransactionSubmissionError.provider(
                    networkID: StellarConstants.networkID,
                    code: "destination_account_not_found",
                    message: WalletLocalization.string(
                        "send.submit.error.stellar_token_destination_inactive"
                    )
                )
            }
            let amount: Int64
            if senderState.address == token.issuer {
                guard !draft.usesMaximumBalance else {
                    throw SendTransactionSubmissionError.invalidAmount
                }
                amount = requestedAtomic
            } else {
                guard let sourceLine = senderState.trustlines.first(where: {
                    $0.identity == token && $0.authorized
                }),
                      let tokenBalance = Int64(sourceLine.balanceStroops),
                      let tokenLiabilities = Int64(
                          sourceLine.sellingLiabilitiesStroops
                      ),
                      tokenBalance >= tokenLiabilities
                else {
                    throw SendTransactionSubmissionError
                        .insufficientAssetBalance
                }
                let spendable = tokenBalance - tokenLiabilities
                amount = draft.usesMaximumBalance
                    ? spendable : requestedAtomic
                guard amount > 0, amount <= spendable else {
                    throw SendTransactionSubmissionError
                        .insufficientAssetBalance
                }
            }

            let recipientLine = recipientState.trustlines.first(where: {
                $0.identity == token && $0.authorized
            })
            guard recipientState.address == token.issuer
                    || recipientLine != nil else {
                throw SendTransactionSubmissionError.provider(
                    networkID: StellarConstants.networkID,
                    code: "destination_missing_trustline",
                    message: WalletLocalization.string(
                        "send.submit.error.stellar_destination_trustline"
                    )
                )
            }

            if let recipientLine {
                guard let balance = Int64(recipientLine.balanceStroops),
                      let buyingLiabilities = Int64(
                          recipientLine.buyingLiabilitiesStroops
                      ),
                      let limit = Int64(recipientLine.limitStroops),
                      balance >= 0,
                      buyingLiabilities >= 0,
                      limit >= balance,
                      let occupied = Self.checkedSum(
                          balance,
                          buyingLiabilities
                      ),
                      occupied <= limit,
                      amount <= limit - occupied
                else {
                    throw SendTransactionSubmissionError.provider(
                        networkID: StellarConstants.networkID,
                        code: "destination_trustline_limit",
                        message: WalletLocalization.string(
                            "send.submit.error.stellar_destination_trustline"
                        )
                    )
                }
            }
            return PreparedStellarAmount(
                atomicAmount: amount,
                userAmount: SendDecimalAmount.userUnits(
                    fromAtomicUnits: String(amount),
                    decimals: StellarConstants.decimals
                ),
                operation: .tokenPayment(token)
            )
        }

        let amount = try SendNativeTransferAmountResolver.int64(
            requestedAtomic: requestedAtomic,
            balanceAtomic: nativeBalance,
            unavailableAtomic: lockedNative,
            usesMaximumBalance: draft.usesMaximumBalance
        )
        if recipientState == nil {
            let destinationReserve = baseReserve.multipliedReportingOverflow(
                by: 2
            )
            guard !destinationReserve.overflow,
                  amount >= destinationReserve.partialValue
            else {
                throw SendTransactionSubmissionError.provider(
                    networkID: StellarConstants.networkID,
                    code: "destination_reserve_required",
                    message: WalletLocalization.string(
                        "send.submit.error.stellar_destination_reserve"
                    )
                )
            }
        }
        return PreparedStellarAmount(
            atomicAmount: amount,
            userAmount: SendDecimalAmount.userUnits(
                fromAtomicUnits: String(amount),
                decimals: StellarConstants.decimals
            ),
            operation: recipientState == nil
                ? .createAccount : .nativePayment
        )
    }

    static func reserveEntries(
        _ state: StellarAccountState
    ) throws -> Int64 {
        guard state.subentryCount >= 0,
              state.numSponsoring >= 0,
              state.numSponsored >= 0 else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        guard let entriesWithSubentries = checkedSum(
            2,
            state.subentryCount,
            state.numSponsoring
        ) else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        let result = entriesWithSubentries.subtractingReportingOverflow(
            state.numSponsored
        )
        guard !result.overflow, result.partialValue >= 2 else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result.partialValue
    }

    private static func checkedSum(_ values: Int64...) -> Int64? {
        var sum: Int64 = 0
        for value in values {
            let result = sum.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            sum = result.partialValue
        }
        return sum
    }

    private static func providerError(
        _ error: StellarProviderError
    ) -> SendTransactionSubmissionError {
        switch error {
        case .insufficientFunds:
            .insufficientAssetBalance
        default:
            .provider(
                networkID: StellarConstants.networkID,
                code: error.diagnosticDescription,
                message: WalletLocalization.string(
                    "send.submit.error.stellar_provider"
                )
            )
        }
    }
}

struct PreparedStellarAmount: Sendable {
    enum Operation: Sendable {
        case createAccount
        case nativePayment
        case tokenPayment(StellarAssetIdentity)
    }

    let atomicAmount: Int64
    let userAmount: String
    let operation: Operation
}
