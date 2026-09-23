import CryptoKit
import Foundation
import P256K
import WalletCore

enum SendMuunRecoveryTransactionSigner {
    private struct InputMaterial {
        let output: SendBitcoinUTXO
        let owner: MuunRecoveryDerivedAddress
        let value: Int64
        let userPrivateKey: Data
        let muunPrivateKey: Data
        let userPublicKey: Data
        let muunPublicKey: Data
        let multisigScript: Data
        let taprootPrivateKey: Data?
    }

    private struct TransactionOutput {
        let value: Int64
        let scriptPubKey: Data
    }

    private struct InputSignatures {
        let user: Data?
        let muun: Data?
        let taproot: Data?
    }

    private struct Selection {
        let inputs: [InputMaterial]
        let sendAmount: Int64
        let fee: Int64
        let change: Int64
    }

    private static let tapSighashTag = Data("TapSighash".utf8)

    static func sign(
        draft: SendDraft,
        material: MuunRecoveryKeyMaterial,
        outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64,
        byteFee: Int64,
        fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions,
        changeAddress: String,
        recipientAddress: String
    ) throws -> SendBitcoinSignedTransaction {
        guard !outputs.isEmpty, byteFee > 0 else {
            throw SendTransactionSubmissionError.secretUnavailable
        }
        let allInputs = try inputMaterials(
            outputs: outputs,
            material: material
        )
        let silentAddress = try? BitcoinSilentPaymentAddress(
            recipientAddress
        )
        let inputs = try eligibleInputs(
            allInputs,
            silentAddress: silentAddress,
            options: options
        )
        let changeScript = BitcoinScript.lockScriptForAddress(
            address: changeAddress,
            coin: .bitcoin
        ).data
        guard !changeScript.isEmpty else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        let recipientScriptSize = silentAddress == nil
            ? BitcoinScript.lockScriptForAddress(
                address: recipientAddress,
                coin: .bitcoin
            ).data.count
            : 34
        guard recipientScriptSize > 0 else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        let opReturnScript = try SendBitcoinOPReturn.scriptPubKey(
            for: options.opReturnMessage
        )
        let selection = try select(
            inputs: inputs,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            customFee: try fee.totalBudgetAtomic.map(
                SendAtomicAmount.int64
            ),
            recipientScriptSize: recipientScriptSize,
            changeScriptSize: changeScript.count,
            opReturnScriptSize: opReturnScript?.count,
            usesMaximumBalance: draft.usesMaximumBalance,
            automatic: options.coinSelection.selectedUTXOs.isEmpty
        )
        let recipientScript: Data
        if let silentAddress {
            recipientScript = try BitcoinSilentPaymentCrypto.destination(
                address: silentAddress,
                inputs: try selection.inputs.map(silentPaymentInput)
            ).scriptPubKey
        } else {
            recipientScript = BitcoinScript.lockScriptForAddress(
                address: recipientAddress,
                coin: .bitcoin
            ).data
        }
        var transactionOutputs = [
            TransactionOutput(
                value: selection.sendAmount,
                scriptPubKey: recipientScript
            )
        ]
        if let opReturnScript {
            transactionOutputs.append(
                TransactionOutput(value: 0, scriptPubKey: opReturnScript)
            )
        }
        if selection.change > 0 {
            transactionOutputs.append(
                TransactionOutput(
                    value: selection.change,
                    scriptPubKey: changeScript
                )
            )
        }
        let sequence = options.inputSequence(for: .bitcoin)
        let signatures = try signatures(
            inputs: selection.inputs,
            outputs: transactionOutputs,
            sequence: sequence
        )
        let encoded = try serializeTransaction(
            inputs: selection.inputs,
            outputs: transactionOutputs,
            signatures: signatures,
            sequence: sequence,
            includeWitness: true
        )
        let stripped = try serializeTransaction(
            inputs: selection.inputs,
            outputs: transactionOutputs,
            signatures: signatures,
            sequence: sequence,
            includeWitness: false
        )
        let weight = try transactionWeight(
            encoded: encoded,
            stripped: stripped
        )
        try SendBitcoinTransactionPolicy.validateWeight(weight)
        let virtualSize = (weight + 3) / 4
        let requiredFee = try checkedMultiply(virtualSize, byteFee)
        guard selection.fee >= requiredFee else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("bitcoin_fee_below_signed_vsize")
        }
        if let budget = fee.totalBudgetAtomic,
           !SendBitcoinDustPolicy.allowsFee(selection.fee, budget: try SendAtomicAmount.int64(budget),
                change: selection.change,
                minimumChange: SendBitcoinDustPolicy.bitcoinMinimum(scriptSize: changeScript.count)) {
            throw invalidResponse("bitcoin_custom_fee_mismatch")
        }
        let transactionID = Data(
            doubleSHA256(stripped).reversed()
        ).hexString
        guard transactionID.count == 64 else {
            throw invalidResponse("muun_recovery_transaction_id")
        }
        return SendBitcoinSignedTransaction(
            encoded: encoded,
            transactionID: transactionID,
            amountAtomic: String(selection.sendAmount),
            feeAtomic: String(selection.fee),
            changeAddress: selection.change > 0 ? changeAddress : nil,
            spentOutpointIDs: Set(selection.inputs.map(\.output.id))
        )
    }

    static func estimatedNetworkFeeAtomic(
        outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64,
        byteFee: Int64,
        totalBudgetAtomic: String?,
        options: SendBitcoinFamilyOptions,
        recipientAddress: String,
        usesMaximumBalance: Bool
    ) throws -> String {
        try selectionPlan(
            outputs: outputs,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            totalBudgetAtomic: totalBudgetAtomic,
            options: options,
            recipientAddress: recipientAddress,
            usesMaximumBalance: usesMaximumBalance
        ).feeAtomic
    }

    static func selectionPlan(
        outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64,
        byteFee: Int64,
        totalBudgetAtomic: String?,
        options: SendBitcoinFamilyOptions,
        recipientAddress: String,
        usesMaximumBalance: Bool
    ) throws -> SendBitcoinSelectionPlan {
        let silentAddress = try? BitcoinSilentPaymentAddress(
            recipientAddress
        )
        let inputs = try estimatedInputMaterials(outputs: outputs)
        let eligible = try eligibleInputs(
            inputs,
            silentAddress: silentAddress,
            options: options
        )
        let recipientScriptSize = silentAddress == nil
            ? BitcoinScript.lockScriptForAddress(
                address: recipientAddress,
                coin: .bitcoin
            ).data.count
            : 34
        guard recipientScriptSize > 0 else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        let opReturnScript = try SendBitcoinOPReturn.scriptPubKey(
            for: options.opReturnMessage
        )
        let selection = try select(
            inputs: eligible,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            customFee: try totalBudgetAtomic.map(SendAtomicAmount.int64),
            recipientScriptSize: recipientScriptSize,
            changeScriptSize: 34,
            opReturnScriptSize: opReturnScript?.count,
            usesMaximumBalance: usesMaximumBalance,
            automatic: options.coinSelection.selectedUTXOs.isEmpty
        )
        return SendBitcoinSelectionPlan(
            outputs: selection.inputs.map(\.output), feeAtomic: String(selection.fee)
        )
    }

    private static func inputMaterials(
        outputs: [SendBitcoinUTXO],
        material: MuunRecoveryKeyMaterial
    ) throws -> [InputMaterial] {
        try outputs.map { output in
            guard output.networkID == BitcoinFamilyChain.bitcoin.networkID,
                  output.owner == nil,
                  output.silentPaymentOwner == nil,
                  let owner = output.muunOwner else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            let derived = try MuunRecoveryAddressFactory.derive(
                material: material,
                version: owner.version,
                branch: owner.branch,
                contactIndex: owner.contactIndex,
                addressIndex: owner.addressIndex
            )
            let keys = try MuunRecoveryDerivation.keys(
                material: material,
                branch: owner.branch,
                contactIndex: owner.contactIndex,
                addressIndex: owner.addressIndex
            )
            guard derived == owner,
                  owner.derivationPath == keys.derivationPath,
                  let userPrivateKey = keys.user.privateKey,
                  let muunPrivateKey = keys.muun.privateKey else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            let multisigScript = MuunRecoveryAddressFactory
                .multisigScript(
                    userPublicKey: keys.user.publicKey,
                    muunPublicKey: keys.muun.publicKey
                )
            let taprootPrivateKey = owner.version == .v5
                ? try MuunRecoveryAddressFactory.taprootOutputPrivateKey(
                    userPrivateKey: userPrivateKey,
                    muunPrivateKey: muunPrivateKey
                )
                : nil
            if let taprootPrivateKey {
                let outputKey = try xOnlyPublicKey(taprootPrivateKey)
                guard owner.scriptPubKey
                    == Data([0x51, 0x20]) + outputKey else {
                    throw SendTransactionSubmissionError
                        .derivedAddressMismatch
                }
            }
            let value = try SendAtomicAmount.int64(output.valueAtomic)
            guard value > 0 else { throw invalidResponse("input_value") }
            return InputMaterial(
                output: output,
                owner: owner,
                value: value,
                userPrivateKey: userPrivateKey,
                muunPrivateKey: muunPrivateKey,
                userPublicKey: keys.user.publicKey,
                muunPublicKey: keys.muun.publicKey,
                multisigScript: multisigScript,
                taprootPrivateKey: taprootPrivateKey
            )
        }
    }

    private static func estimatedInputMaterials(
        outputs: [SendBitcoinUTXO]
    ) throws -> [InputMaterial] {
        try outputs.map { output in
            guard output.networkID == BitcoinFamilyChain.bitcoin.networkID,
                  output.owner == nil,
                  output.silentPaymentOwner == nil,
                  let owner = output.muunOwner else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            let value = try SendAtomicAmount.int64(output.valueAtomic)
            guard value > 0 else { throw invalidResponse("input_value") }
            return InputMaterial(
                output: output,
                owner: owner,
                value: value,
                userPrivateKey: Data(),
                muunPrivateKey: Data(),
                userPublicKey: Data(repeating: 0, count: 33),
                muunPublicKey: Data(repeating: 0, count: 33),
                multisigScript: Data(repeating: 0, count: 71),
                taprootPrivateKey: owner.version == .v5 ? Data() : nil
            )
        }
    }

    private static func eligibleInputs(
        _ inputs: [InputMaterial],
        silentAddress: BitcoinSilentPaymentAddress?,
        options: SendBitcoinFamilyOptions
    ) throws -> [InputMaterial] {
        guard silentAddress != nil else { return inputs }
        switch options.coinSelection {
        case .automatic:
            let eligible = inputs.filter { $0.owner.version == .v5 }
            guard !eligible.isEmpty else {
                throw SendTransactionSubmissionError
                    .insufficientAssetBalance
            }
            return eligible
        case .manual:
            guard inputs.allSatisfy({ $0.owner.version == .v5 }) else {
                throw SendTransactionSubmissionError.signing(
                    code: "muun_silent_payment_requires_v5_inputs",
                    message: WalletLocalization.string(
                        "send.submit.error.provider_invalid_response"
                    )
                )
            }
            return inputs
        }
    }

    private static func select(
        inputs: [InputMaterial],
        requestedAtomic: Int64,
        byteFee: Int64,
        customFee: Int64?,
        recipientScriptSize: Int,
        changeScriptSize: Int,
        opReturnScriptSize: Int?,
        usesMaximumBalance: Bool,
        automatic: Bool
    ) throws -> Selection {
        let recipientMinimum = SendBitcoinDustPolicy.bitcoinMinimum(scriptSize: recipientScriptSize)
        let changeMinimum = SendBitcoinDustPolicy.bitcoinMinimum(scriptSize: changeScriptSize)
        let candidates = automatic
            ? inputs.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.output.id < $1.output.id
            }
            : inputs
        guard !candidates.isEmpty else {
            throw SendTransactionSubmissionError.insufficientAssetBalance
        }
        if usesMaximumBalance {
            let available = try sum(candidates.map(\.value))
            let minimumFee = try estimatedFee(
                inputs: candidates,
                outputScriptSizes: outputScriptSizes(
                    recipientScriptSize,
                    opReturnScriptSize: opReturnScriptSize
                ),
                byteFee: byteFee
            )
            let targetFee = customFee ?? minimumFee
            guard targetFee >= minimumFee else {
                throw SendTransactionSubmissionError
                    .feeQuoteUnavailable(
                        "custom_fee_budget_below_required"
                    )
            }
            let amount = try checkedSubtract(available, targetFee)
            guard amount >= recipientMinimum else {
                throw SendTransactionSubmissionError
                    .insufficientAssetBalance
            }
            return Selection(
                inputs: candidates,
                sendAmount: amount,
                fee: targetFee,
                change: 0
            )
        }
        guard requestedAtomic >= recipientMinimum else {
            throw SendTransactionSubmissionError.invalidAmount
        }
        var selected: [InputMaterial] = []
        var available: Int64 = 0
        for input in candidates {
            selected.append(input)
            available = try checkedAdd(available, input.value)
            if !automatic, selected.count < candidates.count { continue }
            let minimumFee = try estimatedFee(
                inputs: selected,
                outputScriptSizes: outputScriptSizes(
                    recipientScriptSize,
                    changeScriptSize,
                    opReturnScriptSize: opReturnScriptSize
                ),
                byteFee: byteFee
            )
            let targetFee = customFee ?? minimumFee
            guard targetFee >= minimumFee else {
                throw SendTransactionSubmissionError
                    .feeQuoteUnavailable(
                        "custom_fee_budget_below_required"
                    )
            }
            let required = try checkedAdd(requestedAtomic, targetFee)
            guard available >= required else { continue }
            let change = try checkedSubtract(available, required)
            if change == 0 || change >= changeMinimum {
                return Selection(
                    inputs: selected,
                    sendAmount: requestedAtomic,
                    fee: targetFee,
                    change: change
                )
            }
            let oneOutputFee = try estimatedFee(
                inputs: selected,
                outputScriptSizes: outputScriptSizes(
                    recipientScriptSize,
                    opReturnScriptSize: opReturnScriptSize
                ),
                byteFee: byteFee
            )
            let consumedFee = try checkedSubtract(
                available,
                requestedAtomic
            )
            if consumedFee >= oneOutputFee {
                return Selection(
                    inputs: selected,
                    sendAmount: requestedAtomic,
                    fee: consumedFee,
                    change: 0
                )
            }
        }
        throw SendTransactionSubmissionError.insufficientAssetBalance
    }

    private static func outputScriptSizes(
        _ standardSizes: Int...,
        opReturnScriptSize: Int?
    ) -> [Int] {
        standardSizes + (opReturnScriptSize.map { [$0] } ?? [])
    }

    private static func estimatedFee(
        inputs: [InputMaterial],
        outputScriptSizes: [Int],
        byteFee: Int64
    ) throws -> Int64 {
        let hasWitness = inputs.contains { $0.owner.version != .v2 }
        var baseSize = 4 + compactSizeLength(inputs.count) + 4
        var witnessSize = hasWitness ? 2 : 0
        for input in inputs {
            switch input.owner.version {
            case .v2:
                baseSize += 262
                if hasWitness { witnessSize += 1 }
            case .v3:
                baseSize += 76
                witnessSize += 222
            case .v4:
                baseSize += 41
                witnessSize += 222
            case .v5:
                baseSize += 41
                witnessSize += 66
            }
        }
        baseSize += compactSizeLength(outputScriptSizes.count)
        for scriptSize in outputScriptSizes {
            guard scriptSize > 0 else {
                throw invalidResponse("output_script")
            }
            baseSize += 8 + compactSizeLength(scriptSize) + scriptSize
        }
        let weight = try checkedAdd(
            try checkedMultiply(Int64(baseSize), 4),
            Int64(witnessSize)
        )
        try SendBitcoinTransactionPolicy.validateWeight(weight)
        let virtualSize = (weight + 3) / 4
        return try checkedMultiply(virtualSize, byteFee)
    }

    private static func silentPaymentInput(
        _ input: InputMaterial
    ) throws -> BitcoinSilentPaymentInputSecret {
        guard input.owner.version == .v5,
              let privateKey = input.taprootPrivateKey else {
            throw invalidResponse("muun_silent_payment_input")
        }
        return try BitcoinSilentPaymentInputSecret(
            outpoint: serializedOutpoint(input.output),
            privateKey: privateKey,
            isTaproot: true
        )
    }

    private static func signatures(
        inputs: [InputMaterial],
        outputs: [TransactionOutput],
        sequence: UInt32
    ) throws -> [InputSignatures] {
        try inputs.indices.map { index in
            let input = inputs[index]
            switch input.owner.version {
            case .v2:
                let digest = try legacySignatureHash(
                    inputs: inputs,
                    outputs: outputs,
                    signingIndex: index,
                    sequence: sequence
                )
                return InputSignatures(
                    user: try ecdsaSignature(
                        privateKey: input.userPrivateKey,
                        digest: digest
                    ),
                    muun: try ecdsaSignature(
                        privateKey: input.muunPrivateKey,
                        digest: digest
                    ),
                    taproot: nil
                )
            case .v3, .v4:
                let digest = try segwitV0SignatureHash(
                    inputs: inputs,
                    outputs: outputs,
                    signingIndex: index,
                    sequence: sequence
                )
                return InputSignatures(
                    user: try ecdsaSignature(
                        privateKey: input.userPrivateKey,
                        digest: digest
                    ),
                    muun: try ecdsaSignature(
                        privateKey: input.muunPrivateKey,
                        digest: digest
                    ),
                    taproot: nil
                )
            case .v5:
                guard let privateKey = input.taprootPrivateKey else {
                    throw invalidResponse("missing_muun_taproot_key")
                }
                let digest = try taprootSignatureHash(
                    inputs: inputs,
                    outputs: outputs,
                    signingIndex: index,
                    sequence: sequence
                )
                let key = try P256K.Schnorr.PrivateKey(
                    dataRepresentation: privateKey
                )
                let hash = HashDigest(Array(digest))
                let signature = try key.signature(for: hash)
                guard key.xonly.isValidSignature(signature, for: hash)
                else {
                    throw invalidResponse("schnorr_signature")
                }
                return InputSignatures(
                    user: nil,
                    muun: nil,
                    taproot: signature.dataRepresentation
                )
            }
        }
    }

    private static func ecdsaSignature(
        privateKey: Data,
        digest: Data
    ) throws -> Data {
        let key = try P256K.Signing.PrivateKey(
            dataRepresentation: privateKey
        )
        let hash = HashDigest(Array(digest))
        let signature = key.signature(for: hash)
        guard key.publicKey.isValidSignature(signature, for: hash) else {
            throw invalidResponse("ecdsa_signature")
        }
        return signature.derRepresentation + Data([0x01])
    }

    private static func legacySignatureHash(
        inputs: [InputMaterial],
        outputs: [TransactionOutput],
        signingIndex: Int,
        sequence: UInt32
    ) throws -> Data {
        var data = Data()
        data.appendMuunUInt32LE(2)
        data.appendMuunCompactSize(inputs.count)
        for (index, input) in inputs.enumerated() {
            data.append(try serializedOutpoint(input.output))
            data.appendMuunScript(
                index == signingIndex ? input.multisigScript : Data()
            )
            data.appendMuunUInt32LE(sequence)
        }
        data.append(try serializedOutputs(outputs))
        data.appendMuunUInt32LE(0)
        data.appendMuunUInt32LE(1)
        return doubleSHA256(data)
    }

    private static func segwitV0SignatureHash(
        inputs: [InputMaterial],
        outputs: [TransactionOutput],
        signingIndex: Int,
        sequence: UInt32
    ) throws -> Data {
        let input = inputs[signingIndex]
        var prevouts = Data()
        var sequences = Data()
        for item in inputs {
            prevouts.append(try serializedOutpoint(item.output))
            sequences.appendMuunUInt32LE(sequence)
        }
        var data = Data()
        data.appendMuunUInt32LE(2)
        data.append(doubleSHA256(prevouts))
        data.append(doubleSHA256(sequences))
        data.append(try serializedOutpoint(input.output))
        data.appendMuunScript(input.multisigScript)
        data.appendMuunUInt64LE(UInt64(input.value))
        data.appendMuunUInt32LE(sequence)
        data.append(doubleSHA256(try serializedOutputsOnly(outputs)))
        data.appendMuunUInt32LE(0)
        data.appendMuunUInt32LE(1)
        return doubleSHA256(data)
    }

    private static func taprootSignatureHash(
        inputs: [InputMaterial],
        outputs: [TransactionOutput],
        signingIndex: Int,
        sequence: UInt32
    ) throws -> Data {
        var prevouts = Data()
        var amounts = Data()
        var scripts = Data()
        var sequences = Data()
        for input in inputs {
            prevouts.append(try serializedOutpoint(input.output))
            amounts.appendMuunUInt64LE(UInt64(input.value))
            scripts.appendMuunScript(input.owner.scriptPubKey)
            sequences.appendMuunUInt32LE(sequence)
        }
        var message = Data([0x00, 0x00])
        message.appendMuunUInt32LE(2)
        message.appendMuunUInt32LE(0)
        message.append(singleSHA256(prevouts))
        message.append(singleSHA256(amounts))
        message.append(singleSHA256(scripts))
        message.append(singleSHA256(sequences))
        message.append(singleSHA256(try serializedOutputsOnly(outputs)))
        message.append(0x00)
        guard let inputIndex = UInt32(exactly: signingIndex) else {
            throw invalidResponse("taproot_input_index")
        }
        message.appendMuunUInt32LE(inputIndex)
        return Data(SHA256.taggedHash(
            tag: tapSighashTag,
            data: message
        ))
    }

    private static func serializeTransaction(
        inputs: [InputMaterial],
        outputs: [TransactionOutput],
        signatures: [InputSignatures],
        sequence: UInt32,
        includeWitness: Bool
    ) throws -> Data {
        guard inputs.count == signatures.count else {
            throw invalidResponse("signature_count")
        }
        let hasWitness = inputs.contains { $0.owner.version != .v2 }
        var data = Data()
        data.appendMuunUInt32LE(2)
        if includeWitness, hasWitness {
            data.append(contentsOf: [0x00, 0x01])
        }
        data.appendMuunCompactSize(inputs.count)
        for (index, input) in inputs.enumerated() {
            data.append(try serializedOutpoint(input.output))
            let scriptSig = try inputScript(
                input: input,
                signatures: signatures[index]
            )
            data.appendMuunScript(scriptSig)
            data.appendMuunUInt32LE(sequence)
        }
        data.append(try serializedOutputs(outputs))
        if includeWitness, hasWitness {
            for (index, input) in inputs.enumerated() {
                try appendWitness(
                    to: &data,
                    input: input,
                    signatures: signatures[index]
                )
            }
        }
        data.appendMuunUInt32LE(0)
        return data
    }

    private static func inputScript(
        input: InputMaterial,
        signatures: InputSignatures
    ) throws -> Data {
        switch input.owner.version {
        case .v2:
            guard let user = signatures.user,
                  let muun = signatures.muun else {
                throw invalidResponse("missing_multisig_signatures")
            }
            return Data([0x00])
                + (try pushed(user))
                + (try pushed(muun))
                + (try pushed(input.multisigScript))
        case .v3:
            let redeem = Data([0x00, 0x20])
                + singleSHA256(input.multisigScript)
            return try pushed(redeem)
        case .v4, .v5:
            return Data()
        }
    }

    private static func appendWitness(
        to data: inout Data,
        input: InputMaterial,
        signatures: InputSignatures
    ) throws {
        switch input.owner.version {
        case .v2:
            data.appendMuunCompactSize(0)
        case .v3, .v4:
            guard let user = signatures.user,
                  let muun = signatures.muun else {
                throw invalidResponse("missing_multisig_signatures")
            }
            data.appendMuunCompactSize(4)
            data.appendMuunScript(Data())
            data.appendMuunScript(user)
            data.appendMuunScript(muun)
            data.appendMuunScript(input.multisigScript)
        case .v5:
            guard let signature = signatures.taproot else {
                throw invalidResponse("missing_taproot_signature")
            }
            data.appendMuunCompactSize(1)
            data.appendMuunScript(signature)
        }
    }

    private static func pushed(_ value: Data) throws -> Data {
        if value.count <= 75 {
            return Data([UInt8(value.count)]) + value
        }
        if value.count <= Int(UInt8.max) {
            return Data([0x4c, UInt8(value.count)]) + value
        }
        throw invalidResponse("script_push_size")
    }

    private static func serializedOutputs(
        _ outputs: [TransactionOutput]
    ) throws -> Data {
        var data = Data()
        data.appendMuunCompactSize(outputs.count)
        data.append(try serializedOutputsOnly(outputs))
        return data
    }

    private static func serializedOutputsOnly(
        _ outputs: [TransactionOutput]
    ) throws -> Data {
        var data = Data()
        for output in outputs {
            guard output.value >= 0 else {
                throw invalidResponse("negative_output")
            }
            data.appendMuunUInt64LE(UInt64(output.value))
            data.appendMuunScript(output.scriptPubKey)
        }
        return data
    }

    private static func serializedOutpoint(
        _ output: SendBitcoinUTXO
    ) throws -> Data {
        guard let hash = Data(
            bitcoinHex: output.outpoint.transactionHash
        ), hash.count == 32,
        let index = output.outpoint.wireOutputIndex else {
            throw invalidResponse("outpoint")
        }
        var data = Data(hash.reversed())
        data.appendMuunUInt32LE(index)
        return data
    }

    private static func xOnlyPublicKey(_ data: Data) throws -> Data {
        Data(try P256K.Signing.PrivateKey(
            dataRepresentation: data
        ).publicKey.xonly.bytes)
    }

    private static func singleSHA256(_ data: Data) -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }

    private static func doubleSHA256(_ data: Data) -> Data {
        singleSHA256(singleSHA256(data))
    }

    private static func transactionWeight(
        encoded: Data,
        stripped: Data
    ) throws -> Int64 {
        guard encoded.count >= stripped.count else {
            throw invalidResponse("transaction_weight")
        }
        return try checkedAdd(
            try checkedMultiply(Int64(stripped.count), 4),
            Int64(encoded.count - stripped.count)
        )
    }

    private static func sum(_ values: [Int64]) throws -> Int64 {
        try values.reduce(0, checkedAdd)
    }

    private static func checkedAdd(
        _ lhs: Int64,
        _ rhs: Int64
    ) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result.partialValue
    }

    private static func checkedSubtract(
        _ lhs: Int64,
        _ rhs: Int64
    ) throws -> Int64 {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result.partialValue
    }

    private static func checkedMultiply(
        _ lhs: Int64,
        _ rhs: Int64
    ) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result.partialValue
    }

    private static func compactSizeLength(_ value: Int) -> Int {
        if value < 0xfd { return 1 }
        if value <= Int(UInt16.max) { return 3 }
        if UInt64(value) <= UInt64(UInt32.max) { return 5 }
        return 9
    }

    private static func invalidResponse(
        _ code: String
    ) -> SendTransactionSubmissionError {
        .signing(
            code: code,
            message: WalletLocalization.string(
                "send.submit.error.provider_invalid_response"
            )
        )
    }
}

private extension Data {
    mutating func appendMuunCompactSize(_ value: Int) {
        if value < 0xfd {
            append(UInt8(value))
        } else if value <= Int(UInt16.max) {
            append(0xfd)
            appendMuunUInt16LE(UInt16(value))
        } else if UInt64(value) <= UInt64(UInt32.max) {
            append(0xfe)
            appendMuunUInt32LE(UInt32(value))
        } else {
            append(0xff)
            appendMuunUInt64LE(UInt64(value))
        }
    }

    mutating func appendMuunScript(_ script: Data) {
        appendMuunCompactSize(script.count)
        append(script)
    }

    mutating func appendMuunUInt16LE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) {
            append(contentsOf: $0)
        }
    }

    mutating func appendMuunUInt32LE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) {
            append(contentsOf: $0)
        }
    }

    mutating func appendMuunUInt64LE(_ value: UInt64) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) {
            append(contentsOf: $0)
        }
    }
}
