import Foundation
import WalletCore

struct SendSuiTransactionService: Sendable {
    private let api: SuiAPIClient

    init(api: SuiAPIClient = .shared) {
        self.api = api
    }

    func submit(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        reservation: any SendSpendSubmissionReserving
    ) async throws -> SendTransactionReceipt {
        guard draft.asset.networkID == SuiConstants.networkID else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        let normalizedRecipient = draft.recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedSender = material.account.address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let recipient = Self.validAddress(normalizedRecipient) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard let sender = Self.validAddress(normalizedSender) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        guard let requestedAmount = draft.amount else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        let requestedAtomic = try SendAtomicAmount.uint64(
            SendAtomicAmount.fromUserUnits(
                requestedAmount,
                decimals: draft.asset.decimals
            )
        )
        let tokenCoinType: String?
        if let contractAddress = draft.asset.contractAddress {
            guard let canonical = SuiCoinType.canonical(contractAddress),
                  canonical != SuiConstants.nativeCoinType
            else {
                throw SendTransactionSubmissionError.unsupportedAsset
            }
            tokenCoinType = canonical
        } else {
            tokenCoinType = nil
        }

        async let gasObjectsValue = api.coinObjects(
            address: sender,
            coinType: SuiConstants.nativeCoinType
        )
        async let tokenObjectsValue = tokenObjects(
            address: sender,
            coinType: tokenCoinType
        )
        var gasObjects: [SuiCoinObject]
        var tokenObjects: [SuiCoinObject]?
        do {
            (gasObjects, tokenObjects) = try await (
                gasObjectsValue,
                tokenObjectsValue
            )
        } catch let error as SuiProviderError {
            throw Self.providerError(error)
        }

        let pendingResources = try await reservation.pendingSpendResources()
        gasObjects.removeAll { pendingResources.contains(.object($0)) }
        tokenObjects = tokenObjects?.filter { !pendingResources.contains(.object($0)) }

        let fee = try SendSubmissionNetworkFee.resolve(draft: draft)
        guard fee.model == .suiProtocol,
              let gasBudget = UInt64(fee.primaryValue),
              let referenceGasPriceText = fee.secondaryValue,
              let referenceGasPrice = UInt64(referenceGasPriceText),
              gasBudget > 0,
              referenceGasPrice > 0
        else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable(
                "wrong_sui_fee_model"
            )
        }

        let prepared: PreparedSuiTransfer
        if let tokenObjects {
            prepared = try Self.prepareToken(
                tokenObjects: tokenObjects,
                gasObjects: gasObjects,
                requestedAtomic: requestedAtomic,
                usesMaximumBalance: draft.usesMaximumBalance,
                gasBudget: gasBudget
            )
        } else {
            prepared = try Self.prepareNative(
                gasObjects: gasObjects,
                requestedAtomic: requestedAtomic,
                usesMaximumBalance: draft.usesMaximumBalance,
                gasBudget: gasBudget
            )
        }

