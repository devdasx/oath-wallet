import Foundation
import WalletCore

struct SendSolanaTransactionService: Sendable {
    private let rpc: SendSolanaRPCClient

    init(rpc: SendSolanaRPCClient = SendSolanaRPCClient()) {
        self.rpc = rpc
    }

    func submit(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        reservation: any SendSpendSubmissionReserving
    ) async throws -> SendTransactionReceipt {
        guard draft.asset.networkID == SolanaConstants.networkID else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        let recipientAddress = draft.recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let senderAddress = material.account.address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard CoinType.solana.validate(address: recipientAddress) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard CoinType.solana.validate(address: senderAddress) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        guard let requestedAmount = draft.amount else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        let requestedAtomicText = try SendAtomicAmount.fromUserUnits(
            requestedAmount,
            decimals: draft.asset.decimals
        )
        let requestedAtomic = try SendAtomicAmount.uint64(
            requestedAtomicText
        )
        guard requestedAtomic > 0 else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        let fee = try SendSubmissionNetworkFee.resolve(draft: draft)
        async let blockhashValue = rpc.latestBlockhash()
        async let accountStateValue = rpc.accountState(
            address: senderAddress
        )
        let (blockhash, senderAccountState) = try await (
            blockhashValue,
            accountStateValue
        )
        guard let senderAccountState else {
            if draft.asset.contractAddress == nil {
                throw SendTransactionSubmissionError
                    .insufficientAssetBalance
            }
            throw SendTransactionSubmissionError
                .insufficientNetworkFeeBalance
        }
        return try await submit(
            draft: draft,
            material: material,
            requestedAtomic: requestedAtomic,
            blockhash: blockhash,
            senderAccountState: senderAccountState,
            fee: fee,
            senderAddress: senderAddress,
            recipientAddress: recipientAddress,
            reservation: reservation
        )
    }

    private func submit(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        requestedAtomic: UInt64,
        blockhash: String,
        senderAccountState: SendSolanaAccountState,
        fee: SendResolvedNetworkFee,
        senderAddress: String,
        recipientAddress: String,
        reservation: any SendSpendSubmissionReserving
    ) async throws -> SendTransactionReceipt {
        guard fee.model == .solanaPriority else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("wrong_solana_fee_model")
        }
        let priorityPrice = try SendAtomicAmount.uint64(
            fee.primaryValue
        )
        let context: TransferContext
        if let mint = draft.asset.contractAddress {
            context = try await tokenContext(
                draft: draft,
                material: material,
                mint: mint,
                requestedAtomic: requestedAtomic,
                senderAddress: senderAddress,
                recipientAddress: recipientAddress
            )
        } else {
            context = .native(requestedAtomic)
        }
        let nativeBalance = senderAccountState.lamports
        let computeLimit: UInt32 = switch context {
        case .native:
            200_000
        case let .token(_, _, _, createsRecipientAccount, _):
            createsRecipientAccount ? 400_000 : 300_000
        }

        let preliminaryAmount: UInt64 = switch context {
        case .native:
            draft.usesMaximumBalance
                ? nativeBalance
                : requestedAtomic
        case let .token(amount, _, _, _, _):
            amount
        }
        let preliminary = try sign(
            draft: draft,
            material: material,
            context: context.replacingAmount(preliminaryAmount),
            blockhash: blockhash,
            priorityPrice: priorityPrice,
            computeLimit: computeLimit,
            senderAddress: senderAddress,
            recipientAddress: recipientAddress
        )
        let message = try Self.base64Message(
            fromBase64Transaction: preliminary
        )
        // Fee lookup and rent requirements are independent reads. Await all
        // before checking affordability and recording the submission intent.
        async let networkFeeValue = rpc.feeForMessage(
            base64Message: message
        )
        async let senderRentMinimumValue =
            rpc.minimumBalanceForRentExemption(
                dataLength: senderAccountState.dataLength
            )
        async let recipientRentRequirementValue =
            nativeRecipientRentRequirement(
                context: context,
                senderAddress: senderAddress,
                recipientAddress: recipientAddress
            )
        let tokenAccountRent: UInt64
        if let dataLength = context.createdTokenAccountDataLength {
            tokenAccountRent = try await rpc.minimumTokenAccountRent(
                dataLength: dataLength
            )
        } else {
            tokenAccountRent = 0
        }
        let networkFee = try await networkFeeValue
        try Self.validateCustomFeeBudget(
            fee,
            networkFeeAtomic: networkFee
        )
        let (senderRentMinimum, recipientRentRequirement) = try await (
            senderRentMinimumValue,
            recipientRentRequirementValue
        )
        let requiredNative = try Self.adding(
            networkFee,
            tokenAccountRent
        )
        guard nativeBalance >= requiredNative else {
            throw SendTransactionSubmissionError
                .insufficientNetworkFeeBalance
        }

