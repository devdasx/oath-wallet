import Foundation
import WalletCore

struct SendBitcoinTransactionService: Sendable {
    private let utxoRepository: SendBitcoinUTXORepository
    private let broadcaster: any SendBitcoinFamilyTransactionBroadcasting
    private let database: WalletDatabase?

    init(
        database: WalletDatabase? = nil,
        utxoRepository: SendBitcoinUTXORepository = .shared,
        broadcaster: any SendBitcoinFamilyTransactionBroadcasting =
            SendBitcoinFamilyHTTPAPIClient.shared
    ) {
        self.database = database
        self.utxoRepository = utxoRepository
        self.broadcaster = broadcaster
    }

    func submit(
        draft originalDraft: SendDraft,
        material: SendResolvedSigningMaterial,
        reservation: any SendSpendSubmissionReserving
    ) async throws -> SendTransactionReceipt {
        var draft = originalDraft
        guard let chain = BitcoinFamilyChain(
            rawValue: draft.asset.networkID
        ) else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        guard draft.asset.isNative else {
            throw SendTransactionSubmissionError.unsupportedAsset
        }
        let recipientAddress = draft.recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let senderAddress = material.account.address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard SendAddressValidator.isValid(
            recipientAddress,
            for: chain.networkID
        ) else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        guard chain.coin.validate(address: senderAddress) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        guard let requestedAmount = draft.amount else {
            throw SendTransactionSubmissionError.invalidAmount
        }

        var requestedAtomicText = try SendAtomicAmount.fromUserUnits(
            requestedAmount,
            decimals: draft.asset.decimals
        )
        var requestedAtomic = try SendAtomicAmount.int64(
            requestedAtomicText
        )
        let options: SendBitcoinFamilyOptions
        do {
            options = try draft.bitcoinFamilyOptions.normalized(
                for: chain
            )
        } catch {
            let optionsError = error as? SendBitcoinFamilyOptionsError
            throw SendTransactionSubmissionError.signing(
                code: optionsError?.diagnosticCode
                    ?? "invalid_bitcoin_options",
                message: optionsError?.localizedMessage
                    ?? WalletLocalization.string(
                        "send.submit.error.provider_no_message"
                    )
            )
        }

        let allOutputs: [SendBitcoinUTXO]
        do {
            allOutputs = try await utxoRepository.outputs(
                for: chain,
                accountAddress: senderAddress,
                walletID: material.walletID,
                minimumExpectedValueAtomic:
                    Self.minimumExpectedUTXOValue(
                        draft: draft,
                        requestedAtomic: requestedAtomicText
                    ),
                requiredOutpointIDs: Set(
                    options.coinSelection.selectedUTXOs.map(\.id)
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SendBitcoinUTXORepositoryError {
            throw Self.repositoryError(error, networkID: chain.networkID)
        }
        let selectedOutputs = try Self.outputs(
            from: SendSpendResource.availableBitcoinOutputs(
                allOutputs, excluding: try await reservation.pendingSpendResources()
            ),
            selection: options.coinSelection
        )
        guard !selectedOutputs.isEmpty else {
            throw SendTransactionSubmissionError.insufficientAssetBalance
        }
        var fee = try SendSubmissionNetworkFee.resolve(draft: draft)
        guard fee.model == .utxoPerVByte else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("wrong_utxo_fee_model")
        }
        let byteFee = try Self.validatedByteFee(
            fee,
            networkID: chain.networkID
        )

        if let database = database ?? (try? WalletDatabaseRuntime.require()) {
            let estimate = try await SendNetworkFeeEstimator(database: database).nativeBitcoinEstimate(
                draft: draft, fee: fee, loadedInputs: SendBitcoinPlanningInputs(walletID: material.walletID,
                    account: material.account, outputs: selectedOutputs))
            fee = estimate.applyingNativeFee(to: fee)
            draft = estimate.applyingNativeAmount(to: draft).replacingPreparedNetworkFee(fee)
            requestedAtomicText = try SendAtomicAmount.fromUserUnits(draft.amount ?? "0", decimals: draft.asset.decimals)
            requestedAtomic = try SendAtomicAmount.int64(requestedAtomicText)
        }

        let signed: SendBitcoinSignedTransaction
        if chain.supportsFamilyHD, material.bitcoinHDRecoveryCredential != nil {
            guard let database = database ?? (try? WalletDatabaseRuntime.require()) else {
                throw SendTransactionSubmissionError.walletUnavailable
            }
            let change = try await database.freshBitcoinFamilyHDAddress(walletID: material.walletID,
                chain: chain, branch: .change, reserve: true)
            do {
                signed = try SendBitcoinFamilyHDTransactionSigner.sign(draft: draft, material: material, chain: chain,
                    outputs: selectedOutputs, requestedAtomic: requestedAtomic, byteFee: byteFee, fee: fee,
                    options: options, changeAddress: change.address, recipientAddress: recipientAddress)
            } catch {
                try? await database.releaseBitcoinFamilyHDChange(walletID: material.walletID, chain: chain, address: change.address)
                throw error
            }
            if signed.changeAddress == nil {
                try await database.releaseBitcoinFamilyHDChange(walletID: material.walletID, chain: chain, address: change.address)
            }
        } else if chain == .bitcoin, let imported = material.bitcoinImportedMaterial {
            guard let database = database ?? (try? WalletDatabaseRuntime.require()) else {
                throw SendTransactionSubmissionError.walletUnavailable
            }
            let type = try await database.bitcoinReceiveAddressType(walletID: material.walletID)
            let change = try await database.bitcoinImportedReceiveAddress(walletID: material.walletID,
                material: imported, type: type, reserveChange: true)
            signed = try BitcoinSilentPaymentTransactionSigner.signImportedWallet(
                draft: draft, material: imported, outputs: selectedOutputs,
                requestedAtomic: requestedAtomic, byteFee: byteFee, fee: fee, options: options,
                changeAddress: change.address, recipientAddress: recipientAddress
            )
        } else if chain == .bitcoin,
           let muunMaterial = material.muunRecoveryKeyMaterial {
            guard let database = database
                    ?? (try? WalletDatabaseRuntime.require()) else {
                throw SendTransactionSubmissionError.walletUnavailable
            }
            guard let reservedChange = try await database
                .reserveFreshMuunRecoveryChangeAddress(
                    walletID: material.walletID
                ) else {
                throw SendTransactionSubmissionError.accountUnavailable
            }
            do {
                signed = try SendMuunRecoveryTransactionSigner.sign(
                    draft: draft,
                    material: muunMaterial,
                    outputs: selectedOutputs,
                    requestedAtomic: requestedAtomic,
                    byteFee: byteFee,
                    fee: fee,
                    options: options,
                    changeAddress: reservedChange.address,
                    recipientAddress: recipientAddress
                )
            } catch {
                try? await database
                    .releaseMuunRecoveryChangeAddressReservation(
                        walletID: material.walletID,
                        address: reservedChange.address
                    )
                throw error
            }
            if signed.changeAddress == nil {
                try await database
                    .releaseMuunRecoveryChangeAddressReservation(
                        walletID: material.walletID,
                        address: reservedChange.address
                    )
            }
        } else if chain == .bitcoin,
                  material.bitcoinHDRecoveryCredential != nil {
            guard let database = database
                    ?? (try? WalletDatabaseRuntime.require()) else {
                throw SendTransactionSubmissionError.walletUnavailable
            }
            let changeType = try await database
                .bitcoinReceiveAddressType(walletID: material.walletID)
            guard let reservedChange = try await database
                .reserveFreshBitcoinChangeAddress(
                    walletID: material.walletID,
                    addressType: changeType
                ) else {
                throw SendTransactionSubmissionError.accountUnavailable
            }
            do {
                if selectedOutputs.contains(where: {
                    $0.silentPaymentOwner != nil
                }) {
                    guard let credential = material
                        .bitcoinHDRecoveryCredential else {
                        throw SendTransactionSubmissionError
                            .secretUnavailable
                    }
                    let privateKeys = try await Self
                        .silentPaymentPrivateKeys(
                            outputs: selectedOutputs,
                            walletID: material.walletID,
                            database: database
                        )
                    signed = try BitcoinSilentPaymentTransactionSigner.sign(
                        draft: draft,
                        credential: credential,
                        outputs: selectedOutputs,
                        silentPaymentPrivateKeys: privateKeys,
                        requestedAtomic: requestedAtomic,
                        byteFee: byteFee,
                        fee: fee,
                        options: options,
                        changeAddress: reservedChange.address,
                        recipientAddress: recipientAddress
                    )
                } else {
                    signed = try SendBitcoinHDTransactionSigner.sign(
                        draft: draft,
                        material: material,
                        outputs: selectedOutputs,
                        requestedAtomic: requestedAtomic,
                        byteFee: byteFee,
                        fee: fee,
                        options: options,
                        changeAddress: reservedChange.address,
                        recipientAddress: recipientAddress
                    )
                }
            } catch {
                try? await database
                    .releaseBitcoinHDChangeAddressReservation(
                        walletID: material.walletID,
                        address: reservedChange.address
                    )
                throw error
            }
            if signed.changeAddress == nil {
                try await database.releaseBitcoinHDChangeAddressReservation(
                    walletID: material.walletID,
                    address: reservedChange.address
                )
            }
        } else if chain == .bitcoin,
                  let format = PrivateKeyImportFormat(
                      accountMarker: material.account.derivationPath
                  ),
                  [.wifCompressed, .wifUncompressed].contains(format) {
            guard let database = database
                    ?? (try? WalletDatabaseRuntime.require()),
                  let wallet = try await database.bitcoinSingleKeyWallet(
                      walletID: material.walletID
                  ) else {
                throw SendTransactionSubmissionError.walletUnavailable
            }
            let preferredType = try await database
                .bitcoinReceiveAddressType(walletID: material.walletID)
            guard let changeAddress = wallet.address(for: preferredType)
                    ?? wallet.address(for: wallet.defaultAddressType) else {
                throw SendTransactionSubmissionError.accountUnavailable
            }
            signed = try SendBitcoinSingleKeyTransactionSigner.sign(
                draft: draft,
                privateKeyData: material.privateKey,
                format: format,
                outputs: selectedOutputs,
                requestedAtomic: requestedAtomic,
                byteFee: byteFee,
                fee: fee,
                options: options,
                senderAddress: senderAddress,
                changeAddress: changeAddress.address,
                recipientAddress: recipientAddress
            )
        } else if chain == .bitcoin {
            let format = PrivateKeyImportFormat(
                accountMarker: material.account.derivationPath
            ) ?? .wifCompressed
            signed = try BitcoinSilentPaymentTransactionSigner
                .signSingleKey(
                    draft: draft,
                    privateKey: material.privateKey,
                    format: format,
                    outputs: selectedOutputs,
                    requestedAtomic: requestedAtomic,
                    byteFee: byteFee,
                    fee: fee,
                    options: options,
                    senderAddress: senderAddress,
                    recipientAddress: recipientAddress
                )
        } else {
            signed = try Self.signSingleKeyTransaction(
                draft: draft,
                material: material,
                chain: chain,
                outputs: selectedOutputs,
                requestedAtomic: requestedAtomic,
                byteFee: byteFee,
                fee: fee,
                options: options,
                senderAddress: senderAddress,
                recipientAddress: recipientAddress
            )
        }

        if chain == .bitcoin {
            try SendBitcoinTransactionPolicy.validateEncoded(signed.encoded)
        }
        let amountAtomic = signed.amountAtomic
        let feeAtomic = signed.feeAtomic
        let receiptFromAddress = selectedOutputs.compactMap {
            $0.owner?.address
                ?? $0.muunOwner?.address
        }.first ?? senderAddress
        var receipt = SendTransactionReceipt(
            transactionHash: signed.transactionID,
            accountID: material.account.id,
            networkID: chain.networkID,
            fromAddress: receiptFromAddress,
            toAddress: recipientAddress,
            assetID: draft.asset.id,
            assetSymbol: draft.asset.symbol,
            amount: SendDecimalAmount.userUnits(
                fromAtomicUnits: amountAtomic,
                decimals: draft.asset.decimals
            ),
            amountAtomic: amountAtomic,
            networkFee: SendDecimalAmount.userUnits(
                fromAtomicUnits: feeAtomic,
                decimals: draft.asset.decimals
            ),
            networkFeeAtomic: feeAtomic,
            networkFeeSymbol: chain.symbol,
            submittedAt: Date()
        )

        receipt.spendResources = try SendSpendResource.bitcoinInputs(
            rawHex: signed.encoded.hexString, transactionID: signed.transactionID
        )
        try await reservation.markSubmissionStarted(receipt: receipt)
        do {
            _ = try await broadcaster.broadcast(
                chain: chain,
                rawTransactionHex: signed.encoded.hexString,
                expectedTransactionID: signed.transactionID
            )
        } catch let error as SendBitcoinFamilyHTTPBroadcastError {
            switch error {
            case let .notAttempted(provider, code):
                throw SendTransactionSubmissionError.provider(
                    networkID: chain.networkID,
                    code: "\(provider)_\(code)",
                    message: WalletLocalization.string(
                        "send.submit.error.provider_transport"
                    )
                )
            case let .rejected(provider, code, message):
                throw SendTransactionSubmissionError.broadcastRejected(
                    code: "\(provider)_\(code)",
                    message: message,
                    receipt: receipt
                )
            case let .outcomeUnknown(provider, code):
                throw SendTransactionSubmissionError
                    .broadcastOutcomeUnknown(
                        networkID: chain.networkID,
                        code: "\(provider)_\(code)",
                        receipt: receipt
                    )
            }
        } catch is CancellationError {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: chain.networkID,
                    code: "cancelled_after_broadcast_started",
                    receipt: receipt
                )
        } catch let error as SendTransactionSubmissionError {
            throw error.attachingTransactionEvidence(receipt)
        } catch {
            throw SendTransactionSubmissionError
                .broadcastOutcomeUnknown(
                    networkID: chain.networkID,
                    code: SendTransactionSubmissionError
                        .sanitizedErrorType(error),
                    receipt: receipt
                )
        }
        await Self.markSilentPaymentInputsSpent(
            signed: signed,
            outputs: selectedOutputs,
            walletID: material.walletID,
            database: database
        )
        return receipt
    }

    private static func silentPaymentPrivateKeys(
        outputs: [SendBitcoinUTXO],
        walletID: String,
        database: WalletDatabase
    ) async throws -> [String: Data] {
        var keys: [String: Data] = [:]
        for output in outputs {
            guard let owner = output.silentPaymentOwner else { continue }
            guard owner.walletID == walletID else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            do {
                keys[output.id] = try await database
                    .bitcoinSilentPaymentOutputPrivateKey(
                        walletID: walletID,
                        transactionHash: owner.transactionHash,
                        outputIndex: owner.outputIndex
                    )
            } catch {
                throw SendTransactionSubmissionError.secretUnavailable
            }
        }
        return keys
    }

    private static func markSilentPaymentInputsSpent(
        signed: SendBitcoinSignedTransaction,
        outputs: [SendBitcoinUTXO],
        walletID: String,
        database: WalletDatabase?
    ) async {
        guard let database, !signed.spentOutpointIDs.isEmpty else {
            return
        }
        for output in outputs where signed.spentOutpointIDs.contains(
            output.id
        ) {
            guard let owner = output.silentPaymentOwner,
                  owner.walletID == walletID else { continue }
            try? await database.markBitcoinSilentPaymentOutputSpent(
                walletID: walletID,
                transactionHash: owner.transactionHash,
                outputIndex: owner.outputIndex,
                spentByTransactionHash: signed.transactionID
            )
        }
    }

    private static func signSingleKeyTransaction(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        chain: BitcoinFamilyChain,
        outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64,
        byteFee: Int64,
        fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions,
        senderAddress: String,
        recipientAddress: String
    ) throws -> SendBitcoinSignedTransaction {
        let input = try signingInput(
            draft: draft,
            accountMarker: material.account.derivationPath,
            nestedSegwitPublicKey: PrivateKey(
                data: material.privateKey
            )?.getPublicKeySecp256k1(compressed: true),
            chain: chain,
            outputs: outputs,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            options: options,
            senderAddress: senderAddress,
            recipientAddress: recipientAddress
        )
        let plan = try dustSafePlan(input: input, chain: chain, fee: fee)

        var signingInput = input
        signingInput.privateKey = [material.privateKey]
        signingInput.plan = plan
        let output: BitcoinSigningOutput = AnySigner.sign(
            input: signingInput,
            coin: chain.coin
        )
        guard output.error == .ok,
              !output.encoded.isEmpty,
              validTransactionHash(output.transactionID) else {
            throw SendTransactionSubmissionError.signing(
                code: String(output.error.rawValue),
                message: SendTransactionSubmissionError
                    .sanitizedMessage(output.errorMessage)
            )
        }
        return SendBitcoinSignedTransaction(
            encoded: output.encoded,
            transactionID: output.transactionID.lowercased(),
            amountAtomic: String(plan.amount),
            feeAtomic: String(plan.fee),
            changeAddress: plan.change > 0 ? senderAddress : nil
        )
    }

    static func validatedByteFee(
        _ fee: SendResolvedNetworkFee,
        networkID: String
    ) throws -> Int64 {
        guard fee.model == .utxoPerVByte else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("wrong_utxo_fee_model")
        }
        let byteFee = try SendAtomicAmount.int64(fee.primaryValue)
        let minimumByteFee = Int64(
            SendNetworkFeeEstimator.minimumUTXORate(
                networkID: networkID
            )
        )
        guard byteFee >= minimumByteFee else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("custom_fee_below_network_minimum")
        }
        return byteFee
    }

    static func applyingCustomFeeBudget(
        _ fee: SendResolvedNetworkFee,
        to plan: BitcoinTransactionPlan,
        usesMaximumBalance: Bool,
        minimumOutput: Int64 = 0,
        minimumChange: Int64? = nil
    ) throws -> BitcoinTransactionPlan {
        let targetFee = try fee.totalBudgetAtomic.map(SendAtomicAmount.int64) ?? plan.fee
        guard targetFee >= plan.fee else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("custom_fee_budget_below_required")
        }
        let additionalFee = targetFee - plan.fee

        var adjusted = plan
        if usesMaximumBalance {
            guard adjusted.amount > additionalFee else {
                throw SendTransactionSubmissionError
                    .insufficientAssetBalance
            }
            adjusted.amount -= additionalFee
        } else {
            guard adjusted.change >= additionalFee else {
                throw SendTransactionSubmissionError
                    .insufficientNetworkFeeBalance
            }
            adjusted.change -= additionalFee
        }
        // Fold only the new sub-threshold remainder into the reviewed fee.
        guard adjusted.amount >= minimumOutput else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable("custom_fee_would_create_dust_amount")
        }
        adjusted.fee = targetFee
        if adjusted.change > 0, adjusted.change < (minimumChange ?? minimumOutput) {
            let folded = adjusted.fee.addingReportingOverflow(adjusted.change)
            guard !folded.overflow else { throw SendTransactionSubmissionError.amountOutOfRange }
            adjusted.fee = folded.partialValue
            adjusted.change = 0
        }

        let amountAndFee = adjusted.amount.addingReportingOverflow(
            adjusted.fee
        )
        guard !amountAndFee.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        let total = amountAndFee.partialValue.addingReportingOverflow(
            adjusted.change
        )
        guard !total.overflow,
              total.partialValue == adjusted.availableAmount else {
            throw SendTransactionSubmissionError.signing(
                code: "custom_fee_plan_invariant",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        return adjusted
    }

    static func outputs(
        from available: [SendBitcoinUTXO],
        selection: SendBitcoinCoinSelection
    ) throws -> [SendBitcoinUTXO] {
        switch selection {
        case .automatic:
            return available
        case let .manual(requested):
            let availableByID = Dictionary(
                uniqueKeysWithValues: available.map { ($0.id, $0) }
            )
            let resolved = requested.compactMap {
                availableByID[$0.id]
            }
            guard resolved.count == requested.count else {
                throw SendTransactionSubmissionError.signing(
                    code: "selected_utxo_spent",
                    message: WalletLocalization.string(
                        "send.submit.error.selected_utxo_spent"
                    )
                )
            }
            return resolved
        }
    }

    static func minimumExpectedUTXOValue(
        draft: SendDraft,
        requestedAtomic: String
    ) -> String {
        guard let balanceAtomic = draft.asset.balanceAtomic,
              SendAtomicAmount.isCanonical(balanceAtomic),
              SendAtomicAmount.compare(
                  balanceAtomic,
                  requestedAtomic
              ) != .orderedAscending else {
            return requestedAtomic
        }
        return balanceAtomic
    }

    static func signingInput(
        draft: SendDraft,
        accountMarker: String?,
        nestedSegwitPublicKey: PublicKey?,
        chain: BitcoinFamilyChain,
        outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64,
        byteFee: Int64,
        options: SendBitcoinFamilyOptions,
        senderAddress: String,
        recipientAddress: String
    ) throws -> BitcoinSigningInput {
        let lockScript = BitcoinScript.lockScriptForAddress(
            address: senderAddress,
            coin: chain.coin
        )
        guard !lockScript.data.isEmpty else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        let sequence = options.inputSequence(for: chain)
        let utxos: [BitcoinUnspentTransaction] = try outputs.map {
            output in
            guard let hash = Data(
                bitcoinHex: output.outpoint.transactionHash
            ), hash.count == 32 else {
                throw SendTransactionSubmissionError.signing(
                    code: "invalid_utxo_hash",
                    message: WalletLocalization.string(
                        "send.submit.error.provider_invalid_response"
                    )
                )
            }
            let outputIndex = try Self.checkedWireOutputIndex(
                output.outpoint.outputIndex,
                networkID: chain.networkID
            )
            return try BitcoinUnspentTransaction.with {
                $0.outPoint.hash = Data(hash.reversed())
                $0.outPoint.index = outputIndex
                $0.outPoint.sequence = sequence
                $0.script = lockScript.data
                $0.amount = try SendAtomicAmount.int64(
                    output.valueAtomic
                )
            }
        }

        var scripts: [String: Data] = [:]
        if PrivateKeyImportFormat(
            accountMarker: accountMarker
        ) == .extendedNestedSegwit {
            guard let nestedSegwitPublicKey else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            let scriptHash = lockScript.matchPayToScriptHash()
            if let scriptHash {
                scripts[scriptHash.hexString] = BitcoinScript
                    .buildPayToWitnessPubkeyHash(
                        hash: nestedSegwitPublicKey.bitcoinKeyHash
                    ).data
            }
        }

        let opReturnPayload = try SendBitcoinOPReturn.payload(
            for: options.opReturnMessage
        )

        return BitcoinSigningInput.with {
            $0.hashType = BitcoinScript.hashTypeForCoin(
                coinType: chain.coin
            )
            $0.amount = requestedAtomic
            $0.byteFee = byteFee
            $0.toAddress = recipientAddress
            $0.changeAddress = senderAddress
            $0.coinType = chain.coin.rawValue
            let recipientScript = BitcoinScript.lockScriptForAddress(address: recipientAddress, coin: chain.coin).data
            $0.fixedDustThreshold = SendBitcoinDustPolicy.changeMinimum(chain: chain, script: lockScript.data)
            // The final shared planner validates recipient and change separately.
            // This default also keeps standalone Wallet Core plans conservative.
            if chain != .dogecoin {
                $0.fixedDustThreshold = max($0.fixedDustThreshold,
                    SendBitcoinDustPolicy.recipientMinimum(chain: chain, script: recipientScript))
            }
            $0.useMaxUtxo = !options.coinSelection.selectedUTXOs.isEmpty
            $0.disableDustFilter = $0.useMaxUtxo
            $0.utxo = utxos
            $0.useMaxAmount = draft.usesMaximumBalance
            $0.scripts = scripts
            if let opReturnPayload {
                $0.outputOpReturn = opReturnPayload
            }
        }
    }

    static func checkedWireOutputIndex(
        _ outputIndex: Int,
        networkID: String
    ) throws -> UInt32 {
        guard let value = UInt32(exactly: outputIndex) else {
            throw SendTransactionSubmissionError.signing(
                code: "invalid_utxo_output_index",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        return value
    }

    static func planError(
        _ plan: BitcoinTransactionPlan
    ) -> SendTransactionSubmissionError {
        if plan.error == .errorNotEnoughUtxos
            || plan.error == .errorLowBalance
            || plan.error == .errorMissingInputUtxos {
            return .insufficientAssetBalance
        }
        return .signing(
            code: String(plan.error.rawValue),
            message: SendTransactionSubmissionError
                .sanitizedMessage(String(describing: plan.error))
        )
    }

    private static func repositoryError(
        _ error: SendBitcoinUTXORepositoryError,
        networkID: String
    ) -> SendTransactionSubmissionError {
        switch error {
        case .selectedWalletUnavailable:
            return .walletUnavailable
        case .accountUnavailable:
            return .accountUnavailable
        case .invalidAccountAddress:
            return .derivedAddressMismatch
        case let .provider(code):
            return .provider(
                networkID: networkID,
                code: code,
                message: error.localizedMessage
            )
        case let .invalidResponse(code):
            return .provider(
                networkID: networkID,
                code: code,
                message: error.localizedMessage
            )
        case .tooManyOutputs:
            return .provider(
                networkID: networkID,
                code: "too_many_outputs",
                message: error.localizedMessage
            )
        }
    }

    private static func validTransactionHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

}
