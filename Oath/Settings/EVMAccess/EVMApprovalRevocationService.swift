import Foundation
import WalletCore

struct EVMApprovalRevocationOutcome: Hashable, Sendable {
    let receipt: SendTransactionReceipt
    let persistenceWarningCode: String?
}

enum EVMApprovalDraftFactory {
    static func preparedDraft(
        approval: EVMOnChainApproval,
        database: WalletDatabase
    ) async throws -> SendDraft {
        let policy = SendNetworkFeePolicy.preset(.standard)
        let quote = try await SendNetworkFeeQuoteRepository.shared.quote(
            for: approval.networkID, database: database
        )
        let fee = try SendResolvedNetworkFee.resolve(
            policy: policy,
            quote: quote
        )
        return try draft(
            approval: approval,
            feePolicy: policy,
            preparedNetworkFee: fee
        )
    }

    static func draft(
        approval: EVMOnChainApproval,
        feePolicy: SendNetworkFeePolicy = .preset(.standard),
        preparedNetworkFee: SendResolvedNetworkFee? = nil
    ) throws -> SendDraft {
        guard let network = ReceiveNetworkCatalog.network(
            for: approval.networkID
        ), network.blockchain.isEVM,
        SendAddressValidator.isValidEVMAddress(
            approval.ownerAddress
        ),
        SendAddressValidator.isValidEVMAddress(
            approval.contractAddress
        ),
        SendAddressValidator.isValidEVMAddress(
            approval.spenderAddress
        ) else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        let tokenName = approval.tokenName
            ?? shortened(approval.contractAddress)
        let tokenSymbol = approval.tokenSymbol ?? network.symbol
        let logoSource = ReceiveAssetCatalog.variant(
            networkID: approval.networkID,
            contractAddress: approval.contractAddress
        )?.logoSource ?? .unavailable
        let request = SendPaymentRequest(
            source: .ethereumURI,
            recipient: approval.contractAddress,
            candidateNetworkIDs: [approval.networkID],
            requestedNetworkID: approval.networkID,
            requestedAsset: .contract(approval.contractAddress),
            requestedAmount: .atomicUnits("0"),
            label: nil,
            message: nil,
            memo: nil,
            references: ["evm-approval", approval.id]
        )
        return SendDraft(
            request: request,
            asset: SendAssetChoice(
                id: "evm-approval:\(approval.id)",
                name: tokenName,
                symbol: tokenSymbol,
                networkID: approval.networkID,
                networkName: network.localizedName,
                blockchain: network.blockchain,
                contractAddress: approval.contractAddress,
                decimals: approval.decimals ?? 0,
                logoSource: logoSource,
                networkLogoSource: network.logoSource,
                balance: 0,
                fiatValue: 0,
                balanceAtomic: approval.amountAtomic,
                sourceAddress: approval.ownerAddress,
                isVerified: logoSource.origin == .catalog
            ),
            recipient: approval.contractAddress,
            amount: "0",
            note: nil,
            feePolicy: feePolicy,
            preparedNetworkFee: preparedNetworkFee
        )
    }

    private static func shortened(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return "\(address.prefix(8))…\(address.suffix(6))"
    }
}

struct EVMApprovalRevocationService: Sendable {
    let database: WalletDatabase

