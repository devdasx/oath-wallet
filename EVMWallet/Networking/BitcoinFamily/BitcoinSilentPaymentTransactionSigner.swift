import CryptoKit
import Foundation
import P256K
import WalletCore

enum BitcoinSilentPaymentTransactionSigner {
    enum InputKind {
        case legacy
        case nestedSegwit
        case nativeSegwit
        case taproot
    }

    struct InputMaterial {
        let output: SendBitcoinUTXO
        let value: Int64
        let scriptPubKey: Data
        let privateKey: Data
        let publicKey: Data
        let kind: InputKind

        var isTaproot: Bool {
            if case .taproot = kind { return true }
            return false
        }
    }

    private struct TransactionOutput {
        let value: Int64
        let scriptPubKey: Data
    }

    struct Selection {
        let inputs: [InputMaterial]
        let sendAmount: Int64
        let fee: Int64
        let change: Int64
    }

    private static let tapSighashTag = Data("TapSighash".utf8)

    static func sign(
        draft: SendDraft,
        credential: WalletRecoveryCredential,
        outputs: [SendBitcoinUTXO],
        silentPaymentPrivateKeys: [String: Data],
        requestedAtomic: Int64,
        byteFee: Int64,
        fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions,
        changeAddress: String,
        recipientAddress: String
    ) throws -> SendBitcoinSignedTransaction {
        guard let wallet = credential.makeHDWallet(),
              !outputs.isEmpty,
              byteFee > 0 else {
            throw SendTransactionSubmissionError.secretUnavailable
        }
        let inputs = try inputMaterials(
            outputs: outputs,
            wallet: wallet,
            silentPaymentPrivateKeys: silentPaymentPrivateKeys
        )
        return try sign(
            draft: draft,
            inputs: inputs,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            fee: fee,
            options: options,
            changeAddress: changeAddress,
            recipientAddress: recipientAddress
        )
    }

    static func signSingleKey(
        draft: SendDraft,
        privateKey: Data,
        format: PrivateKeyImportFormat,
        outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64,
        byteFee: Int64,
        fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions,
        senderAddress: String,
        recipientAddress: String
    ) throws -> SendBitcoinSignedTransaction {
        guard let key = PrivateKey(data: privateKey),
              !outputs.isEmpty else {
            throw SendTransactionSubmissionError.secretUnavailable
        }
        let account = try BitcoinFamilyDerivationService().derive(
            privateKey: privateKey,
            chain: .bitcoin,
            format: format,
            derivationPath: format.accountMarker
        )
        guard account.address == senderAddress else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        let kind: InputKind
        switch format {
        case .wifUncompressed, .extendedLegacy:
            kind = .legacy
        case .extendedNestedSegwit:
            kind = .nestedSegwit
        case .rawSecp256k1, .wifCompressed, .extendedNativeSegwit:
            kind = .nativeSegwit
        case .solanaSeed, .solanaKeypair, .rawEd25519:
            throw SendTransactionSubmissionError.secretUnavailable
        }
        let publicKey = key.getPublicKeySecp256k1(
            compressed: format != .wifUncompressed
        ).data
        let inputs = try outputs.map { output in
            guard output.networkID == BitcoinFamilyChain.bitcoin.networkID,
                  output.owner == nil,
                  output.silentPaymentOwner == nil else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            let value = try SendAtomicAmount.int64(output.valueAtomic)
            guard value > 0 else { throw invalidResponse("input_value") }
            return InputMaterial(
                output: output,
                value: value,
                scriptPubKey: account.scriptPubKey,
                privateKey: privateKey,
                publicKey: publicKey,
                kind: kind
            )
        }
        return try sign(
            draft: draft,
            inputs: inputs,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            fee: fee,
            options: options,
            changeAddress: senderAddress,
            recipientAddress: recipientAddress
        )
    }



