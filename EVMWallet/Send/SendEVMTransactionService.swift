import Foundation
import WalletCore

struct SendEVMTransactionService: Sendable {
    private let injectedRPC: SendEVMRPCClient?

    init(rpc: SendEVMRPCClient? = nil) {
        injectedRPC = rpc
    }

    func submit(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        reservation: any SendSpendSubmissionReserving
    ) async throws -> SendTransactionReceipt {
        guard let network = ReceiveNetworkCatalog.network(
            for: draft.asset.networkID
        ), network.chainID > 0 else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        let recipientAddress = draft.recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let senderAddress = material.account.address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let contractAddress = draft.asset.contractAddress?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard SendAddressValidator.isValidEVMAddress(
            recipientAddress
        ) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard SendAddressValidator.isValidEVMAddress(senderAddress) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        if let contractAddress,
           !SendAddressValidator.isValidEVMAddress(contractAddress) {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        if let contractAddress,
           recipientAddress.caseInsensitiveCompare(contractAddress)
            == .orderedSame {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard let requestedAmount = draft.amount else {
            throw SendTransactionSubmissionError.invalidAmount
        }

        let rpc = try injectedRPC ?? SendEVMRPCClient(
            networkID: draft.asset.networkID
        )
        let requestedAtomic = try SendAtomicAmount.fromUserUnits(
            requestedAmount,
            decimals: draft.asset.decimals
        )
        let fee = try SendSubmissionNetworkFee.resolve(draft: draft)

        let requestedTransferData = try Self.erc20TransferData(
            recipient: recipientAddress,
            amountAtomic: requestedAtomic,
            contractAddress: contractAddress
        )
        let transactionTarget = contractAddress ?? recipientAddress

        // Metadata is independent of nonce, balances and gas simulation, but
        // must still match the reviewed asset before any signing or submission.
        async let metadataValidation: Void = validateTokenMetadata(
            rpc: rpc, contractAddress: contractAddress,
            expectedDecimals: draft.asset.decimals
        )
        async let chainIDValue = rpc.chainID()
        async let nonceValue = rpc.transactionCount(
            address: senderAddress
        )
        async let nativeBalanceValue = rpc.nativeBalance(
            address: senderAddress
        )
        async let gasEstimateValue = initialGasEstimate(
            rpc: rpc,
            draft: draft,
            requestedAtomic: requestedAtomic,
            senderAddress: senderAddress,
            transactionTarget: transactionTarget,
            transferData: requestedTransferData,
            fee: fee
        )
        async let tokenBalanceValue: String? = tokenBalance(
            rpc: rpc,
            contractAddress: contractAddress,
            ownerAddress: senderAddress
        )
        try await metadataValidation
        let (
            chainIDHex,
            nonceHex,
            nativeBalanceHex,
            gasEstimateHex,
            tokenBalanceHex
        ) = try await (
            chainIDValue,
            nonceValue,
            nativeBalanceValue,
            gasEstimateValue,
            tokenBalanceValue
        )

        let actualChainID = try SendAtomicAmount
            .decimalFromHexQuantity(chainIDHex)
        guard actualChainID == String(network.chainID) else {
            throw SendTransactionSubmissionError.provider(
                networkID: draft.asset.networkID,
                code: "chain_id_mismatch",
                message: WalletLocalization.string(
                    "send.submit.error.provider_wrong_chain"
                )
            )
        }
        let nonce = try await reservation.nextSequence(
            networkValue: SendAtomicAmount.decimalFromHexQuantity(nonceHex)
        )
        let nativeBalance = try SendAtomicAmount
            .decimalFromHexQuantity(nativeBalanceHex)
        let feePerGas = fee.primaryValue
        if fee.model == .evmEIP1559,
           let priorityFee = fee.secondaryValue,
           SendAtomicAmount.compare(
               feePerGas,
               priorityFee
           ) == .orderedAscending {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("priority_exceeds_maximum")
        }

        let tokenAmountAtomic: String?
        if draft.asset.isNative {
            tokenAmountAtomic = nil
        } else {
            guard let tokenBalanceHex else {
                throw SendTransactionSubmissionError.unsupportedAsset
            }
            let tokenBalance = try SendAtomicAmount
                .decimalFromABIUnsignedInteger(tokenBalanceHex)
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
            tokenAmountAtomic = amount
        }

        let gasLimit: UInt64
        if draft.asset.isNative {
            gasLimit = try await Self.maximumNativeGasLimit(
                rpc: rpc,
                nativeBalance: nativeBalance,
                fee: fee,
                senderAddress: senderAddress,
                transactionTarget: transactionTarget,
                networkID: draft.asset.networkID,
                requestedAtomic: draft.usesMaximumBalance ? nil : requestedAtomic
            )
        } else if draft.usesMaximumBalance,
                  let tokenAmountAtomic {
            let transferData = try Self.erc20TransferData(
                recipient: recipientAddress,
                amountAtomic: tokenAmountAtomic,
                contractAddress: contractAddress
            )
            let fields = try Self.gasEstimateFeeFields(fee)
            let estimateHex = try await rpc.estimateGas(
                from: senderAddress,
                to: transactionTarget,
                value: "0x0",
                data: transferData,
                gasPrice: fields.gasPrice,
                maximumFeePerGas: fields.maximumFeePerGas,
                priorityFeePerGas: fields.priorityFeePerGas
            )
            let estimate = try SendAtomicAmount.uint64(
                SendAtomicAmount.decimalFromHexQuantity(estimateHex)
            )
            gasLimit = try Self.bufferedGasLimit(estimate)
        } else {
            guard let gasEstimateHex else {
                throw SendTransactionSubmissionError.provider(
                    networkID: draft.asset.networkID,
                    code: "missing_gas_estimate",
                    message: WalletLocalization.string(
                        "send.submit.error.provider_invalid_response"
                    )
                )
            }
            let estimatedGas = try SendAtomicAmount.uint64(
                SendAtomicAmount.decimalFromHexQuantity(gasEstimateHex)
            )
            gasLimit = try Self.bufferedGasLimit(estimatedGas)
        }
        let executionFee = try Self.maximumFeeAtomic(
            feePerGas: feePerGas,
            gasLimit: gasLimit,
            networkID: draft.asset.networkID
        )
        let rollupReserve = try await SendEVMRollupFee.reserve(
            networkID: draft.asset.networkID,
            isToken: !draft.asset.isNative, gasLimit: gasLimit,
            call: { try await rpc.callContract(contractAddress: $0, data: $1) }
        )
        let maximumFee = SendAtomicAmount.add(executionFee, rollupReserve)
        try Self.validateCustomFeeBudget(
            fee,
            maximumFeeAtomic: maximumFee
        )

        let amountAtomic: String
        if draft.asset.isNative {
            amountAtomic = try SendNativeTransferAmountResolver.resolve(
                requestedAtomic: requestedAtomic,
                balanceAtomic: nativeBalance,
                unavailableAtomic: maximumFee,
                usesMaximumBalance: draft.usesMaximumBalance
            )
        } else {
            guard SendAtomicAmount.compare(
                nativeBalance,
                maximumFee
            ) != .orderedAscending else {
                throw SendTransactionSubmissionError
                    .insufficientNetworkFeeBalance
            }
            guard let tokenAmountAtomic else {
                throw SendTransactionSubmissionError.unsupportedAsset
            }
            amountAtomic = tokenAmountAtomic
        }

        let rawTransaction = try sign(
            draft: draft,
            material: material,
            network: network,
            amountAtomic: amountAtomic,
            nonce: nonce,
            gasLimit: gasLimit,
            fee: fee,
            recipientAddress: recipientAddress,
            contractAddress: contractAddress
        )
        let localTransactionHash = try Self
            .locallyDerivedTransactionHash(
                from: rawTransaction,
                networkID: draft.asset.networkID
            )
        var receipt = SendTransactionReceipt(
            transactionHash: "0x"
                + localTransactionHash.hexString.lowercased(),
            accountID: material.account.id,
            networkID: draft.asset.networkID,
            fromAddress: senderAddress,
            toAddress: recipientAddress,
            assetID: draft.asset.id,
            assetSymbol: draft.asset.symbol,
            amount: SendDecimalAmount.userUnits(
                fromAtomicUnits: amountAtomic,
                decimals: draft.asset.decimals
            ),
            amountAtomic: amountAtomic,
            networkFee: SendDecimalAmount.userUnits(
                fromAtomicUnits: maximumFee,
                decimals: 18
            ),
            networkFeeAtomic: maximumFee,
            networkFeeSymbol: network.symbol,
            submittedAt: Date()
        )
        receipt.spendResources = [.sequence(nonce)]
        try await reservation.markSubmissionStarted(receipt: receipt)
        let providerHash: String
        do {
            providerHash = try await rpc.broadcast(
                rawTransaction: "0x" + rawTransaction.hexString
            )
        } catch is CancellationError {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: draft.asset.networkID,
                code: "cancelled_after_broadcast_started",
                receipt: receipt
            )
        } catch let error as SendTransactionSubmissionError {
            if Self.isAlreadyKnownBroadcastRejection(error) {
                return receipt
            }
            throw error.attachingTransactionEvidence(receipt)
        } catch {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: draft.asset.networkID,
                code: SendTransactionSubmissionError
                    .sanitizedErrorType(error),
                receipt: receipt
            )
        }
        do {
            _ = try Self.verifiedBroadcastHash(
                providerHash,
                locallyDerivedHash: localTransactionHash,
                networkID: draft.asset.networkID
            )
        } catch let error as SendTransactionSubmissionError {
            throw error.attachingTransactionEvidence(receipt)
        }
        return receipt
    }