    func submit(
        approval: EVMOnChainApproval,
        draft: SendDraft,
        authorization: SendTransactionAuthorization
    ) async throws -> EVMApprovalRevocationOutcome {
        let material = try await SendSigningKeyResolver(
            database: database
        ).resolve(
            draft: draft,
            authorization: authorization
        )
        guard material.account.id == approval.accountID,
              material.account.networkID == approval.networkID,
              material.account.address.caseInsensitiveCompare(
                  approval.ownerAddress
              ) == .orderedSame,
              draft.asset.networkID == approval.networkID,
              draft.recipient.caseInsensitiveCompare(
                  approval.contractAddress
              ) == .orderedSame,
              draft.asset.contractAddress?.caseInsensitiveCompare(
                  approval.contractAddress
              ) == .orderedSame,
              let network = ReceiveNetworkCatalog.network(
                  for: approval.networkID
              ),
              network.blockchain.isEVM,
              let fee = draft.preparedNetworkFee
        else {
            throw SendTransactionAuthorizationError.bindingMismatch
        }
        let reservation = try await SendTransactionSubmissionService(
            database: database
        ).acquireSpendReservation(material: material)
        do {
        let calldata = try EVMApprovalABI.revokeCalldata(
            approval: approval
        )
        let rpc = try SendEVMRPCClient(networkID: approval.networkID)
        let feeFields = try SendEVMTransactionService
            .gasEstimateFeeFields(fee)

        async let chainIDValue = rpc.chainID()
        async let nonceValue = rpc.transactionCount(
            address: approval.ownerAddress
        )
        async let balanceValue = rpc.nativeBalance(
            address: approval.ownerAddress
        )
        let (chainHex, nonceHex, balanceHex) = try await (
            chainIDValue,
            nonceValue,
            balanceValue
        )
        let chainID = try SendAtomicAmount.decimalFromHexQuantity(
            chainHex
        )
        guard chainID == String(network.chainID) else {
            throw SendTransactionSubmissionError.provider(
                networkID: approval.networkID,
                code: "chain_id_mismatch",
                message: WalletLocalization.string(
                    "send.submit.error.provider_wrong_chain"
                )
            )
        }
        let nonce = try await reservation.nextSequence(
            networkValue: SendAtomicAmount.decimalFromHexQuantity(nonceHex)
        )
        let balance = try SendAtomicAmount.decimalFromHexQuantity(
            balanceHex
        )
        let gasHex = try await EVMApprovalGasFunding.validatedEstimate(
            networkID: approval.networkID,
            nativeBalance: balance,
            feePerGas: fee.primaryValue
        ) {
            try await rpc.estimateGas(
                from: approval.ownerAddress,
                to: approval.contractAddress,
                value: "0x0",
                data: calldata,
                gasPrice: feeFields.gasPrice,
                maximumFeePerGas: feeFields.maximumFeePerGas,
                priorityFeePerGas: feeFields.priorityFeePerGas
            )
        }
        let estimate = try SendAtomicAmount.uint64(
            SendAtomicAmount.decimalFromHexQuantity(gasHex)
        )
        let gasLimit = try SendEVMTransactionService.bufferedGasLimit(
            estimate
        )
        let maximumFee = try SendEVMTransactionService.maximumFeeAtomic(
            feePerGas: fee.primaryValue,
            gasLimit: gasLimit,
            networkID: approval.networkID
        )
        try SendEVMTransactionService.validateCustomFeeBudget(
            fee,
            maximumFeeAtomic: maximumFee
        )
        guard SendAtomicAmount.compare(balance, maximumFee)
                != .orderedAscending else {
            throw SendTransactionSubmissionError
                .insufficientNetworkFeeBalance
        }

        let signed = try Self.sign(
            network: network,
            material: material,
            contractAddress: approval.contractAddress,
            calldata: calldata,
            nonce: nonce,
            gasLimit: gasLimit,
            fee: fee
        )
        let localHash = try SendEVMTransactionService
            .locallyDerivedTransactionHash(
                from: signed,
                networkID: approval.networkID
            )
        let submittedAt = Date()
        var receipt = SendTransactionReceipt(
            transactionHash: "0x" + localHash.hexString.lowercased(),
            accountID: approval.accountID,
            networkID: approval.networkID,
            fromAddress: approval.ownerAddress,
            toAddress: approval.contractAddress,
            assetID: draft.asset.id,
            assetSymbol: draft.asset.symbol,
            amount: "0",
            amountAtomic: "0",
            networkFee: SendDecimalAmount.userUnits(
                fromAtomicUnits: maximumFee,
                decimals: 18
            ),
            networkFeeAtomic: maximumFee,
            networkFeeSymbol: network.symbol,
            submittedAt: submittedAt
        )
        receipt.spendResources = [.sequence(nonce)]
        try await reservation.markSubmissionStarted(receipt: receipt)
        let providerHash: String
        do {
            providerHash = try await rpc.broadcast(
                rawTransaction: "0x" + signed.hexString
            )
        } catch is CancellationError {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: approval.networkID,
                code: "cancelled_after_broadcast_started",
                receipt: receipt
            )
        } catch let error as SendTransactionSubmissionError {
            if SendEVMTransactionService
                .isAlreadyKnownBroadcastRejection(error) {
                try? await database.finishSendSpendSubmission(reservation)
                return await persist(
                    approval: approval,
                    receipt: receipt
                )
            }
            throw error.attachingTransactionEvidence(receipt)
        } catch {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: approval.networkID,
                code: SendTransactionSubmissionError
                    .sanitizedErrorType(error),
                receipt: receipt
            )
        }
        do {
            _ = try SendEVMTransactionService.verifiedBroadcastHash(
                providerHash,
                locallyDerivedHash: localHash,
                networkID: approval.networkID
            )
        } catch let error as SendTransactionSubmissionError {
            throw error.attachingTransactionEvidence(receipt)
        }
        try? await database.finishSendSpendSubmission(reservation)
        return await persist(approval: approval, receipt: receipt)
        } catch let error as SendTransactionSubmissionError {
            if case .broadcastRejected = error {
                try? await database.releaseSendSpendReservation(
                    reservation
                )
            } else {
                try? await database.finishSendSpendSubmission(reservation)
                try? await database.releaseSendSpendReservation(
                    reservation,
                    onlyIfPreparing: true
                )
            }
            throw error
        } catch {
            try? await database.finishSendSpendSubmission(reservation)
            try? await database.releaseSendSpendReservation(
                reservation,
                onlyIfPreparing: true
            )
            throw error
        }
    }

    static func sign(
        network: ReceiveNetwork,
        material: SendResolvedSigningMaterial,
        contractAddress: String,
        calldata: String,
        nonce: String,
        gasLimit: UInt64,
        fee: SendResolvedNetworkFee
    ) throws -> Data {
        guard calldata.hasPrefix("0x"),
              let data = Data(hexString: String(calldata.dropFirst(2)))
        else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        let input = try EthereumSigningInput.with {
            $0.chainID = try SendAtomicAmount.bigEndianData(
                String(network.chainID)
            )
            $0.nonce = try SendAtomicAmount.bigEndianData(nonce)
            $0.gasLimit = try SendAtomicAmount.bigEndianData(
                String(gasLimit)
            )
            $0.toAddress = contractAddress
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
                 .tonProtocol, .suiProtocol, .xrpProtocol, .nearProtocol,
                 .aptosProtocol, .stellarProtocol:
                throw SendTransactionSubmissionError
                    .feeQuoteUnavailable("wrong_evm_fee_model")
            }
            $0.transaction = EthereumTransaction.with {
                $0.contractGeneric = EthereumTransaction
                    .ContractGeneric.with {
                        $0.amount = Data([0])
                        $0.data = data
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

    private func persist(
        approval: EVMOnChainApproval,
        receipt: SendTransactionReceipt
    ) async -> EVMApprovalRevocationOutcome {
        do {
            try await database.markEVMApprovalRevocationSubmitted(
                approvalID: approval.id,
                transactionHash: receipt.transactionHash,
                submittedAt: receipt.submittedAt
            )
            return EVMApprovalRevocationOutcome(
                receipt: receipt,
                persistenceWarningCode: nil
            )
        } catch {
            return EVMApprovalRevocationOutcome(
                receipt: receipt,
                persistenceWarningCode:
                    SendTransactionSubmissionService.persistenceCode(error)
            )
        }
    }
}
