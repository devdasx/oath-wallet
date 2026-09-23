import Foundation
import WalletCore

struct SendBitcoinSignedTransaction: Sendable {
    let encoded: Data
    let transactionID: String
    let amountAtomic: String
    let feeAtomic: String
    let changeAddress: String?
    let spentOutpointIDs: Set<String>

    init(
        encoded: Data,
        transactionID: String,
        amountAtomic: String,
        feeAtomic: String,
        changeAddress: String?,
        spentOutpointIDs: Set<String> = []
    ) {
        self.encoded = encoded
        self.transactionID = transactionID
        self.amountAtomic = amountAtomic
        self.feeAtomic = feeAtomic
        self.changeAddress = changeAddress
        self.spentOutpointIDs = spentOutpointIDs
    }
}

enum SendBitcoinHDTransactionSigner {
    struct OwnedInput {
        let output: SendBitcoinUTXO
        let owner: BitcoinHDDerivedAddress
        let privateKey: PrivateKey
        let publicKey: PublicKey
    }

    static func sign(
        draft: SendDraft,
        material: SendResolvedSigningMaterial,
        outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64,
        byteFee: Int64,
        fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions,
        changeAddress: String,
        recipientAddress: String
    ) throws -> SendBitcoinSignedTransaction {
        guard let credential = material.bitcoinHDRecoveryCredential else {
            throw SendTransactionSubmissionError.secretUnavailable
        }
        let owned = try ownedInputs(outputs, credential: credential)
        let silentPaymentAddress = try? BitcoinSilentPaymentAddress(
            recipientAddress
        )
        return try signV2(
            draft: draft,
            inputs: owned,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            fee: fee,
            options: options,
            changeAddress: changeAddress,
            recipientAddress: recipientAddress,
            silentPaymentAddress: silentPaymentAddress
        )
    }

    private static func ownedInputs(
        _ outputs: [SendBitcoinUTXO],
        credential: WalletRecoveryCredential
    ) throws -> [OwnedInput] {
        let derivation = BitcoinHDDerivationService()
        return try outputs.map { output in
            guard let owner = output.owner else {
                throw SendTransactionSubmissionError.signing(
                    code: "missing_bitcoin_utxo_owner",
                    message: WalletLocalization.string(
                        "send.submit.error.provider_invalid_response"
                    )
                )
            }
            guard let location = BitcoinHDAddressType.location(
                for: owner.derivationPath, addressType: owner.addressType
            ), location.addressType == owner.addressType,
               location.branch == owner.branch,
               location.index == owner.index else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            let privateKey = try derivation.privateKey(
                credential: credential,
                addressType: location.addressType,
                branch: location.branch,
                index: location.index
            )
            let derived = try derivation.deriveAddress(
                credential: credential,
                addressType: location.addressType,
                branch: location.branch,
                index: location.index
            )
            guard derived == owner,
                  privateKey.getPublicKeySecp256k1(compressed: true).data
                    == owner.publicKey else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            return OwnedInput(
                output: output,
                owner: owner,
                privateKey: privateKey,
                publicKey: privateKey.getPublicKeySecp256k1(
                    compressed: true
                )
            )
        }
    }