        let amountAtomic: UInt64
        let signedTransaction: String
        if case .native = context {
            amountAtomic = try SendNativeTransferAmountResolver.uint64(
                requestedAtomic: context.amount,
                balanceAtomic: nativeBalance,
                unavailableAtomic: requiredNative,
                usesMaximumBalance: draft.usesMaximumBalance
            )
            if amountAtomic != preliminaryAmount {
                signedTransaction = try sign(
                    draft: draft,
                    material: material,
                    context: context.replacingAmount(amountAtomic),
                    blockhash: blockhash,
                    priorityPrice: priorityPrice,
                    computeLimit: computeLimit,
                    senderAddress: senderAddress,
                    recipientAddress: recipientAddress
                )
            } else {
                signedTransaction = preliminary
            }
        } else {
            amountAtomic = context.amount
            signedTransaction = preliminary
        }

        if case .native = context,
           amountAtomic < recipientRentRequirement {
            throw SendTransactionSubmissionError
                .solanaRecipientRentMinimum(
                    requiredAmount: Self.solAmount(
                        recipientRentRequirement
                    )
                )
        }

        let senderDebit: UInt64
        switch context {
        case .native where senderAddress == recipientAddress:
            senderDebit = requiredNative
        case .native:
            senderDebit = try Self.adding(
                requiredNative,
                amountAtomic
            )
        case .token:
            senderDebit = requiredNative
        }
        guard nativeBalance >= senderDebit else {
            if case .native = context {
                throw SendTransactionSubmissionError
                    .insufficientAssetBalance
            }
            throw SendTransactionSubmissionError
                .insufficientNetworkFeeBalance
        }
        let postTransactionBalance = nativeBalance - senderDebit
        guard SendSolanaRentPolicy.permitsSenderTransition(
            preBalance: nativeBalance,
            postBalance: postTransactionBalance,
            rentMinimum: senderRentMinimum
        ) else {
            throw SendTransactionSubmissionError
                .solanaSenderRentMinimum(
                    requiredAmount: Self.solAmount(
                        senderRentMinimum
                    )
                )
        }