    private func validateTokenMetadata(
        rpc: SendEVMRPCClient,
        contractAddress: String?,
        expectedDecimals: Int
    ) async throws {
        guard let contractAddress else { return }
        let decimals = try await rpc.tokenDecimals(contractAddress: contractAddress)
        guard decimals == expectedDecimals else {
            throw SendTransactionSubmissionError.tokenMetadataMismatch
        }
    }

    static func maximumFeeAtomic(
        feePerGas: String,
        gasLimit: UInt64,
        networkID: String
    ) throws -> String {
        do {
            let result = try SendAtomicAmount.multiply(
                feePerGas,
                by: gasLimit
            )
            return result
        } catch let error as SendTransactionSubmissionError {
            throw error
        }
    }

    static func validateCustomFeeBudget(
        _ fee: SendResolvedNetworkFee,
        maximumFeeAtomic: String
    ) throws {
        guard let budget = fee.totalBudgetAtomic else { return }
        guard SendAtomicAmount.isCanonical(maximumFeeAtomic),
              SendAtomicAmount.isCanonical(budget) else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("invalid_custom_fee")
        }
        guard SendAtomicAmount.compare(
            maximumFeeAtomic,
            budget
        ) != .orderedDescending else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("custom_fee_budget_below_required")
        }
    }

    private func tokenBalance(
        rpc: SendEVMRPCClient,
        contractAddress: String?,
        ownerAddress: String
    ) async throws -> String? {
        guard let contract = contractAddress else {
            return nil
        }
        return try await rpc.tokenBalance(
            ownerAddress: ownerAddress,
            contractAddress: contract
        )
    }

    private func initialGasEstimate(
        rpc: SendEVMRPCClient,
        draft: SendDraft,
        requestedAtomic: String,
        senderAddress: String,
        transactionTarget: String,
        transferData: String?,
        fee: SendResolvedNetworkFee
    ) async throws -> String? {
        guard !draft.usesMaximumBalance, !draft.asset.isNative else {
            return nil
        }
        let value = draft.asset.isNative
            ? try SendAtomicAmount.hexQuantity(requestedAtomic)
            : "0x0"
        let fields = try Self.gasEstimateFeeFields(fee)
        return try await rpc.estimateGas(
            from: senderAddress,
            to: transactionTarget,
            value: value,
            data: transferData,
            gasPrice: fields.gasPrice,
            maximumFeePerGas: fields.maximumFeePerGas,
            priorityFeePerGas: fields.priorityFeePerGas
        )
    }

    static func maximumNativeGasLimit(
        rpc: SendEVMRPCClient,
        nativeBalance: String,
        fee: SendResolvedNetworkFee,
        senderAddress: String,
        transactionTarget: String,
        networkID: String,
        requestedAtomic: String? = nil
    ) async throws -> UInt64 {
        // Even with gasPrice zero, rollups charge for posting the transaction.
        // Sending the full balance in the probe can fail before gas is known.
        let probeReserve = try await SendEVMRollupFee.reserve(
            networkID: networkID, isToken: false, gasLimit: 25_200,
            call: { try await rpc.callContract(contractAddress: $0, data: $1) }
        )
        guard SendAtomicAmount.compare(nativeBalance, probeReserve) == .orderedDescending else {
            throw SendTransactionSubmissionError.insufficientNetworkFeeBalance
        }
        let probeAmount = try SendNativeTransferAmountResolver.resolve(
            requestedAtomic: requestedAtomic ?? nativeBalance, balanceAtomic: nativeBalance,
            unavailableAtomic: probeReserve, usesMaximumBalance: requestedAtomic == nil
        )
        let probeHex = try await rpc.estimateGas(
            from: senderAddress,
            to: transactionTarget,
            value: try SendAtomicAmount.hexQuantity(probeAmount),
            data: nil,
            gasPrice: "0x0"
        )
        let probe = try SendAtomicAmount.uint64(
            SendAtomicAmount.decimalFromHexQuantity(probeHex)
        )
        var gasLimit = try bufferedGasLimit(probe)
        let fields = try Self.gasEstimateFeeFields(fee)
        for _ in 0..<4 {
            let executionFee = try Self.maximumFeeAtomic(
                feePerGas: fee.primaryValue,
                gasLimit: gasLimit,
                networkID: networkID
            )
            let rollupReserve = try await SendEVMRollupFee.reserve(
                networkID: networkID, isToken: false, gasLimit: gasLimit,
                call: { try await rpc.callContract(contractAddress: $0, data: $1) }
            )
            let maximumFee = SendAtomicAmount.add(executionFee, rollupReserve)
            try Self.validateCustomFeeBudget(
                fee,
                maximumFeeAtomic: maximumFee
            )
            guard SendAtomicAmount.compare(nativeBalance, maximumFee)
                    == .orderedDescending else {
                throw SendTransactionSubmissionError
                    .insufficientNetworkFeeBalance
            }
            let candidate = try SendNativeTransferAmountResolver.resolve(
                requestedAtomic: requestedAtomic ?? nativeBalance, balanceAtomic: nativeBalance,
                unavailableAtomic: maximumFee, usesMaximumBalance: requestedAtomic == nil
            )
            let estimateHex = try await rpc.estimateGas(
                from: senderAddress,
                to: transactionTarget,
                value: try SendAtomicAmount.hexQuantity(candidate),
                data: nil,
                gasPrice: fields.gasPrice,
                maximumFeePerGas: fields.maximumFeePerGas,
                priorityFeePerGas: fields.priorityFeePerGas
            )
            let estimate = try SendAtomicAmount.uint64(
                SendAtomicAmount.decimalFromHexQuantity(estimateHex)
            )
            let required = try Self.bufferedGasLimit(estimate)
            guard required > gasLimit else { return gasLimit }
            gasLimit = required
        }
        throw SendTransactionSubmissionError.provider(
            networkID: networkID,
            code: "native_max_gas_estimate_unstable",
            message: WalletLocalization.string(
                "send.submit.error.provider_invalid_response"
            )
        )
    }

    static func bufferedGasLimit(_ estimate: UInt64) throws -> UInt64 {
        let buffer = max(estimate / 5, 1)
        let result = estimate.addingReportingOverflow(buffer)
        guard !result.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result.partialValue
    }

    static func gasEstimateFeeFields(
        _ fee: SendResolvedNetworkFee
    ) throws -> (
        gasPrice: String?,
        maximumFeePerGas: String?,
        priorityFeePerGas: String?
    ) {
        switch fee.model {
        case .evmLegacy:
            return (
                try SendAtomicAmount.hexQuantity(fee.primaryValue),
                nil,
                nil
            )
        case .evmEIP1559:
            return (
                nil,
                try SendAtomicAmount.hexQuantity(fee.primaryValue),
                try SendAtomicAmount.hexQuantity(fee.secondaryValue ?? "0")
            )
        case .utxoPerVByte, .solanaPriority, .tronProtocol,
             .tonProtocol, .suiProtocol, .xrpProtocol, .nearProtocol,
             .aptosProtocol, .stellarProtocol:
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("wrong_evm_fee_model")
        }
    }

    static func erc20TransferData(
        recipient: String,
        amountAtomic: String,
        contractAddress: String?
    ) throws -> String? {
        guard contractAddress != nil else { return nil }
        guard let address = AnyAddress(
            string: recipient,
            coin: .ethereum
        ) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        let recipientData = address.data
        guard recipientData.count == 20 else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        let paddedAddress = Data(repeating: 0, count: 12)
            + recipientData
        let paddedAmount = try SendAtomicAmount.fixedWidthData(
            amountAtomic,
            byteCount: 32
        )
        return "0xa9059cbb"
            + paddedAddress.hexString
            + paddedAmount.hexString
    }

    private func sign(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        network: ReceiveNetwork,
        amountAtomic: String,
        nonce: String,
        gasLimit: UInt64,
        fee: SendResolvedNetworkFee,
        recipientAddress: String,
        contractAddress: String?
    ) throws -> Data {
        let transferAmount = try SendAtomicAmount.bigEndianData(
            amountAtomic
        )
        let input = try EthereumSigningInput.with {
            $0.chainID = try SendAtomicAmount.bigEndianData(
                String(network.chainID)
            )
            $0.nonce = try SendAtomicAmount.bigEndianData(nonce)
            $0.gasLimit = try SendAtomicAmount.bigEndianData(
                String(gasLimit)
            )
            $0.toAddress = contractAddress ?? recipientAddress
            $0.privateKey = material.privateKey
            switch fee.model {
            case .evmEIP1559:
                $0.txMode = .enveloped
                $0.maxFeePerGas = try SendAtomicAmount.bigEndianData(
                    fee.primaryValue
                )
                $0.maxInclusionFeePerGas = try SendAtomicAmount
                    .bigEndianData(fee.secondaryValue ?? "0")
            case .evmLegacy:
                $0.gasPrice = try SendAtomicAmount.bigEndianData(
                    fee.primaryValue
                )
            case .utxoPerVByte, .solanaPriority, .tronProtocol,
                 .tonProtocol,
                 .suiProtocol, .xrpProtocol, .nearProtocol,
                 .aptosProtocol, .stellarProtocol:
                throw SendTransactionSubmissionError
                    .feeQuoteUnavailable("wrong_evm_fee_model")
            }
            $0.transaction = EthereumTransaction.with {
                if draft.asset.isNative {
                    $0.transfer = EthereumTransaction.Transfer.with {
                        $0.amount = transferAmount
                    }
                } else {
                    $0.erc20Transfer =
                        EthereumTransaction.ERC20Transfer.with {
                            $0.to = recipientAddress
                            $0.amount = transferAmount
                        }
                }
            }
        }
        let output: EthereumSigningOutput = AnySigner.sign(
            input: input,
            coin: .ethereum
        )
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SendTransactionSubmissionError.signing(
                code: String(output.error.rawValue),
                message: SendTransactionSubmissionError
                    .sanitizedMessage(output.errorMessage)
            )
        }
        return output.encoded
    }

    static func locallyDerivedTransactionHash(
        from signedTransaction: Data,
        networkID: String
    ) throws -> Data {
        let hash = Hash.keccak256(data: signedTransaction)
        guard hash.count == 32 else {
            throw SendTransactionSubmissionError.signing(
                code: "invalid_local_transaction_hash",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        return hash
    }

    static func verifiedBroadcastHash(
        _ providerHash: String,
        locallyDerivedHash: Data,
        networkID: String
    ) throws -> String {
        let providerHashData = transactionHashData(providerHash)
        guard let providerHashData else {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: networkID,
                    code: "invalid_transaction_hash"
                )
        }
        guard providerHashData == locallyDerivedHash else {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: networkID,
                    code: "broadcast_hash_mismatch"
                )
        }
        return "0x" + locallyDerivedHash.hexString.lowercased()
    }

    static func isAlreadyKnownBroadcastRejection(
        _ error: SendTransactionSubmissionError
    ) -> Bool {
        guard case let .broadcastRejected(_, message, _) = error else {
            return false
        }
        return SendEVMSubmissionErrorClassifier
            .isKnownTransactionMessage(message)
    }

    private static func transactionHashData(
        _ hash: String
    ) -> Data? {
        guard hash.hasPrefix("0x"),
              hash.count == 66,
              hash.dropFirst(2).allSatisfy(\.isHexDigit),
              let data = Data(
                  hexString: String(hash.dropFirst(2))
              ),
              data.count == 32
        else {
            return nil
        }
        return data
    }
}