    private static func signLegacy(
        draft: SendDraft,
        inputs: [OwnedInput],
        requestedAtomic: Int64,
        byteFee: Int64,
        fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions,
        changeAddress: String,
        recipientAddress: String
    ) throws -> SendBitcoinSignedTransaction {
        let sequence = options.inputSequence(for: .bitcoin)
        let utxos: [BitcoinUnspentTransaction] = try inputs.map { input in
            guard input.owner.addressType != .bip86,
                  let hash = Data(
                      bitcoinHex: input.output.outpoint.transactionHash
                  ), hash.count == 32 else {
                throw invalidProviderResponse(code: "invalid_hd_utxo")
            }
            return try BitcoinUnspentTransaction.with {
                $0.outPoint.hash = Data(hash.reversed())
                $0.outPoint.index = try SendBitcoinTransactionService
                    .checkedWireOutputIndex(
                        input.output.outpoint.outputIndex,
                        networkID: BitcoinFamilyChain.bitcoin.networkID
                    )
                $0.outPoint.sequence = sequence
                $0.script = input.owner.scriptPubKey
                $0.amount = try SendAtomicAmount.int64(
                    input.output.valueAtomic
                )
            }
        }
        var scripts: [String: Data] = [:]
        for input in inputs
        where input.owner.addressType == .bip49 {
            let lockScript = BitcoinScript.lockScriptForAddress(
                address: input.owner.address,
                coin: .bitcoin
            )
            guard let scriptHash = lockScript.matchPayToScriptHash()
            else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            scripts[scriptHash.hexString] = BitcoinScript
                .buildPayToWitnessPubkeyHash(
                    hash: input.publicKey.bitcoinKeyHash
                ).data
        }

        let opReturnPayload = try SendBitcoinOPReturn.payload(
            for: options.opReturnMessage
        )

        var signingInput = BitcoinSigningInput.with {
            $0.hashType = BitcoinScript.hashTypeForCoin(
                coinType: .bitcoin
            )
            $0.amount = requestedAtomic
            $0.byteFee = byteFee
            $0.toAddress = recipientAddress
            $0.changeAddress = changeAddress
            $0.coinType = CoinType.bitcoin.rawValue
            $0.utxo = utxos
            $0.useMaxAmount = draft.usesMaximumBalance
            $0.scripts = scripts
            if let opReturnPayload {
                $0.outputOpReturn = opReturnPayload
            }
        }
        var plan: BitcoinTransactionPlan = AnySigner.plan(
            input: signingInput,
            coin: .bitcoin
        )
        guard plan.error == .ok else {
            throw SendBitcoinTransactionService.planError(plan)
        }
        plan = try SendBitcoinTransactionService
            .applyingCustomFeeBudget(
                fee,
                to: plan,
                usesMaximumBalance: draft.usesMaximumBalance
            )
        signingInput.privateKey = uniquePrivateKeys(inputs)
        signingInput.plan = plan
        let output: BitcoinSigningOutput = AnySigner.sign(
            input: signingInput,
            coin: .bitcoin
        )
        guard output.error == .ok,
              !output.encoded.isEmpty,
              validTransactionID(output.transactionID) else {
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
            changeAddress: plan.change > 0 ? changeAddress : nil
        )
    }

