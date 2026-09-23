import Foundation
import WalletCore

struct SendTronTransactionService: Sendable {
    private let api: SendTronAPIClient

    init(api: SendTronAPIClient = SendTronAPIClient()) {
        self.api = api
    }

    func estimatedNetworkFeeAtomic(
        draft: SendDraft,
        fee: SendResolvedNetworkFee
    ) async throws -> String {
        try await estimatedNetworkFee(draft: draft, fee: fee).atomicAmount
    }

    func estimatedNetworkFee(
        draft: SendDraft,
        fee: SendResolvedNetworkFee
    ) async throws -> SendNetworkFeeEstimate {
        guard draft.asset.networkID == TronConstants.networkID else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        guard let sourceAddress = draft.asset.sourceAddress else {
            throw SendTransactionSubmissionError.accountUnavailable
        }
        let ownerAddress = sourceAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let recipientAddress = draft.recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard TronValueParser.isValidMainnetAddress(ownerAddress) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        guard TronValueParser.isValidMainnetAddress(recipientAddress) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        try SendSelfTransferPolicy.validate(draft: draft, sourceAddress: ownerAddress)
        guard let requestedAmount = draft.amount else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        let requestedAtomic = try SendAtomicAmount.fromUserUnits(
            requestedAmount,
            decimals: draft.asset.decimals
        )
        async let balanceValue = api.accountBalance(address: ownerAddress)
        async let resourceValue = api.accountResource(address: ownerAddress)
        let parameters = try fee.resolvedTronParameters(isCustom: !draft.feePolicy.requiresLiveQuote)
        async let recipientActiveValue = nativeRecipientActive(
            contractAddress: draft.asset.contractAddress,
            recipientAddress: recipientAddress
        )
        let (nativeBalance, resource, recipientActive) = try await (
            balanceValue, resourceValue, recipientActiveValue
        )
        guard fee.model == .tronProtocol else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("wrong_tron_fee_model")
        }