        let output: SuiSigningOutput = AnySigner.sign(
            input: SuiSigningInput.with {
                $0.privateKey = material.privateKey
                $0.gasBudget = gasBudget
                $0.referenceGasPrice = referenceGasPrice
                switch prepared.kind {
                case let .native(inputCoins):
                    $0.paySui = .with {
                        $0.inputCoins = inputCoins.map(Self.objectReference)
                        $0.recipients = [recipient]
                        $0.amounts = [prepared.amountAtomic]
                    }
                case let .token(inputCoins, gas):
                    $0.pay = .with {
                        $0.inputCoins = inputCoins.map(Self.objectReference)
                        $0.recipients = [recipient]
                        $0.amounts = [prepared.amountAtomic]
                        $0.gas = Self.objectReference(gas)
                    }
                }
            },
            coin: .sui
        )
        guard output.error == .ok,
              !output.unsignedTx.isEmpty,
              !output.signature.isEmpty
        else {
            throw SendTransactionSubmissionError.signing(
                code: String(output.error.rawValue),
                message: SendTransactionSubmissionError
                    .sanitizedMessage(output.errorMessage)
            )
        }
        let localDigest: String
        do {
            localDigest = try SuiTransactionDigest.make(
                transactionDataBCS: output.unsignedTx
            )
        } catch {
            throw SendTransactionSubmissionError.signing(
                code: "invalid_unsigned_transaction",
                message: WalletLocalization.string(
                    "send.submit.error.sui_signing_output"
                )
            )
        }
        var receipt = SendTransactionReceipt(
            transactionHash: localDigest,
            accountID: material.account.id,
            networkID: SuiConstants.networkID,
            fromAddress: sender,
            toAddress: recipient,
            assetID: draft.asset.id,
            assetSymbol: draft.asset.symbol,
            amount: SendDecimalAmount.userUnits(
                fromAtomicUnits: String(prepared.amountAtomic),
                decimals: draft.asset.decimals
            ),
            amountAtomic: String(prepared.amountAtomic),
            networkFee: SendDecimalAmount.userUnits(
                fromAtomicUnits: String(gasBudget),
                decimals: SuiConstants.decimals
            ),
            networkFeeAtomic: String(gasBudget),
            networkFeeSymbol: SuiConstants.nativeSymbol,
            submittedAt: Date()
        )

