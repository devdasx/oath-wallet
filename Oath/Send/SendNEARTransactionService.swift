import Foundation
import WalletCore

struct SendNEARTransactionService: Sendable {
    private let api: NEARAPIClient

    init(api: NEARAPIClient = .shared) {
        self.api = api
    }

    func submit(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        reservation: any SendSpendSubmissionReserving
    ) async throws -> SendTransactionReceipt {
        guard draft.asset.networkID == NEARConstants.networkID else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        try SendSelfTransferPolicy.validate(draft: draft, sourceAddress: material.account.address)
        guard NEARAddress.isValid(material.account.address),
              let recipientKind = NEARAddress.kind(draft.recipient),
              let requestedAmount = draft.amount,
              let privateKey = PrivateKey(data: material.privateKey)
        else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        let requestedAtomic = try SendAtomicAmount.fromUserUnits(
            requestedAmount,
            decimals: draft.asset.decimals
        )
        let publicKey = privateKey.getPublicKeyEd25519()
        let publicKeyText = "ed25519:\(Base58.encodeNoCheck(data: publicKey.data))"

        async let accessValue = api.accessKeyState(
            accountID: material.account.address,
            publicKey: publicKeyText
        )
        async let accountStateValue = api.accountState(
            accountID: material.account.address
        )
        async let protocolConfigValue = api.protocolConfig()
        async let recipientExistsValue = recipientExistsIfRequired(
            contractID: draft.asset.contractAddress,
            recipient: draft.recipient,
            kind: recipientKind
        )

        // FT balance/registration depend only on the reviewed addresses, not
        // access-key, account or protocol responses. All must pass before signing.
        async let tokenStateValue = loadTokenState(
            contractID: draft.asset.contractAddress,
            sender: material.account.address,
            recipient: draft.recipient
        )

        let access: NEARAccessKeyState
        let accountState: NEARAccountState
        let protocolConfig: NEARProtocolConfig
        let recipientExists: Bool
        do {
            (access, accountState, protocolConfig, recipientExists) =
                try await (
                accessValue,
                accountStateValue,
                protocolConfigValue,
                recipientExistsValue
            )
        } catch let error as NEARProviderError {
            throw Self.providerError(error)
        }

        try Self.validateRecipient(
            kind: recipientKind,
            accountExists: recipientExists,
            sendsToken: draft.asset.contractAddress != nil
        )

        let tokenState: NEARTokenSendState?
        do {
            tokenState = try await tokenStateValue
        } catch let error as NEARProviderError {
            throw Self.providerError(error)
        }

        guard access.isFullAccess else {
            throw SendTransactionSubmissionError.provider(
                networkID: NEARConstants.networkID,
                code: "near_access_key_not_full_access",
                message: WalletLocalization.string(
                    "send.submit.error.near_provider"
                )
            )
        }
        let resolvedFee = try SendSubmissionNetworkFee.resolve(draft: draft)
        guard resolvedFee.model == .nearProtocol else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable(
                "wrong_near_fee_model"
            )
        }
        let feeReserve = resolvedFee.primaryValue
        guard SendAtomicAmount.isCanonical(feeReserve),
              SendAtomicAmount.isCanonical(accountState.amount)
        else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable(
                "invalid_near_fee"
            )
        }
        let storageReserve = try Self.storageReserve(
            accountState: accountState,
            protocolConfig: protocolConfig
        )

        let prepared: PreparedNEARTransfer
        if let tokenState {
            prepared = try await prepareToken(
                draft: draft,
                state: tokenState,
                requestedAtomic: requestedAtomic,
                nativeBalance: accountState.amount,
                feeReserve: feeReserve,
                storageReserve: storageReserve
            )
        } else {
            prepared = try Self.prepareNative(
                draft: draft,
                requestedAtomic: requestedAtomic,
                nativeBalance: accountState.amount,
                feeReserve: feeReserve,
                storageReserve: storageReserve
            )
        }
        guard access.nonce < UInt64.max else {
            throw SendTransactionSubmissionError.provider(
                networkID: NEARConstants.networkID,
                code: "nonce_out_of_range",
                message: WalletLocalization.string(
                    "send.submit.error.near_provider"
                )
            )
        }

        // NEAR accepts nonce jumps: a later transaction arriving first can
        // invalidate the earlier one. Wait for the access-key nonce to advance,
        // not for all cross-contract receipts to finish, before using it again.
        let nonce = access.nonce + 1
        let output: NEARSigningOutput = AnySigner.sign(
            input: NEARSigningInput.with {
                $0.signerID = material.account.address
                $0.nonce = nonce
                $0.receiverID = prepared.signingReceiver
                $0.blockHash = access.blockHash
                $0.actions = prepared.actions
                $0.privateKey = material.privateKey
                $0.publicKey = publicKey.data
            },
            coin: .near
        )
        let localHash = Base58.encodeNoCheck(data: output.hash)
        guard output.error == .ok,
              !output.signedTransaction.isEmpty,
              output.hash.count == 32,
              !localHash.isEmpty
        else {
            throw SendTransactionSubmissionError.signing(
                code: String(output.error.rawValue),
                message: SendTransactionSubmissionError.sanitizedMessage(
                    output.errorMessage
                )
            )
        }

        var receipt = SendTransactionReceipt(
            transactionHash: localHash,
            accountID: material.account.id,
            networkID: NEARConstants.networkID,
            fromAddress: material.account.address,
            toAddress: draft.recipient,
            assetID: draft.asset.id,
            assetSymbol: draft.asset.symbol,
            amount: SendDecimalAmount.userUnits(
                fromAtomicUnits: prepared.amountAtomic,
                decimals: draft.asset.decimals
            ),
            amountAtomic: prepared.amountAtomic,
            networkFee: SendDecimalAmount.userUnits(
                fromAtomicUnits: feeReserve,
                decimals: NEARConstants.decimals
            ),
            networkFeeAtomic: feeReserve,
            networkFeeSymbol: NEARConstants.nativeSymbol,
            submittedAt: Date()
        )

        receipt.spendResources = [.sequence(String(nonce))]
        try await reservation.markSubmissionStarted(receipt: receipt)
        let result: NEARSubmitResult
        do {
            result = try await api.submit(
                signedTransaction: output.signedTransaction
            )
        } catch let error as NEARProviderError {
            throw Self.broadcastError(error, receipt: receipt)
        } catch {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: NEARConstants.networkID,
                code: SendTransactionSubmissionError.sanitizedErrorType(error),
                receipt: receipt
            )
        }
        guard result.transactionHash == localHash else {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: NEARConstants.networkID,
                code: "transaction_hash_mismatch",
                receipt: receipt
            )
        }
        guard result.succeeded else {
            throw SendTransactionSubmissionError.broadcastExecutionFailed(
                code: result.providerStatus,
                message: WalletLocalization.string(
                    "send.submit.error.near_execution_failed"
                ),
                receipt: receipt
            )
        }
        return receipt
    }

    private func loadTokenState(
        contractID: String?,
        sender: String,
        recipient: String
    ) async throws -> NEARTokenSendState? {
        guard let contractID else { return nil }
        guard NEARAddress.isValid(contractID) else {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        async let balanceValue = api.fungibleTokenBalance(
            contractID: contractID,
            accountID: sender
        )
        async let registrationValue = api.isStorageRegistered(
            contractID: contractID,
            accountID: recipient
        )
        let (balance, registered) = try await (
            balanceValue,
            registrationValue
        )
        return NEARTokenSendState(
            contractID: contractID,
            balanceAtomic: balance,
            recipientIsRegistered: registered
        )
    }

    private func recipientExistsIfRequired(
        contractID: String?,
        recipient: String,
        kind: NEARAddress.Kind
    ) async throws -> Bool {
        if contractID == nil, kind != .named {
            // A native transfer initializes an unfunded implicit account.
            // Named accounts require explicit creation, while token transfers
            // require an existing base account before storage registration.
            return false
        }
        return try await api.accountExists(accountID: recipient)
    }

    static func validateRecipient(
        kind: NEARAddress.Kind,
        accountExists: Bool,
        sendsToken: Bool
    ) throws {
        if accountExists || (!sendsToken && kind != .named) { return }
        let key = sendsToken
            ? "send.submit.error.near_token_recipient_missing"
            : "send.submit.error.near_named_recipient_missing"
        let code = sendsToken
            ? "near_token_recipient_missing"
            : "near_named_recipient_missing"
        throw SendTransactionSubmissionError.provider(
            networkID: NEARConstants.networkID,
            code: code,
            message: WalletLocalization.string(key)
        )
    }

    private func prepareToken(
        draft: SendDraft,
        state: NEARTokenSendState,
        requestedAtomic: String,
        nativeBalance: String,
        feeReserve: String,
        storageReserve: String
    ) async throws -> PreparedNEARTransfer {
        let amount = draft.usesMaximumBalance
            ? state.balanceAtomic
            : requestedAtomic
        guard amount != "0",
              SendAtomicAmount.compare(
                amount,
                state.balanceAtomic
              ) != .orderedDescending
        else {
            throw SendTransactionSubmissionError.insufficientAssetBalance
        }
        // NEP-141 represents token amounts as decimal u128 text. Validate the
        // bound before handing the value to Wallet Core's JSON action builder.
        _ = try Self.uint128LittleEndian(amount)

        let storageDeposit: String
        if state.recipientIsRegistered {
            storageDeposit = "0"
        } else {
            do {
                storageDeposit = try await api.storageMinimumBalance(
                    contractID: state.contractID
                )
            } catch let error as NEARProviderError {
                throw Self.providerError(error)
            }
        }
        let requiredNative = SendAtomicAmount.add(
            SendAtomicAmount.add(
                SendAtomicAmount.add(feeReserve, storageDeposit),
                "1"
            ),
            storageReserve
        )
        guard SendAtomicAmount.isCanonical(requiredNative),
              SendAtomicAmount.compare(
            requiredNative,
            nativeBalance
        ) != .orderedDescending else {
            throw SendTransactionSubmissionError
                .insufficientNetworkFeeBalance
        }

        var actions: [NEARAction] = []
        if storageDeposit != "0" {
            let arguments = try Self.storageDepositArguments(
                accountID: draft.recipient
            )
            let storageDepositData = try Self.uint128LittleEndian(
                storageDeposit
            )
            actions.append(
                NEARAction.with {
                    $0.functionCall = .with {
                        $0.methodName = "storage_deposit"
                        $0.args = arguments
                        $0.gas = NEARConstants.storageDepositGas
                        $0.deposit = storageDepositData
                    }
                }
            )
        }
        let deposit = try Self.uint128LittleEndian("1")
        actions.append(
            NEARAction.with {
                $0.tokenTransfer = .with {
                    $0.tokenAmount = amount
                    $0.receiverID = draft.recipient
                    $0.gas = NEARConstants.fungibleTokenGas
                    $0.deposit = deposit
                }
            }
        )
        return PreparedNEARTransfer(
            signingReceiver: state.contractID,
            amountAtomic: amount,
            actions: actions
        )
    }

    private static func prepareNative(
        draft: SendDraft,
        requestedAtomic: String,
        nativeBalance: String,
        feeReserve: String,
        storageReserve: String
    ) throws -> PreparedNEARTransfer {
        let unavailable = SendAtomicAmount.add(feeReserve, storageReserve)
        guard SendAtomicAmount.isCanonical(unavailable) else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        let amount = try SendNativeTransferAmountResolver.resolve(
            requestedAtomic: requestedAtomic,
            balanceAtomic: nativeBalance,
            unavailableAtomic: unavailable,
            usesMaximumBalance: draft.usesMaximumBalance
        )
        let deposit = try uint128LittleEndian(amount)
        return PreparedNEARTransfer(
            signingReceiver: draft.recipient,
            amountAtomic: amount,
            actions: [
                NEARAction.with {
                    $0.transfer = .with { $0.deposit = deposit }
                }
            ]
        )
    }

    private static func storageDepositArguments(
        accountID: String
    ) throws -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: [
                    "account_id": accountID,
                    "registration_only": true
                ],
                options: [.sortedKeys]
            )
        } catch {
            throw SendTransactionSubmissionError.signing(
                code: "storage_arguments",
                message: WalletLocalization.string(
                    "send.submit.error.near_storage_arguments"
                )
            )
        }
    }

    static func uint128LittleEndian(_ value: String) throws -> Data {
        Data(try SendAtomicAmount.fixedWidthData(value, byteCount: 16).reversed())
    }

    static func storageReserve(
        accountState: NEARAccountState,
        protocolConfig: NEARProtocolConfig
    ) throws -> String {
        guard protocolConfig.chainID == "mainnet",
              SendAtomicAmount.isCanonical(accountState.locked),
              SendAtomicAmount.isCanonical(
                  protocolConfig.storageAmountPerByte
              )
        else {
            throw SendTransactionSubmissionError.provider(
                networkID: NEARConstants.networkID,
                code: "invalid_near_storage_state",
                message: WalletLocalization.string(
                    "send.submit.error.near_provider"
                )
            )
        }
        guard accountState.storageUsage
                > NEARConstants.zeroBalanceAccountStorageLimit else {
            return "0"
        }
        let required = try SendAtomicAmount.multiply(
            protocolConfig.storageAmountPerByte,
            by: accountState.storageUsage
        )
        guard SendAtomicAmount.compare(required, accountState.locked)
                == .orderedDescending else {
            return "0"
        }
        return try SendAtomicAmount.subtract(required, accountState.locked)
    }

    private static func providerError(
        _ error: NEARProviderError
    ) -> SendTransactionSubmissionError {
        .provider(
            networkID: NEARConstants.networkID,
            code: error.diagnosticDescription,
            message: WalletLocalization.string(
                "send.submit.error.near_provider"
            )
        )
    }

    private static func broadcastError(
        _ error: NEARProviderError,
        receipt: SendTransactionReceipt
    ) -> SendTransactionSubmissionError {
        if NEARSubmissionErrorClassifier
            .isDefinitivePreSubmissionRejection(error) {
            return .broadcastRejected(
                code: error.diagnosticDescription,
                message: WalletLocalization.string(
                    "send.submit.error.near_rejected"
                ),
                receipt: receipt
            )
        }
        return .broadcastOutcomeUnknown(
            networkID: NEARConstants.networkID,
            code: error.diagnosticDescription,
            receipt: receipt
        )
    }
}

enum NEARSubmissionErrorClassifier {
    static func isDefinitivePreSubmissionRejection(
        _ error: NEARProviderError
    ) -> Bool {
        switch error {
        case .providerRejected:
            true
        case let .rpc(code, message):
            [-32700, -32600, -32601, -32602].contains(code)
                || [
                    "expired_transaction",
                    "invalid_signature"
                ].contains(message.lowercased())
        case let .http(status, _):
            (400..<500).contains(status) && status != 408 && status != 429
        default:
            false
        }
    }
}

private struct NEARTokenSendState: Sendable {
    let contractID: String
    let balanceAtomic: String
    let recipientIsRegistered: Bool
}

private struct PreparedNEARTransfer {
    let signingReceiver: String
    let amountAtomic: String
    let actions: [NEARAction]
}