    static func signV2(
        draft: SendDraft,
        inputs: [OwnedInput],
        requestedAtomic: Int64,
        byteFee: Int64,
        fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions,
        changeAddress: String,
        recipientAddress: String,
        silentPaymentAddress: BitcoinSilentPaymentAddress?
    ) throws -> SendBitcoinSignedTransaction {
        let prepared = try SendBitcoinHDTransactionPlanner.prepare(
            draft: draft, outputs: inputs.map(\.output),
            requestedAtomic: requestedAtomic, byteFee: byteFee,
            fee: fee, options: options, changeAddress: changeAddress,
            recipientAddress: recipientAddress
        )
        var signing = prepared.signing
        let plan = prepared.plan
        let ownedByID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.output.id, $0) })
        let selected = try prepared.inputs.map { input in
            guard let owned = ownedByID[input.output.id] else {
                throw invalidProviderResponse(code: "v2_plan_selected_unknown_input")
            }
            return owned
        }
        if let silentPaymentAddress {
            let destination = try BitcoinSilentPaymentCrypto.destination(
                address: silentPaymentAddress,
                inputs: try silentPaymentInputSecrets(selected)
            )
            signing = try SendBitcoinV2OutputBuilder.replacingRecipientScript(
                in: signing,
                with: destination.scriptPubKey
            )
        }
        signing.privateKeys = uniquePrivateKeys(selected)
        let finalWrapper = BitcoinSigningInput.with {
            $0.coinType = CoinType.bitcoin.rawValue
            $0.signingV2 = signing
        }
        let legacyOutput: BitcoinSigningOutput = AnySigner.sign(
            input: finalWrapper,
            coin: .bitcoin
        )
        guard legacyOutput.hasSigningResultV2 else {
            throw invalidProviderResponse(code: "missing_v2_output")
        }
        let output = legacyOutput.signingResultV2
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SendTransactionSubmissionError.signing(
                code: String(output.error.rawValue),
                message: SendTransactionSubmissionError
                    .sanitizedMessage(output.errorMessage)
            )
        }
        let nestedPublicKeys = Dictionary(
            uniqueKeysWithValues: selected.compactMap { input in
                input.owner.addressType == .bip49
                    ? (input.output.id, input.publicKey.data)
                    : nil
            }
        )
        let finalized = try SendBitcoinNestedSegwitTransaction.finalize(
            encoded: output.encoded,
            nestedPublicKeysByOutpointID: nestedPublicKeys
        )
        guard finalized.patchedOutpointIDs
                == Set(nestedPublicKeys.keys),
              validTransactionID(finalized.transactionID) else {
            throw invalidProviderResponse(
                code: "missing_nested_segwit_input"
            )
        }
        try SendBitcoinTransactionPolicy.validateVirtualSize(finalized.virtualSize)
        let actualMinimumFee = try checkedMultiply(
            finalized.virtualSize,
            byteFee
        )
        guard output.fee >= actualMinimumFee else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("bitcoin_fee_below_signed_vsize")
        }
        if String(output.fee) != prepared.feeAtomic {
            throw SendTransactionSubmissionError.signing(
                code: "bitcoin_custom_fee_mismatch",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        let amount: Int64
        if draft.usesMaximumBalance {
            let result = plan.availableAmount.subtractingReportingOverflow(
                output.fee
            )
            guard !result.overflow, result.partialValue > 0 else {
                throw SendTransactionSubmissionError
                    .insufficientAssetBalance
            }
            amount = result.partialValue
        } else {
            amount = requestedAtomic
        }
        let spent = amount.addingReportingOverflow(output.fee)
        guard !spent.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        let hasChange = !draft.usesMaximumBalance
            && plan.availableAmount > spent.partialValue
        return SendBitcoinSignedTransaction(
            encoded: finalized.encoded,
            transactionID: finalized.transactionID,
            amountAtomic: String(amount),
            feeAtomic: String(output.fee),
            changeAddress: hasChange ? changeAddress : nil
        )
    }

    private static func silentPaymentInputSecrets(
        _ inputs: [OwnedInput]
    ) throws -> [BitcoinSilentPaymentInputSecret] {
        try inputs.map { input in
            guard let transactionHash = Data(
                bitcoinHex: input.output.outpoint.transactionHash
            ), transactionHash.count == 32,
            let outputIndex = input.output.outpoint.wireOutputIndex else {
                throw invalidProviderResponse(
                    code: "invalid_silent_payment_outpoint"
                )
            }
            var littleEndianIndex = outputIndex.littleEndian
            let serializedIndex = withUnsafeBytes(
                of: &littleEndianIndex
            ) { Data($0) }
            let privateKey = if input.owner.addressType == .bip86 {
                try BitcoinSilentPaymentCrypto.taprootKeyPathPrivateKey(
                    internalPrivateKey: input.privateKey.data
                )
            } else {
                input.privateKey.data
            }
            return try BitcoinSilentPaymentInputSecret(
                outpoint: Data(transactionHash.reversed())
                    + serializedIndex,
                privateKey: privateKey,
                isTaproot: input.owner.addressType == .bip86
            )
        }
    }

    private static func checkedMultiply(
        _ left: Int64,
        _ right: Int64
    ) throws -> Int64 {
        let result = left.multipliedReportingOverflow(by: right)
        guard !result.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result.partialValue
    }

    private static func uniquePrivateKeys(
        _ inputs: [OwnedInput]
    ) -> [Data] {
        Array(Set(inputs.map(\.privateKey.data))).sorted {
            $0.lexicographicallyPrecedes($1)
        }
    }

    private static func invalidProviderResponse(
        code: String
    ) -> SendTransactionSubmissionError {
        .signing(
            code: code,
            message: WalletLocalization.string(
                "send.submit.error.provider_invalid_response"
            )
        )
    }

    private static func validTransactionID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}