        let localSignature = try Self.locallyEmbeddedSignature(
            fromBase64Transaction: signedTransaction
        )
        let amountText = String(amountAtomic)
        let feeText = String(networkFee)
        var receipt = SendTransactionReceipt(
            transactionHash: Base58.encodeNoCheck(data: localSignature),
            accountID: material.account.id,
            networkID: SolanaConstants.networkID,
            fromAddress: senderAddress,
            toAddress: recipientAddress,
            assetID: draft.asset.id,
            assetSymbol: draft.asset.symbol,
            amount: SendDecimalAmount.userUnits(
                fromAtomicUnits: amountText,
                decimals: draft.asset.decimals
            ),
            amountAtomic: amountText,
            networkFee: SendDecimalAmount.userUnits(
                fromAtomicUnits: feeText,
                decimals: 9
            ),
            networkFeeAtomic: feeText,
            networkFeeSymbol: "SOL",
            submittedAt: Date()
        )
        receipt.spendResources = [SendSpendResource(kind: .transactionID, value: receipt.transactionHash)]
        try await reservation.markSubmissionStarted(receipt: receipt)
        let providerSignature: String
        do {
            providerSignature = try await rpc.broadcast(
                base64Transaction: signedTransaction
            )
        } catch let error as SendTransactionSubmissionError {
            if case let .broadcastRejected(_, message, _) = error,
               SendSolanaSubmissionErrorClassifier
                .isAlreadyProcessedMessage(message) {
                return receipt
            }
            throw error.attachingTransactionEvidence(receipt)
        } catch {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: SendTransactionSubmissionError
                        .sanitizedErrorType(error),
                    receipt: receipt
                )
        }
        do {
            _ = try Self.verifiedBroadcastSignature(
                providerSignature,
                locallyEmbeddedSignature: localSignature
            )
        } catch let error as SendTransactionSubmissionError {
            throw error.attachingTransactionEvidence(receipt)
        }
        return receipt
    }

    static func validateCustomFeeBudget(
        _ fee: SendResolvedNetworkFee,
        networkFeeAtomic: UInt64
    ) throws {
        guard let budget = fee.totalBudgetAtomic else { return }
        guard let budgetValue = UInt64(budget) else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("invalid_custom_fee")
        }
        guard networkFeeAtomic <= budgetValue else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("custom_fee_budget_below_required")
        }
    }

    private func nativeRecipientRentRequirement(
        context: TransferContext,
        senderAddress: String,
        recipientAddress: String
    ) async throws -> UInt64 {
        guard case .native = context,
              senderAddress != recipientAddress
        else {
            return 0
        }
        let recipientState = try await rpc.accountState(
            address: recipientAddress
        )
        let rentMinimum = try await rpc
            .minimumBalanceForRentExemption(
                dataLength: recipientState?.dataLength ?? 0
            )
        return SendSolanaRentPolicy.requiredRecipientFunding(
            currentBalance: recipientState?.lamports,
            rentMinimum: rentMinimum
        )
    }

    private func tokenContext(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        mint: String,
        requestedAtomic: UInt64,
        senderAddress: String,
        recipientAddress: String
    ) async throws -> TransferContext {
        let normalizedMint = mint.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard CoinType.solana.validate(address: normalizedMint),
              let sender = SolanaAddress(
                  string: senderAddress
              ),
              let recipient = SolanaAddress(
                  string: recipientAddress
              )
        else {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        let program = try await rpc.tokenProgram(mint: normalizedMint)
        let senderTokenAddress: String?
        let recipientTokenAddress: String?
        switch program {
        case .legacy:
            senderTokenAddress = sender.defaultTokenAddress(
                tokenMintAddress: normalizedMint
            )
            recipientTokenAddress = recipient.defaultTokenAddress(
                tokenMintAddress: normalizedMint
            )
        case .token2022:
            senderTokenAddress = sender.token2022Address(
                tokenMintAddress: normalizedMint
            )
            recipientTokenAddress = recipient.token2022Address(
                tokenMintAddress: normalizedMint
            )
        }
        guard let senderTokenAddress,
              let recipientTokenAddress
        else {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        async let balanceValue = rpc.tokenBalance(
            address: senderTokenAddress
        )
        async let existsValue = rpc.accountExists(
            address: recipientTokenAddress
        )
        async let dataLengthValue = rpc.tokenAccountDataLength(
            address: senderTokenAddress,
            program: program
        )
        let (balance, recipientExists, dataLength) = try await (
            balanceValue,
            existsValue,
            dataLengthValue
        )
        let amount = draft.usesMaximumBalance
            ? balance
            : requestedAtomic
        guard amount > 0, amount <= balance else {
            throw SendTransactionSubmissionError
                .insufficientAssetBalance
        }
        return .token(
            amount: amount,
            mint: normalizedMint,
            program: program,
            createsRecipientAccount: !recipientExists,
            recipientAccountDataLength: dataLength
        )
    }

    func sign(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        context: TransferContext,
        blockhash: String,
        priorityPrice: UInt64,
        computeLimit: UInt32,
        senderAddress: String,
        recipientAddress: String
    ) throws -> String {
        let input = try SolanaSigningInput.with {
            $0.recentBlockhash = blockhash
            $0.privateKey = material.privateKey
            $0.sender = senderAddress
            $0.txEncoding = .base64
            $0.priorityFeePrice = .with {
                $0.price = priorityPrice
            }
            $0.priorityFeeLimit = .with {
                $0.limit = computeLimit
            }
            switch context {
            case let .native(amount):
                $0.transferTransaction = .with {
                    $0.recipient = recipientAddress
                    $0.value = amount
                    $0.memo = draft.request.memo ?? ""
                    $0.references = draft.request.references
                }
            case let .token(
                amount,
                mint,
                program,
                createsRecipientAccount,
                _
            ):
                guard draft.asset.decimals >= 0,
                      let decimals = UInt32(
                          exactUserDecimal: draft.asset.decimals
                      )
                else {
                    throw SendTransactionSubmissionError
                        .amountOutOfRange
                }
                guard
                    let sender = SolanaAddress(
                        string: senderAddress
                    ),
                    let recipient = SolanaAddress(
                        string: recipientAddress
                    )
                else {
                    throw SendTransactionSubmissionError
                        .invalidRecipient
                }
                let senderTokenAddress: String?
                let recipientTokenAddress: String?
                let walletCoreProgram:
                    TW_Solana_Proto_TokenProgramId
                switch program {
                case .legacy:
                    senderTokenAddress = sender.defaultTokenAddress(
                        tokenMintAddress: mint
                    )
                    recipientTokenAddress =
                        recipient.defaultTokenAddress(
                            tokenMintAddress: mint
                        )
                    walletCoreProgram = .tokenProgram
                case .token2022:
                    senderTokenAddress = sender.token2022Address(
                        tokenMintAddress: mint
                    )
                    recipientTokenAddress =
                        recipient.token2022Address(
                            tokenMintAddress: mint
                        )
                    walletCoreProgram = .token2022Program
                }
                guard let senderTokenAddress,
                      let recipientTokenAddress
                else {
                    throw SendTransactionSubmissionError
                        .unsupportedAsset
                }
                if createsRecipientAccount {
                    $0.createAndTransferTokenTransaction = .with {
                        $0.recipientMainAddress = recipientAddress
                        $0.tokenMintAddress = mint
                        $0.recipientTokenAddress =
                            recipientTokenAddress
                        $0.senderTokenAddress = senderTokenAddress
                        $0.amount = amount
                        $0.decimals = decimals
                        $0.memo = draft.request.memo ?? ""
                        $0.references = draft.request.references
                        $0.tokenProgramID = walletCoreProgram
                    }
                } else {
                    $0.tokenTransferTransaction = .with {
                        $0.tokenMintAddress = mint
                        $0.senderTokenAddress = senderTokenAddress
                        $0.recipientTokenAddress =
                            recipientTokenAddress
                        $0.amount = amount
                        $0.decimals = decimals
                        $0.memo = draft.request.memo ?? ""
                        $0.references = draft.request.references
                        $0.tokenProgramID = walletCoreProgram
                    }
                }
            }
        }
        let output: SolanaSigningOutput = AnySigner.sign(
            input: input,
            coin: .solana
        )
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SendTransactionSubmissionError.signing(
                code: String(output.error.rawValue),
                message: SendTransactionSubmissionError
                    .sanitizedMessage(output.errorMessage)
            )
        }
        guard Data(base64Encoded: output.encoded) != nil else {
            throw SendTransactionSubmissionError.signing(
                code: "invalid_base64_transaction",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        return output.encoded
    }

    private static func base64Message(
        fromBase64Transaction transaction: String
    ) throws -> String {
        guard let data = Data(base64Encoded: transaction) else {
            throw SendTransactionSubmissionError.signing(
                code: "invalid_base64_transaction",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        let (count, prefixLength) = try compactArrayLength(data)
        let signatureBytes = count.multipliedReportingOverflow(by: 64)
        guard !signatureBytes.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        let offset = prefixLength + signatureBytes.partialValue
        guard offset < data.count else {
            throw SendTransactionSubmissionError.signing(
                code: "invalid_solana_message",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        return Data(data.dropFirst(offset)).base64EncodedString()
    }

    static func locallyEmbeddedSignature(
        fromBase64Transaction transaction: String
    ) throws -> Data {
        guard let data = Data(base64Encoded: transaction) else {
            throw SendTransactionSubmissionError.signing(
                code: "invalid_base64_transaction",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        let (count, prefixLength) = try compactArrayLength(data)
        let signatureBytes = count.multipliedReportingOverflow(by: 64)
        guard count > 0,
              !signatureBytes.overflow,
              data.count > prefixLength + signatureBytes.partialValue
        else {
            throw SendTransactionSubmissionError.signing(
                code: "invalid_solana_signatures",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        let end = prefixLength + 64
        guard end <= data.count else {
            throw SendTransactionSubmissionError.signing(
                code: "truncated_solana_signature",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        let signature = Data(data[prefixLength..<end])
        guard signature.contains(where: { $0 != 0 }) else {
            throw SendTransactionSubmissionError.signing(
                code: "unsigned_solana_transaction",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        return signature
    }

    static func verifiedBroadcastSignature(
        _ providerSignature: String,
        locallyEmbeddedSignature: Data
    ) throws -> String {
        let providerData = Base58.decodeNoCheck(
            string: providerSignature
        )
        let syntaxValid = providerData?.count == 64
            && providerData.map {
                Base58.encodeNoCheck(data: $0) == providerSignature
            } == true
        guard syntaxValid, let providerData else {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "invalid_signature"
                )
        }
        guard providerData == locallyEmbeddedSignature else {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: SolanaConstants.networkID,
                    code: "broadcast_signature_mismatch"
                )
        }
        return Base58.encodeNoCheck(
            data: locallyEmbeddedSignature
        )
    }

    private static func compactArrayLength(
        _ data: Data
    ) throws -> (value: Int, bytes: Int) {
        var value = 0
        var shift = 0
        for (index, byte) in data.prefix(3).enumerated() {
            value |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return (value, index + 1)
            }
            shift += 7
        }
        throw SendTransactionSubmissionError.signing(
            code: "invalid_compact_array",
            message: WalletLocalization.string(
                "send.submit.error.provider_invalid_response"
            )
        )
    }

    private static func adding(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result.partialValue
    }

    private static func solAmount(_ lamports: UInt64) -> String {
        SendDecimalAmount.userUnits(
            fromAtomicUnits: String(lamports),
            decimals: 9
        )
    }
}

enum SendSolanaRentPolicy {
    static func requiredRecipientFunding(
        currentBalance: UInt64?,
        rentMinimum: UInt64
    ) -> UInt64 {
        guard let currentBalance else {
            return rentMinimum
        }
        guard currentBalance < rentMinimum else {
            return 0
        }
        return rentMinimum - currentBalance
    }

    static func permitsSenderTransition(
        preBalance: UInt64,
        postBalance: UInt64,
        rentMinimum: UInt64
    ) -> Bool {
        if postBalance == 0 || postBalance >= rentMinimum {
            return true
        }
        return preBalance > 0
            && preBalance < rentMinimum
            && postBalance <= preBalance
    }
}

private extension UInt32 {
    init?(exactUserDecimal value: Int) {
        guard value >= 0,
              UInt64(value) <= UInt64(UInt32.max)
        else {
            return nil
        }
        self = UInt32(value)
    }
}

enum TransferContext: Sendable {
    case native(UInt64)
    case token(
        amount: UInt64,
        mint: String,
        program: SendSolanaRPCClient.TokenProgram,
        createsRecipientAccount: Bool,
        recipientAccountDataLength: Int
    )

    var amount: UInt64 {
        switch self {
        case let .native(amount), let .token(amount, _, _, _, _):
            amount
        }
    }

    var createsRecipientTokenAccount: Bool {
        if case let .token(_, _, _, creates, _) = self {
            return creates
        }
        return false
    }

    var createdTokenAccountDataLength: Int? {
        if case let .token(_, _, _, true, dataLength) = self {
            return dataLength
        }
        return nil
    }

    func replacingAmount(_ amount: UInt64) -> TransferContext {
        switch self {
        case .native:
            return .native(amount)
        case let .token(_, mint, program, creates, dataLength):
            return .token(
                amount: amount,
                mint: mint,
                program: program,
                createsRecipientAccount: creates,
                recipientAccountDataLength: dataLength
            )
        }
    }
}