        receipt.spendResources = prepared.spendResources
        try await reservation.markSubmissionStarted(receipt: receipt)
        let providerDigest: String
        do {
            providerDigest = try await api.execute(
                transactionDataBCS: output.unsignedTx,
                signature: output.signature
            )
        } catch let error as SuiProviderError {
            switch error {
            case let .executionFailed(_, digest):
                guard digest == receipt.transactionHash else {
                    throw SendTransactionSubmissionError
                        .broadcastOutcomeUnknown(
                            networkID: SuiConstants.networkID,
                            code: "failed_execution_digest_mismatch",
                            receipt: receipt
                        )
                }
                throw SendTransactionSubmissionError
                    .broadcastExecutionFailed(
                        code: error.diagnosticDescription,
                        message: WalletLocalization.string(
                            "send.submit.error.sui_execution_failed"
                        ),
                        receipt: receipt
                    )
            case .submissionUnavailable:
                throw SendTransactionSubmissionError.broadcastRejected(
                    code: error.diagnosticDescription,
                    message: WalletLocalization.string("send.submit.error.sui_provider_unavailable"),
                    receipt: receipt
                )
            case .grpc(status: 3), .providerRejected:
                throw SendTransactionSubmissionError.broadcastRejected(
                    code: error.diagnosticDescription,
                    message: WalletLocalization.string(
                        "send.submit.error.sui_rejected"
                    ),
                    receipt: receipt
                )
            case let .http(status, _) where
                (400..<500).contains(status)
                    && status != 408 && status != 429:
                throw SendTransactionSubmissionError.broadcastRejected(
                    code: error.diagnosticDescription,
                    message: WalletLocalization.string(
                        "send.submit.error.sui_rejected"
                    ),
                    receipt: receipt
                )
            default:
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: SuiConstants.networkID,
                        code: error.diagnosticDescription,
                        receipt: receipt
                    )
            }
        } catch {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SuiConstants.networkID,
                    code: SendTransactionSubmissionError
                        .sanitizedErrorType(error),
                    receipt: receipt
                )
        }
        guard providerDigest == localDigest else {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SuiConstants.networkID,
                    code: "broadcast_digest_mismatch",
                    receipt: receipt
                )
        }
        return receipt
    }

    private func tokenObjects(
        address: String,
        coinType: String?
    ) async throws -> [SuiCoinObject]? {
        guard let coinType else { return nil }
        return try await api.coinObjects(
            address: address,
            coinType: coinType
        )
    }

    private static func prepareNative(
        gasObjects: [SuiCoinObject],
        requestedAtomic: UInt64,
        usesMaximumBalance: Bool,
        gasBudget: UInt64
    ) throws -> PreparedSuiTransfer {
        let sorted = gasObjects.sorted {
            $0.atomicBalance > $1.atomicBalance
        }
        let total = try sum(sorted)
        let amount = try SendNativeTransferAmountResolver.uint64(
            requestedAtomic: requestedAtomic,
            balanceAtomic: total,
            unavailableAtomic: gasBudget,
            usesMaximumBalance: usesMaximumBalance
        )
        let required = amount + gasBudget
        let selected = try select(
            sorted,
            covering: required
        )
        return PreparedSuiTransfer(
            amountAtomic: amount,
            kind: .native(inputCoins: selected)
        )
    }

    private static func prepareToken(
        tokenObjects: [SuiCoinObject],
        gasObjects: [SuiCoinObject],
        requestedAtomic: UInt64,
        usesMaximumBalance: Bool,
        gasBudget: UInt64
    ) throws -> PreparedSuiTransfer {
        let tokenObjects = tokenObjects.sorted {
            $0.atomicBalance > $1.atomicBalance
        }
        let tokenTotal = try sum(tokenObjects)
        let amount = usesMaximumBalance ? tokenTotal : requestedAtomic
        guard amount > 0, amount <= tokenTotal else {
            throw SendTransactionSubmissionError
                .insufficientAssetBalance
        }
        guard let gas = gasObjects
            .filter({ $0.atomicBalance >= gasBudget })
            .min(by: { $0.atomicBalance < $1.atomicBalance })
        else {
            throw SendTransactionSubmissionError
                .insufficientNetworkFeeBalance
        }
        return PreparedSuiTransfer(
            amountAtomic: amount,
            kind: .token(
                inputCoins: try select(tokenObjects, covering: amount),
                gas: gas
            )
        )
    }

    private static func select(
        _ objects: [SuiCoinObject],
        covering required: UInt64
    ) throws -> [SuiCoinObject] {
        var selected: [SuiCoinObject] = []
        var total: UInt64 = 0
        for object in objects {
            selected.append(object)
            let next = total.addingReportingOverflow(object.atomicBalance)
            guard !next.overflow else {
                throw SendTransactionSubmissionError.amountOutOfRange
            }
            total = next.partialValue
            if total >= required { return selected }
        }
        throw SendTransactionSubmissionError.insufficientAssetBalance
    }

    private static func sum(
        _ objects: [SuiCoinObject]
    ) throws -> UInt64 {
        try objects.reduce(0) { result, object in
            let next = result.addingReportingOverflow(
                object.atomicBalance
            )
            guard !next.overflow else {
                throw SendTransactionSubmissionError.amountOutOfRange
            }
            return next.partialValue
        }
    }

    private static func objectReference(
        _ object: SuiCoinObject
    ) -> SuiObjectRef {
        .with {
            $0.objectID = object.objectID
            $0.version = object.version
            $0.objectDigest = object.digest
        }
    }

    private static func validAddress(_ value: String) -> String? {
        SuiCoinType.validatedAccountAddress(value)
    }

    private static func providerError(
        _ error: SuiProviderError
    ) -> SendTransactionSubmissionError {
        .provider(
            networkID: SuiConstants.networkID,
            code: error.diagnosticDescription,
            message: WalletLocalization.string(
                "send.submit.error.sui_provider"
            )
        )
    }
}

private struct PreparedSuiTransfer: Sendable {
    enum Kind: Sendable {
        case native(inputCoins: [SuiCoinObject])
        case token(inputCoins: [SuiCoinObject], gas: SuiCoinObject)
    }

    let amountAtomic: UInt64
    let kind: Kind

    var spendResources: Set<SendSpendResource> {
        switch kind {
        case let .native(inputCoins):
            Set(inputCoins.map(SendSpendResource.object))
        case let .token(inputCoins, gas):
            Set((inputCoins + [gas]).map(SendSpendResource.object))
        }
    }
}