        let prepared: PreparedTransaction
        if let contractAddress = draft.asset.contractAddress {
            prepared = try await prepareToken(
                draft: draft,
                ownerAddress: ownerAddress,
                recipientAddress: recipientAddress,
                contractAddress: contractAddress,
                requestedAtomic: requestedAtomic,
                resource: resource,
                parameters: parameters,
                fee: fee
            )
        } else {
            prepared = try await prepareNative(
                draft: draft,
                ownerAddress: ownerAddress,
                recipientAddress: recipientAddress,
                requestedAtomic: requestedAtomic,
                nativeBalance: nativeBalance,
                resource: resource,
                parameters: parameters,
                recipientActive: recipientActive == true
            )
        }
        try Self.validateCustomFeeBudget(
            fee,
            estimatedFeeAtomic: prepared.estimatedFee
        )
        let estimate = SendNetworkFeeEstimate(
            atomicAmount: String(prepared.estimatedFee),
            nativeDecimals: 6,
            nativeTransferAmountAtomic: draft.asset.isNative ? prepared.amountAtomic : nil
        )
        // The fee limit is an execution cap, not a balance requirement. Only
        // paid energy after resources plus serialized bandwidth consumes TRX.
        guard nativeBalance >= prepared.estimatedFee else {
            guard let network = ReceiveNetworkCatalog.catalogNetwork(for: draft.asset.networkID) else {
                throw SendTransactionSubmissionError.unsupportedNetwork
            }
            throw SendReviewFundingIssue(
                funding: SendReviewFunding(address: ownerAddress, network: network),
                cause: .insufficientNetworkFeeBalance, estimate: estimate
            )
        }
        return estimate
    }

    func submit(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        reservation: any SendSpendSubmissionReserving
    ) async throws -> SendTransactionReceipt {
        guard draft.asset.networkID == TronConstants.networkID else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        let recipientAddress = draft.recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let ownerAddress = material.account.address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard TronValueParser.isValidMainnetAddress(recipientAddress) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard TronValueParser.isValidMainnetAddress(ownerAddress) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        try SendSelfTransferPolicy.validate(draft: draft, sourceAddress: ownerAddress)
        guard let requestedAmount = draft.amount else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        let requestedAtomic = try SendAtomicAmount.fromUserUnits(
            requestedAmount,
            decimals: draft.asset.decimals
        )

        async let balanceValue = api.accountBalance(
            address: ownerAddress
        )
        async let resourceValue = api.accountResource(
            address: ownerAddress
        )
        let resolvedFee = try SendSubmissionNetworkFee.resolve(draft: draft)
        let parameters = try resolvedFee.resolvedTronParameters(isCustom: !draft.feePolicy.requiresLiveQuote)
        async let recipientActiveValue = nativeRecipientActive(
            contractAddress: draft.asset.contractAddress,
            recipientAddress: recipientAddress
        )
        let nativeBalance: UInt64
        let resource: SendTronAccountResource
        let recipientActive: Bool?
        (nativeBalance, resource, recipientActive) = try await (
            balanceValue, resourceValue, recipientActiveValue
        )
        guard resolvedFee.model == .tronProtocol else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("wrong_tron_fee_model")
        }

        let prepared: PreparedTransaction
        if let contractAddress = draft.asset.contractAddress {
            prepared = try await prepareToken(
                draft: draft,
                ownerAddress: ownerAddress,
                recipientAddress: recipientAddress,
                contractAddress: contractAddress,
                requestedAtomic: requestedAtomic,
                resource: resource,
                parameters: parameters,
                fee: resolvedFee
            )
        } else {
            prepared = try await prepareNative(
                draft: draft,
                ownerAddress: ownerAddress,
                recipientAddress: recipientAddress,
                requestedAtomic: requestedAtomic,
                nativeBalance: nativeBalance,
                resource: resource,
                parameters: parameters,
                recipientActive: recipientActive == true
            )
        }
        // Recheck the freshly prepared cost before any signing or broadcast.
        guard nativeBalance >= prepared.estimatedFee else {
            throw SendTransactionSubmissionError.insufficientNetworkFeeBalance
        }
        try Self.validateCustomFeeBudget(
            resolvedFee,
            estimatedFeeAtomic: prepared.estimatedFee
        )

        let output: TronSigningOutput = AnySigner.sign(
            input: TronSigningInput.with {
                $0.rawJson = prepared.unsigned.json
                $0.privateKey = material.privateKey
            },
            coin: .tron
        )
        let signedTransactionID = output.id.hexString.lowercased()
        guard output.error == .ok,
              !output.json.isEmpty,
              signedTransactionID == prepared
                .unsigned.transactionID
        else {
            throw SendTransactionSubmissionError.signing(
                code: String(output.error.rawValue),
                message: SendTransactionSubmissionError
                    .sanitizedMessage(output.errorMessage)
            )
        }
        var receipt = SendTransactionReceipt(
            transactionHash: signedTransactionID,
            accountID: material.account.id,
            networkID: TronConstants.networkID,
            fromAddress: ownerAddress,
            toAddress: recipientAddress,
            assetID: draft.asset.id,
            assetSymbol: draft.asset.symbol,
            amount: SendDecimalAmount.userUnits(
                fromAtomicUnits: prepared.amountAtomic,
                decimals: draft.asset.decimals
            ),
            amountAtomic: prepared.amountAtomic,
            networkFee: SendDecimalAmount.userUnits(
                fromAtomicUnits: String(prepared.estimatedFee),
                decimals: 6
            ),
            networkFeeAtomic: String(prepared.estimatedFee),
            networkFeeSymbol: "TRX",
            submittedAt: Date()
        )
        receipt.spendResources = [SendSpendResource(kind: .transactionID, value: receipt.transactionHash.lowercased())]
        try await reservation.markSubmissionStarted(receipt: receipt)
        let broadcastHash: String
        do {
            broadcastHash = try await api.broadcast(
                signedJSON: output.json
            )
        } catch let error as SendTransactionSubmissionError {
            switch error {
            case let .broadcastRejected(code, message, _):
                throw SendTransactionSubmissionError.broadcastRejected(
                    code: code,
                    message: message,
                    receipt: receipt
                )
            case let .broadcastOutcomeUnknown(networkID, code, _):
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: networkID,
                        code: code,
                        receipt: receipt
                    )
            default:
                throw error
            }
        }
        guard broadcastHash == signedTransactionID else {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: TronConstants.networkID,
                    code: "broadcast_hash_mismatch",
                    receipt: receipt
                )
        }
        return receipt
    }

    private func prepareNative(
        draft: SendDraft,
        ownerAddress: String,
        recipientAddress: String,
        requestedAtomic: String,
        nativeBalance: UInt64,
        resource: SendTronAccountResource,
        parameters: SendTronProtocolParameters,
        recipientActive: Bool
    ) async throws -> PreparedTransaction {
        let requested = try SendAtomicAmount.uint64(requestedAtomic)
        guard requested > 0 else { throw SendTransactionSubmissionError.invalidAmount }
        // TransferContract validation requires amount + account creation fee
        // before the node returns an unsigned transaction. Reserve that known
        // cost first; serialized bandwidth is then priced by the loop below.
        var reservedFee = recipientActive ? 0 : parameters.accountCreationFee
        var candidateAmount = try SendNativeTransferAmountResolver.uint64(
            requestedAtomic: requested,
            balanceAtomic: nativeBalance,
            unavailableAtomic: reservedFee,
            usesMaximumBalance: draft.usesMaximumBalance
        )
        for _ in 0..<4 {
            guard candidateAmount > 0 else {
                throw SendTransactionSubmissionError
                    .insufficientNetworkFeeBalance
            }
            let unsigned = try await api.createNativeTransfer(
                ownerAddress: ownerAddress,
                recipientAddress: recipientAddress,
                amountAtomic: candidateAmount
            )
            let estimatedFee = try Self.nativeTransferFee(
                transaction: unsigned,
                resource: resource,
                parameters: parameters,
                recipientActive: recipientActive
            )
            // Serialized amount length can change bandwidth cost. Retaining
            // the largest observed fee prevents oscillation at varint boundaries.
            reservedFee = max(reservedFee, estimatedFee)
            let adjustedAmount = try
                SendNativeTransferAmountResolver.uint64(
                    requestedAtomic: requested,
                    balanceAtomic: nativeBalance,
                    unavailableAtomic: reservedFee,
                    usesMaximumBalance: draft.usesMaximumBalance
                )
            if adjustedAmount == candidateAmount {
                return PreparedTransaction(
                    unsigned: unsigned,
                    amountAtomic: String(candidateAmount),
                    estimatedFee: reservedFee
                )
            }
            candidateAmount = adjustedAmount
        }
        throw SendTransactionSubmissionError
            .feeQuoteUnavailable("tron_max_fee_did_not_converge")
    }

    private func prepareToken(
        draft: SendDraft,
        ownerAddress: String,
        recipientAddress: String,
        contractAddress: String,
        requestedAtomic: String,
        resource: SendTronAccountResource,
        parameters: SendTronProtocolParameters,
        fee: SendResolvedNetworkFee
    ) async throws -> PreparedTransaction {
        let normalizedContractAddress = contractAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard TronValueParser.isValidMainnetAddress(
            normalizedContractAddress
        ) else {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        let tokenBalance = try await api.trc20Balance(
            ownerAddress: ownerAddress,
            contractAddress: normalizedContractAddress
        )
        let amount = draft.usesMaximumBalance
            ? tokenBalance
            : requestedAtomic
        guard amount != "0",
              SendAtomicAmount.compare(
                  amount,
                  tokenBalance
              ) != .orderedDescending
        else {
            throw SendTransactionSubmissionError
                .insufficientAssetBalance
        }
        let estimatedEnergy = try await api.estimatedEnergy(
            ownerAddress: ownerAddress,
            contractAddress: normalizedContractAddress,
            recipientAddress: recipientAddress,
            amountAtomic: amount
        )

        let paidEnergy = estimatedEnergy > resource.energyRemaining
            ? estimatedEnergy - resource.energyRemaining : 0
        let estimatedEnergyFee = try Self.multiply(
            paidEnergy,
            parameters.energyPrice
        )
        let customFeeLimit: UInt64?
        if draft.feePolicy.customValue?.model == .tronFeeLimit {
            customFeeLimit = try SendAtomicAmount.uint64(
                fee.primaryValue
            )
        } else {
            customFeeLimit = nil
        }
        let feeLimit = try Self.energyFeeLimit(
            estimatedEnergy: estimatedEnergy,
            energyPrice: parameters.energyPrice,
            customValue: customFeeLimit
        )
        let unsigned = try await api.createTRC20Transfer(
            ownerAddress: ownerAddress,
            recipientAddress: recipientAddress,
            contractAddress: normalizedContractAddress,
            amountAtomic: amount,
            feeLimit: feeLimit
        )
        let bandwidthFee = try Self.paidBandwidthFee(
            transaction: unsigned,
            resource: resource,
            parameters: parameters,
            createsAccount: false
        )
        let totalFee = estimatedEnergyFee
            .addingReportingOverflow(bandwidthFee)
        guard !totalFee.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return PreparedTransaction(
            unsigned: unsigned,
            amountAtomic: amount,
            estimatedFee: totalFee.partialValue
        )
    }

    private func nativeRecipientActive(
        contractAddress: String?,
        recipientAddress: String
    ) async throws -> Bool? {
        guard contractAddress == nil else { return nil }
        return try await api.accountExists(address: recipientAddress)
    }

    static func nativeTransferFee(
        transaction: SendTronUnsignedTransaction,
        resource: SendTronAccountResource,
        parameters: SendTronProtocolParameters,
        recipientActive: Bool
    ) throws -> UInt64 {
        let bandwidthFee = try paidBandwidthFee(
            transaction: transaction,
            resource: resource,
            parameters: parameters,
            createsAccount: !recipientActive
        )
        guard !recipientActive else { return bandwidthFee }
        let total = bandwidthFee.addingReportingOverflow(
            parameters.accountCreationFee
        )
        guard !total.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return total.partialValue
    }

    static func paidBandwidthFee(
        transaction: SendTronUnsignedTransaction,
        resource: SendTronAccountResource,
        parameters: SendTronProtocolParameters,
        createsAccount: Bool
    ) throws -> UInt64 {
        let transactionBytes = try signedTransactionBandwidthBytes(
            rawDataBytes: transaction.rawDataBytes
        )
        if createsAccount {
            let requiredBandwidth = try multiply(
                transactionBytes,
                parameters.accountCreationBandwidthRate
            )
            return resource.stakedBandwidthRemaining >= requiredBandwidth
                ? 0
                : parameters.accountCreationBandwidthFee
        }
        if resource.stakedBandwidthRemaining >= transactionBytes
            || resource.freeBandwidthRemaining >= transactionBytes {
            return 0
        }
        return try multiply(transactionBytes, parameters.bandwidthPrice)
    }

    static func signedTransactionBandwidthBytes(
        rawDataBytes: Int
    ) throws -> UInt64 {
        guard rawDataBytes >= 0 else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        let rawBytes = UInt64(rawDataBytes)
        let protobufOverhead = UInt64(1)
            + protobufVarintByteCount(rawBytes)
            + 1
            + 1
            + 65
            + 64
        let total = rawBytes.addingReportingOverflow(protobufOverhead)
        guard !total.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return total.partialValue
    }

    static func energyFeeLimit(
        estimatedEnergy: UInt64,
        energyPrice: UInt64,
        customValue: UInt64?
    ) throws -> UInt64 {
        let fullEnergyFee = try multiply(estimatedEnergy, energyPrice)
        if let customValue {
            guard customValue >= fullEnergyFee else {
                throw SendTransactionSubmissionError
                    .feeQuoteUnavailable("tron_fee_limit_too_low")
            }
            return customValue
        }
        return try buffered(fullEnergyFee)
    }

    static func validateCustomFeeBudget(
        _ fee: SendResolvedNetworkFee,
        estimatedFeeAtomic: UInt64
    ) throws {
        guard let budget = fee.totalBudgetAtomic else { return }
        guard let budgetValue = UInt64(budget) else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("invalid_custom_fee")
        }
        guard estimatedFeeAtomic <= budgetValue else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("custom_fee_budget_below_required")
        }
    }

    private static func protobufVarintByteCount(
        _ value: UInt64
    ) -> UInt64 {
        var remaining = value
        var count: UInt64 = 1
        while remaining >= 0x80 {
            remaining >>= 7
            count += 1
        }
        return count
    }

    private static func multiply(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) throws -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result.partialValue
    }

    private static func buffered(_ value: UInt64) throws -> UInt64 {
        let buffer = max(value / 5, 1_000_000)
        let result = value.addingReportingOverflow(buffer)
        guard !result.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return max(result.partialValue, 1_000_000)
    }
}

private struct PreparedTransaction: Sendable {
    let unsigned: SendTronUnsignedTransaction
    let amountAtomic: String
    let estimatedFee: UInt64
}

enum SendTronBroadcastErrorClassifier {
    static func outcomeMayBeUnknown(code: String) -> Bool {
        let normalized = code.uppercased().map {
            $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_"
        }
        let compact = String(normalized)
            .split(separator: "_")
            .joined(separator: "_")
        return [
            "SERVER_BUSY",
            "NO_CONNECTION",
            "NOT_ENOUGH_EFFECTIVE_CONNECTION",
            "BLOCK_UNSOLIDIFIED",
            "OTHER_ERROR"
        ].contains(compact)
    }
}