    static func sign(
        draft: SendDraft,
        inputs: [InputMaterial],
        requestedAtomic: Int64,
        byteFee: Int64,
        fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions,
        changeAddress: String,
        recipientAddress: String
    ) throws -> SendBitcoinSignedTransaction {
        let changeScript = BitcoinScript.lockScriptForAddress(
            address: changeAddress,
            coin: .bitcoin
        ).data
        guard !changeScript.isEmpty else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        let silentAddress = try? BitcoinSilentPaymentAddress(
            recipientAddress
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
                inputs: try selection.inputs.map(senderInputSecret)
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
            throw SendTransactionSubmissionError.signing(
                code: "bitcoin_custom_fee_mismatch",
                message: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        let transactionID = Data(
            doubleSHA256(stripped).reversed()
        ).hexString
        guard transactionID.count == 64 else {
            throw invalidResponse("silent_payment_transaction_id")
        }
        return SendBitcoinSignedTransaction(
            encoded: encoded,
            transactionID: transactionID,
            amountAtomic: String(selection.sendAmount),
            feeAtomic: String(selection.fee),
            changeAddress: selection.change > 0 ? changeAddress : nil,
            spentOutpointIDs: Set(
                selection.inputs.map(\.output.id)
            )
        )
    }

    private static func inputMaterials(
        outputs: [SendBitcoinUTXO],
        wallet: HDWallet,
        silentPaymentPrivateKeys: [String: Data]
    ) throws -> [InputMaterial] {
        let derivation = BitcoinHDDerivationService()
        return try outputs.map { output in
            let value = try SendAtomicAmount.int64(output.valueAtomic)
            guard value > 0 else { throw invalidResponse("input_value") }
            if let owner = output.owner {
                let location = BitcoinHDAddressLocation(
                    addressType: owner.addressType,
                    branch: owner.branch,
                    index: owner.index
                )
                guard owner.derivationPath == derivation.derivationPath(
                    addressType: location.addressType,
                    branch: location.branch,
                    index: location.index
                ) else {
                    throw SendTransactionSubmissionError
                        .derivedAddressMismatch
                }
                let walletCoreKey = try derivation.privateKey(
                    wallet: wallet,
                    addressType: location.addressType,
                    branch: location.branch,
                    index: location.index
                )
                let derived = try derivation.deriveAddress(
                    wallet: wallet,
                    addressType: location.addressType,
                    branch: location.branch,
                    index: location.index
                )
                guard derived == owner else {
                    throw SendTransactionSubmissionError
                        .derivedAddressMismatch
                }
                let privateKey: Data
                let publicKey: Data
                let kind: InputKind
                switch owner.addressType {
                case .bip44, .brdLegacy:
                    privateKey = walletCoreKey.data
                    publicKey = owner.publicKey
                    kind = .legacy
                case .bip49:
                    privateKey = walletCoreKey.data
                    publicKey = owner.publicKey
                    kind = .nestedSegwit
                case .bip84, .brdSegwit:
                    privateKey = walletCoreKey.data
                    publicKey = owner.publicKey
                    kind = .nativeSegwit
                case .bip86:
                    privateKey = try BitcoinSilentPaymentCrypto
                        .taprootKeyPathPrivateKey(
                            internalPrivateKey: walletCoreKey.data
                        )
                    publicKey = try xOnlyPublicKey(privateKey)
                    kind = .taproot
                }
                return InputMaterial(
                    output: output,
                    value: value,
                    scriptPubKey: owner.scriptPubKey,
                    privateKey: privateKey,
                    publicKey: publicKey,
                    kind: kind
                )
            }
            guard let silentOwner = output.silentPaymentOwner,
                  let storedKey = silentPaymentPrivateKeys[output.id],
                  silentOwner.transactionHash
                    == output.outpoint.transactionHash,
                  silentOwner.outputIndex == output.outpoint.outputIndex,
                  silentOwner.valueAtomic.decimalText == output.valueAtomic
            else {
                throw invalidResponse("missing_silent_payment_owner")
            }
            let privateKey = try normalizedXOnlyPrivateKey(storedKey)
            let publicKey = try xOnlyPublicKey(privateKey)
            guard publicKey == silentOwner.outputPublicKey,
                  silentOwner.scriptPubKey
                    == Data([0x51, 0x20]) + publicKey else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            return InputMaterial(
                output: output,
                value: value,
                scriptPubKey: silentOwner.scriptPubKey,
                privateKey: privateKey,
                publicKey: publicKey,
                kind: .taproot
            )
        }
    }

    static func select(
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
            // Manual coin control commits the complete selected set. Only
            // automatic selection may stop at the first sufficient prefix.
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
        let hasWitness = inputs.contains { input in
            if case .legacy = input.kind { return false }
            return true
        }
        var baseSize = 4 + compactSizeLength(inputs.count) + 4
        var witnessSize = hasWitness ? 2 : 0
        for input in inputs {
            switch input.kind {
            case .legacy:
                baseSize += input.publicKey.count == 65 ? 181 : 149
                if hasWitness { witnessSize += 1 }
            case .nestedSegwit:
                baseSize += 64
                witnessSize += 109
            case .nativeSegwit:
                baseSize += 41
                witnessSize += 109
            case .taproot:
                baseSize += 41
                // Wallet Core's SIGHASH_ALL appends a byte to the 64-byte
                // Schnorr signature. Reserve it even for default-sighash paths.
                witnessSize += 67
            }
        }
        baseSize += compactSizeLength(outputScriptSizes.count)
        for scriptSize in outputScriptSizes {
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

    private static func senderInputSecret(
        _ input: InputMaterial
    ) throws -> BitcoinSilentPaymentInputSecret {
        try BitcoinSilentPaymentInputSecret(
            outpoint: try serializedOutpoint(input.output),
            privateKey: input.privateKey,
            isTaproot: input.isTaproot
        )
    }

    private static func signatures(
        inputs: [InputMaterial],
        outputs: [TransactionOutput],
        sequence: UInt32
    ) throws -> [Data] {
        try inputs.indices.map { index in
            let input = inputs[index]
            switch input.kind {
            case .legacy:
                let digest = try legacySignatureHash(
                    inputs: inputs,
                    outputs: outputs,
                    signingIndex: index,
                    sequence: sequence
                )
                return try ecdsaSignature(
                    privateKey: input.privateKey,
                    digest: digest
                )
            case .nestedSegwit, .nativeSegwit:
                let digest = try segwitV0SignatureHash(
                    inputs: inputs,
                    outputs: outputs,
                    signingIndex: index,
                    sequence: sequence
                )
                return try ecdsaSignature(
                    privateKey: input.privateKey,
                    digest: digest
                )
            case .taproot:
                let digest = try taprootSignatureHash(
                    inputs: inputs,
                    outputs: outputs,
                    signingIndex: index,
                    sequence: sequence
                )
                let key = try P256K.Schnorr.PrivateKey(
                    dataRepresentation: input.privateKey
                )
                let hash = HashDigest(Array(digest))
                let signature = try key.signature(for: hash)
                guard key.xonly.isValidSignature(signature, for: hash)
                else {
                    throw invalidResponse("schnorr_signature")
                }
                return signature.dataRepresentation
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
        data.appendUInt32LE(2)
        data.appendCompactSize(inputs.count)
        for (index, input) in inputs.enumerated() {
            data.append(try serializedOutpoint(input.output))
            let script = index == signingIndex
                ? input.scriptPubKey : Data()
            data.appendScript(script)
            data.appendUInt32LE(sequence)
        }
        data.append(try serializedOutputs(outputs))
        data.appendUInt32LE(0)
        data.appendUInt32LE(1)
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
            sequences.appendUInt32LE(sequence)
        }
        let key = try P256K.Signing.PrivateKey(
            dataRepresentation: input.privateKey
        )
        let publicKey = key.publicKey.dataRepresentation
        let walletCorePublicKey = try requireWalletCorePublicKey(publicKey)
        let scriptCode = BitcoinScript.buildPayToPublicKeyHash(
            hash: walletCorePublicKey.bitcoinKeyHash
        ).data
        var data = Data()
        data.appendUInt32LE(2)
        data.append(doubleSHA256(prevouts))
        data.append(doubleSHA256(sequences))
        data.append(try serializedOutpoint(input.output))
        data.appendScript(scriptCode)
        data.appendUInt64LE(UInt64(input.value))
        data.appendUInt32LE(sequence)
        data.append(doubleSHA256(try serializedOutputsOnly(outputs)))
        data.appendUInt32LE(0)
        data.appendUInt32LE(1)
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
            amounts.appendUInt64LE(UInt64(input.value))
            scripts.appendScript(input.scriptPubKey)
            sequences.appendUInt32LE(sequence)
        }
        var message = Data([0x00, 0x00])
        message.appendUInt32LE(2)
        message.appendUInt32LE(0)
        message.append(singleSHA256(prevouts))
        message.append(singleSHA256(amounts))
        message.append(singleSHA256(scripts))
        message.append(singleSHA256(sequences))
        message.append(singleSHA256(try serializedOutputsOnly(outputs)))
        message.append(0x00)
        message.appendUInt32LE(UInt32(signingIndex))
        return Data(SHA256.taggedHash(
            tag: tapSighashTag,
            data: message
        ))
    }

    private static func serializeTransaction(
        inputs: [InputMaterial],
        outputs: [TransactionOutput],
        signatures: [Data],
        sequence: UInt32,
        includeWitness: Bool
    ) throws -> Data {
        guard inputs.count == signatures.count else {
            throw invalidResponse("signature_count")
        }
        let hasWitness = inputs.contains { input in
            if case .legacy = input.kind { return false }
            return true
        }
        var data = Data()
        data.appendUInt32LE(2)
        if includeWitness, hasWitness {
            data.append(contentsOf: [0x00, 0x01])
        }
        data.appendCompactSize(inputs.count)
        for (index, input) in inputs.enumerated() {
            data.append(try serializedOutpoint(input.output))
            let script: Data
            switch input.kind {
            case .legacy:
                script = push(signatures[index]) + push(input.publicKey)
            case .nestedSegwit:
                let key = try requireWalletCorePublicKey(input.publicKey)
                script = push(
                    BitcoinScript.buildPayToWitnessPubkeyHash(
                        hash: key.bitcoinKeyHash
                    ).data
                )
            case .nativeSegwit, .taproot:
                script = Data()
            }
            data.appendScript(script)
            data.appendUInt32LE(sequence)
        }
        data.append(try serializedOutputs(outputs))
        if includeWitness, hasWitness {
            for (index, input) in inputs.enumerated() {
                switch input.kind {
                case .legacy:
                    data.appendCompactSize(0)
                case .nestedSegwit, .nativeSegwit:
                    data.appendCompactSize(2)
                    data.appendScript(signatures[index])
                    data.appendScript(input.publicKey)
                case .taproot:
                    data.appendCompactSize(1)
                    data.appendScript(signatures[index])
                }
            }
        }
        data.appendUInt32LE(0)
        return data
    }

    private static func serializedOutputs(
        _ outputs: [TransactionOutput]
    ) throws -> Data {
        var data = Data()
        data.appendCompactSize(outputs.count)
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
            data.appendUInt64LE(UInt64(output.value))
            data.appendScript(output.scriptPubKey)
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
        data.appendUInt32LE(index)
        return data
    }

    private static func normalizedXOnlyPrivateKey(
        _ data: Data
    ) throws -> Data {
        var key = try P256K.Signing.PrivateKey(
            dataRepresentation: data
        )
        if key.publicKey.dataRepresentation.first == 0x03 {
            key = key.negation
        }
        return key.dataRepresentation
    }

    private static func xOnlyPublicKey(_ data: Data) throws -> Data {
        Data(try P256K.Signing.PrivateKey(
            dataRepresentation: data
        ).publicKey.xonly.bytes)
    }

    private static func requireWalletCorePublicKey(
        _ data: Data
    ) throws -> PublicKey {
        guard let key = PublicKey(data: data, type: .secp256k1) else {
            throw invalidResponse("public_key")
        }
        return key
    }

    private static func push(_ value: Data) -> Data {
        precondition(value.count <= 75)
        return Data([UInt8(value.count)]) + value
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

    static func invalidResponse(
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
