import Foundation
import WalletCore

struct SendTONTransactionService: Sendable {
    private static let jettonForwardAmount: UInt64 = 1

    private let api: TONAPIClient
    private let quoteLoader:
        @Sendable (String) async throws -> SendNetworkFeeQuote

    init(
        api: TONAPIClient = .shared,
        quoteLoader: @escaping @Sendable (String) async throws
            -> SendNetworkFeeQuote = SendSubmissionNetworkFee.builtInQuote
    ) {
        self.api = api
        self.quoteLoader = quoteLoader
    }

    func submit(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        reservation: any SendSpendSubmissionReserving
    ) async throws -> SendTransactionReceipt {
        guard draft.asset.networkID == TONConstants.networkID else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        let senderAddress = material.account.address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let recipientAddress = draft.recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let senderRaw = TONAddress.rawAddress(from: senderAddress) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        guard let recipientRaw = TONAddress.rawAddress(
            from: recipientAddress
        ) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard let requestedAmount = draft.amount else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        let requestedAtomic = try SendAtomicAmount.fromUserUnits(
            requestedAmount,
            decimals: draft.asset.decimals
        )
        let jettonMaster: String?
        if let contract = draft.asset.contractAddress {
            guard let raw = TONAddress.rawAddress(from: contract),
                  TONTokenCatalog.byAddress[raw] != nil
            else {
                throw SendTransactionSubmissionError.unsupportedAsset
            }
            jettonMaster = raw
        } else {
            jettonMaster = nil
        }

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

        async let senderAccountValue = api.account(
            address: senderAddress
        )
        async let recipientAccountValue = api.account(
            address: recipientRaw
        )
        async let seqnoValue = api.seqno(
            address: senderAddress
        )
        async let jettonsValue: TONAPIJettonBalances? =
            jettonMaster == nil
                ? nil
                : try await api.jettonBalances(
                    address: senderAddress
                )
        async let verifiedJettonWalletValue: String? =
            verifiedJettonWalletAddress(
                masterAddress: jettonMaster,
                ownerAddress: senderRaw
            )

        let senderAccount: TONAPIAccount
        let recipientAccount: TONAPIAccount
        let seqno: Int
        let jettons: TONAPIJettonBalances?
        let verifiedJettonWallet: String?
        do {
            (
                senderAccount,
                recipientAccount,
                seqno,
                jettons,
                verifiedJettonWallet
            ) = try await (
                senderAccountValue,
                recipientAccountValue,
                seqnoValue,
                jettonsValue,
                verifiedJettonWalletValue
            )
        } catch let error as TONProviderError {
            throw Self.providerError(error)
        }

        guard senderAccount.isScam != true,
              TONAddress.matches(senderAccount.address, senderRaw)
        else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        guard recipientAccount.isScam != true,
              TONAddress.matches(recipientAccount.address, recipientRaw)
        else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard fee.model == .tonProtocol else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("wrong_ton_fee_model")
        }
        let feeReserve = try SendAtomicAmount.uint64(
            fee.primaryValue
        )
        let jettonAttachedAmount = try SendAtomicAmount.uint64(
            fee.secondaryValue ?? "100000000"
        )
        let nativeBalance = try Self.exactUInt64(
            senderAccount.balance.text,
            field: "native_balance"
        )
        guard seqno >= 0, let sequenceNumber = UInt32(exactly: seqno)
        else {
            throw SendTransactionSubmissionError.provider(
                networkID: TONConstants.networkID,
                code: "invalid_seqno",
                message: WalletLocalization.string(
                    "send.submit.error.ton_sequence_range"
                )
            )
        }
        let bounceable = recipientAccount.status == "active"
        guard let recipient = TONAddress.userFriendlyAddress(
            from: recipientRaw,
            bounceable: bounceable
        ) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }

        let prepared: PreparedTransfer
        if let jettonMaster {
            guard let jettons, let verifiedJettonWallet else {
                throw SendTransactionSubmissionError.unsupportedAsset
            }
            prepared = try prepareJetton(
                draft: draft,
                senderAddress: senderAddress,
                recipient: recipient,
                contractAddress: jettonMaster,
                verifiedJettonWallet: verifiedJettonWallet,
                requestedAtomic: requestedAtomic,
                nativeBalance: nativeBalance,
                feeReserve: feeReserve,
                attachedAmount: jettonAttachedAmount,
                balances: jettons
            )
        } else {
            prepared = try prepareNative(
                draft: draft,
                recipient: recipient,
                requestedAtomic: requestedAtomic,
                nativeBalance: nativeBalance,
                feeReserve: feeReserve,
                bounceable: bounceable
            )
        }

        guard let expiry = UInt32(
            exactly: Int(Date().timeIntervalSince1970) + 300
        ) else {
            throw SendTransactionSubmissionError.signing(
                code: "invalid_expiry",
                message: WalletLocalization.string(
                    "send.submit.error.ton_expiry_range"
                )
            )
        }
        guard let privateKey = PrivateKey(data: material.privateKey)
        else {
            throw SendTransactionSubmissionError.secretUnavailable
        }
        let output: TheOpenNetworkSigningOutput = AnySigner.sign(
            input: TheOpenNetworkSigningInput.with {
                $0.privateKey = material.privateKey
                $0.publicKey =
                    privateKey.getPublicKeyEd25519().data
                $0.messages = [prepared.transfer]
                $0.sequenceNumber = sequenceNumber
                $0.expireAt = expiry
                $0.walletVersion = .walletV4R2
            },
            coin: .ton
        )
        let transactionHash = output.hash.hexString.lowercased()
        guard output.error == .ok,
              !output.encoded.isEmpty,
              transactionHash.count == 64
        else {
            throw SendTransactionSubmissionError.signing(
                code: String(output.error.rawValue),
                message: SendTransactionSubmissionError
                    .sanitizedMessage(output.errorMessage)
            )
        }
        var receipt = SendTransactionReceipt(
            transactionHash: transactionHash,
            accountID: material.account.id,
            networkID: TONConstants.networkID,
            fromAddress: senderAddress,
            toAddress: recipientAddress,
            assetID: draft.asset.id,
            assetSymbol: draft.asset.symbol,
            amount: SendDecimalAmount.userUnits(
                fromAtomicUnits: prepared.amountAtomic,
                decimals: draft.asset.decimals
            ),
            amountAtomic: prepared.amountAtomic,
            networkFee: SendDecimalAmount.userUnits(
                fromAtomicUnits: String(feeReserve),
                decimals: TONConstants.decimals
            ),
            networkFeeAtomic: String(feeReserve),
            networkFeeSymbol: TONConstants.nativeSymbol,
            submittedAt: Date()
        )
        receipt.spendResources = [.sequence(String(sequenceNumber))]
        try await reservation.markSubmissionStarted(receipt: receipt)
        do {
            try await api.broadcast(
                boc: output.encoded,
                expectedHash: transactionHash
            )
        } catch is CancellationError {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: TONConstants.networkID,
                    code: "cancelled_after_broadcast_started",
                    receipt: receipt
                )
        } catch let error as TONProviderError {
            if TONSubmissionErrorClassifier
                .isDefinitivePreSubmission(error) {
                throw SendTransactionSubmissionError.broadcastRejected(
                    code: error.diagnosticDescription,
                    message: WalletLocalization.string(
                        "send.submit.error.ton_rejected"
                    ),
                    receipt: receipt
                )
            }
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: TONConstants.networkID,
                    code: error.diagnosticDescription,
                    receipt: receipt
                )
        } catch {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: TONConstants.networkID,
                    code: SendTransactionSubmissionError
                        .sanitizedErrorType(error),
                    receipt: receipt
                )
        }
        return receipt
    }

    private func prepareNative(
        draft: SendDraft,
        recipient: String,
        requestedAtomic: String,
        nativeBalance: UInt64,
        feeReserve: UInt64,
        bounceable: Bool
    ) throws -> PreparedTransfer {
        let requested = try SendAtomicAmount.uint64(requestedAtomic)
        let amount = try SendNativeTransferAmountResolver.uint64(
            requestedAtomic: requested,
            balanceAtomic: nativeBalance,
            unavailableAtomic: feeReserve,
            usesMaximumBalance: draft.usesMaximumBalance
        )
        return PreparedTransfer(
            amountAtomic: String(amount),
            transfer: TheOpenNetworkTransfer.with {
                $0.dest = recipient
                $0.amount = Self.bigEndianUInt128Data(amount)
                $0.mode = Self.sendMode
                $0.comment = Self.memo(from: draft)
                $0.bounceable = bounceable
            }
        )
    }

    private func verifiedJettonWalletAddress(
        masterAddress: String?,
        ownerAddress: String
    ) async throws -> String? {
        guard let masterAddress else { return nil }
        return try await api.verifiedJettonWalletAddress(
            masterAddress: masterAddress,
            ownerAddress: ownerAddress
        )
    }

    private func prepareJetton(
        draft: SendDraft,
        senderAddress: String,
        recipient: String,
        contractAddress: String,
        verifiedJettonWallet: String,
        requestedAtomic: String,
        nativeBalance: UInt64,
        feeReserve: UInt64,
        attachedAmount: UInt64,
        balances: TONAPIJettonBalances
    ) throws -> PreparedTransfer {
        guard let definition =
                TONTokenCatalog.byAddress[contractAddress],
              definition.decimals == draft.asset.decimals,
              let balance = balances.balances.first(where: {
                  TONAddress.rawAddress(from: $0.jetton.address)
                      == contractAddress
                      && $0.jetton.verification == "whitelist"
                      && $0.walletAddress.isScam != true
              }),
              TONAddress.matches(
                balance.walletAddress.address,
                verifiedJettonWallet
              ),
              let jettonWallet = TONAddress.userFriendlyAddress(
                  from: balance.walletAddress.address,
                  bounceable: true
              ),
              let responseAddress = TONAddress.userFriendlyAddress(
                  from: senderAddress,
                  bounceable: true
              )
        else {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        let available = try Self.exactUnsignedDecimal(
            balance.balance,
            field: "jetton_balance"
        )
        guard SendAtomicAmount.isCanonical(requestedAtomic) else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        let requested = requestedAtomic
        let amount = draft.usesMaximumBalance
            ? available : requested
        guard amount != "0" else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        guard SendAtomicAmount.compare(amount, available)
                != .orderedDescending
        else {
            throw SendTransactionSubmissionError
                .insufficientAssetBalance
        }
        let jettonAmount = try Self.jettonTransferAmountData(amount)
        let requiredNative = attachedAmount.addingReportingOverflow(
            feeReserve
        )
        guard !requiredNative.overflow,
              requiredNative.partialValue <= nativeBalance
        else {
            throw SendTransactionSubmissionError
                .insufficientNetworkFeeBalance
        }
        return PreparedTransfer(
            amountAtomic: amount,
            transfer: TheOpenNetworkTransfer.with {
                $0.dest = jettonWallet
                $0.amount = Self.bigEndianUInt128Data(attachedAmount)
                $0.mode = Self.sendMode
                $0.comment = Self.memo(from: draft)
                $0.bounceable = true
                $0.jettonTransfer =
                    TheOpenNetworkJettonTransfer.with {
                        $0.queryID = UInt64(
                            Date().timeIntervalSince1970 * 1_000
                        )
                        $0.jettonAmount = jettonAmount
                        $0.toOwner = recipient
                        $0.responseAddress = responseAddress
                        $0.forwardAmount =
                            Self.bigEndianUInt128Data(
                                Self.jettonForwardAmount
                            )
                    }
            }
        )
    }

    private static var sendMode: UInt32 {
        UInt32(
            TheOpenNetworkSendMode.payFeesSeparately.rawValue
                | TheOpenNetworkSendMode
                    .ignoreActionPhaseErrors.rawValue
        )
    }

    private static func memo(from draft: SendDraft) -> String {
        String((draft.request.memo ?? "").prefix(500))
    }

    private static func exactUInt64(
        _ value: String,
        field: String
    ) throws -> UInt64 {
        guard let canonical =
                ExactDecimalText.canonicalUnsignedInteger(value),
              let result = UInt64(canonical)
        else {
            throw SendTransactionSubmissionError.provider(
                networkID: TONConstants.networkID,
                code: "invalid_\(field)",
                message: WalletLocalization.string(
                    "send.submit.error.ton_invalid_quantity"
                )
            )
        }
        return result
    }

    private static func exactUnsignedDecimal(
        _ value: String,
        field: String
    ) throws -> String {
        guard let canonical =
                ExactDecimalText.canonicalUnsignedInteger(value)
        else {
            throw SendTransactionSubmissionError.provider(
                networkID: TONConstants.networkID,
                code: "invalid_\(field)",
                message: WalletLocalization.string(
                    "send.submit.error.ton_invalid_quantity"
                )
            )
        }
        return canonical
    }

    /// TEP-74 stores a Jetton amount as `VarUInteger 16`. Its four-bit byte
    /// length prefix represents 0...15, so a positive transfer can contain at
    /// most 15 big-endian bytes (120 bits), not merely UInt64 and not 16 bytes.
    static func jettonTransferAmountData(_ value: String) throws -> Data {
        let data = try SendAtomicAmount.bigEndianData(value)
        guard !data.isEmpty, data.count <= 15 else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return data
    }

    private static func bigEndianUInt128Data(
        _ value: UInt64
    ) -> Data {
        var bigEndian = value.bigEndian
        let bytes = withUnsafeBytes(of: &bigEndian) {
            Array($0)
        }
        return Data(bytes.drop(while: { $0 == 0 }))
    }

    private static func providerError(
        _ error: TONProviderError
    ) -> SendTransactionSubmissionError {
        .provider(
            networkID: TONConstants.networkID,
            code: error.diagnosticDescription,
            message: WalletLocalization.string(
                "send.submit.error.ton_provider"
            )
        )
    }

    private struct PreparedTransfer {
        let amountAtomic: String
        let transfer: TheOpenNetworkTransfer
    }
}
