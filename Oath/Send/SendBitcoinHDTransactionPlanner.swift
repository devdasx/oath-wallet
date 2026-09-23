import Foundation
import WalletCore

/// Public transaction planning shared by Coin Control and the HD signer.
/// Planning uses output ownership and public keys; it never reads wallet secrets.
enum SendBitcoinHDTransactionPlanner {
    struct Input {
        let output: SendBitcoinUTXO
        let owner: BitcoinHDDerivedAddress
        let publicKey: PublicKey
    }

    struct Prepared {
        let signing: BitcoinV2SigningInput
        let plan: BitcoinV2TransactionPlan
        let inputs: [Input]
        let feeAtomic: String

        var selection: SendBitcoinSelectionPlan {
            SendBitcoinSelectionPlan(outputs: inputs.map(\.output), feeAtomic: feeAtomic)
        }
    }

    private struct PlanSelection {
        let plan: BitcoinV2TransactionPlan
        let inputs: [Input]
        let minimumRequiredFee: Int64
    }

    static func prepare(
        draft: SendDraft,
        outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64,
        byteFee: Int64,
        fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions,
        changeAddress: String,
        recipientAddress: String
    ) throws -> Prepared {
        let inputs = try outputs.map { output in
            guard output.isValid, let owner = output.owner,
                  let publicKey = PublicKey(data: owner.publicKey, type: .secp256k1) else {
                throw invalidProviderResponse(code: "invalid_hd_planning_input")
            }
            return Input(output: output, owner: owner, publicKey: publicKey)
        }
        let silentPaymentAddress = try? BitcoinSilentPaymentAddress(recipientAddress)
        let initialRecipientScript = silentPaymentAddress == nil
            ? nil
            : Data([0x51, 0x20]) + Data(repeating: 0, count: 32)
        let opReturnPayload = try SendBitcoinOPReturn.payload(
            for: options.opReturnMessage
        )
        // Wallet Core's maximum output cannot coexist with any other output.
        // Plan Max alone, then freeze explicit outputs with the full message fee.
        let maximumMessageFee: Int64
        if draft.usesMaximumBalance, let opReturnPayload {
            maximumMessageFee = try checkedMultiply(
                SendBitcoinV2OutputBuilder.serializedOPReturnSize(
                    payload: opReturnPayload
                ),
                byteFee
            )
        } else {
            maximumMessageFee = 0
        }
        var signing = try v2SigningInput(
            draft: draft,
            inputs: inputs,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            options: options,
            changeAddress: changeAddress,
            recipientAddress: recipientAddress,
            recipientScript: initialRecipientScript,
            opReturnPayload: opReturnPayload
        )
        let wrapper = BitcoinSigningInput.with {
            $0.coinType = CoinType.bitcoin.rawValue
            $0.signingV2 = signing
        }
        let legacyPlan: BitcoinTransactionPlan = AnySigner.plan(
            input: wrapper,
            coin: .bitcoin
        )
        guard legacyPlan.hasPlanningResultV2 else {
            throw invalidProviderResponse(code: "missing_v2_plan")
        }
        var plan = legacyPlan.planningResultV2
        guard plan.error == .ok else {
            throw v2PlanError(plan)
        }

        var selected = try selectedInputs(
            plan: plan,
            availableInputs: inputs
        )
        var minimumRequiredFee = try minimumRequiredFee(
            plan: plan,
            selectedInputs: selected,
            byteFee: byteFee,
            additionalOutputFee: maximumMessageFee
        )
        let customBudget = try fee.totalBudgetAtomic.map(
            SendAtomicAmount.int64
        )
        if let customBudget, customBudget < minimumRequiredFee {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("custom_fee_budget_below_required")
        }
        if !selectionSatisfies(
            inputs: selected,
            requestedAtomic: requestedAtomic,
            minimumRequiredFee: minimumRequiredFee,
            customBudget: customBudget,
            usesMaximumBalance: draft.usesMaximumBalance
        ) {
            let expanded = try expandedPlanSelection(
                original: signing,
                initialPlan: plan,
                initialInputs: selected,
                availableInputs: inputs,
                requestedAtomic: requestedAtomic,
                byteFee: byteFee,
                additionalOutputFee: maximumMessageFee,
                customBudget: customBudget,
                usesMaximumBalance: draft.usesMaximumBalance
            )
            plan = expanded.plan
            selected = expanded.inputs
            minimumRequiredFee = expanded.minimumRequiredFee
        }

        // Freeze explicit outputs for every path, not just custom fees. This
        // makes Review and signing share one script-aware dust decision.
        signing = try exactBudgetSigningInput(
            original: signing, plan: plan, availableInputs: inputs,
            requestedAtomic: requestedAtomic,
            totalBudgetAtomic: String(customBudget ?? minimumRequiredFee),
            minimumRequiredFee: minimumRequiredFee,
            usesMaximumBalance: draft.usesMaximumBalance,
            changeAddress: changeAddress, recipientAddress: recipientAddress,
            recipientScript: initialRecipientScript, opReturnPayload: opReturnPayload
        )
        let outputTotal = try signing.builder.outputs.reduce(Int64(0)) { try checkedAdd($0, $1.value) }
        let effectiveFee = try checkedSubtract(atomicSum(selected), outputTotal)
        return Prepared(signing: signing, plan: plan, inputs: selected, feeAtomic: String(effectiveFee))
    }

    private static func expandedPlanSelection(
        original: BitcoinV2SigningInput,
        initialPlan: BitcoinV2TransactionPlan,
        initialInputs: [Input],
        availableInputs: [Input],
        requestedAtomic: Int64,
        byteFee: Int64,
        additionalOutputFee: Int64,
        customBudget: Int64?,
        usesMaximumBalance: Bool
    ) throws -> PlanSelection {
        var candidateInputs = initialInputs
        let selectedIDs = Set(candidateInputs.map(\.output.id))
        let remaining = availableInputs
            .filter { !selectedIDs.contains($0.output.id) }
            .sorted {
                let left = Int64($0.output.valueAtomic) ?? 0
                let right = Int64($1.output.valueAtomic) ?? 0
                if left != right { return left > right }
                return $0.output.id < $1.output.id
            }
        var latestMinimum = try minimumRequiredFee(
            plan: initialPlan,
            selectedInputs: initialInputs,
            byteFee: byteFee,
            additionalOutputFee: additionalOutputFee
        )

        for input in remaining {
            candidateInputs.append(input)
            let candidateSigning = try fixedSelectionSigningInput(
                original: original,
                inputs: candidateInputs
            )
            let candidatePlan = try planningResult(candidateSigning)
            guard candidatePlan.error == .ok else { continue }
            let plannedInputs = try selectedInputs(
                plan: candidatePlan,
                availableInputs: candidateInputs
            )
            let minimum = try minimumRequiredFee(
                plan: candidatePlan,
                selectedInputs: plannedInputs,
                byteFee: byteFee,
                additionalOutputFee: additionalOutputFee
            )
            candidateInputs = plannedInputs
            latestMinimum = minimum
            if selectionSatisfies(
                inputs: plannedInputs,
                requestedAtomic: requestedAtomic,
                minimumRequiredFee: minimum,
                customBudget: customBudget,
                usesMaximumBalance: usesMaximumBalance
            ) {
                return PlanSelection(
                    plan: candidatePlan,
                    inputs: plannedInputs,
                    minimumRequiredFee: minimum
                )
            }
        }

        if let customBudget, customBudget < latestMinimum {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("custom_fee_budget_below_required")
        }
        throw SendTransactionSubmissionError.insufficientAssetBalance
    }

    private static func fixedSelectionSigningInput(
        original: BitcoinV2SigningInput,
        inputs: [Input]
    ) throws -> BitcoinV2SigningInput {
        var value = original
        let sequence = original.builder.inputs.first?.sequence.sequence
            ?? UInt32.max
        value.builder.inputs = try inputs.map {
            try v2Input($0, sequence: sequence)
        }
        value.builder.inputSelector = .useAll
        value.publicKeys = uniquePublicKeys(inputs)
        return value
    }

    private static func planningResult(
        _ input: BitcoinV2SigningInput
    ) throws -> BitcoinV2TransactionPlan {
        let wrapper = BitcoinSigningInput.with {
            $0.coinType = CoinType.bitcoin.rawValue
            $0.signingV2 = input
        }
        let legacyPlan: BitcoinTransactionPlan = AnySigner.plan(
            input: wrapper,
            coin: .bitcoin
        )
        guard legacyPlan.hasPlanningResultV2 else {
            throw invalidProviderResponse(code: "missing_v2_plan")
        }
        return legacyPlan.planningResultV2
    }

    private static func minimumRequiredFee(
        plan: BitcoinV2TransactionPlan,
        selectedInputs: [Input],
        byteFee: Int64,
        additionalOutputFee: Int64
    ) throws -> Int64 {
        let nestedInputCount = selectedInputs.reduce(into: Int64(0)) {
            count, input in
            if input.owner.addressType == .bip49 { count += 1 }
        }
        try SendBitcoinTransactionPolicy.validateVirtualSize(
            Int64(plan.vsizeEstimate) + nestedInputCount * 23 + additionalOutputFee / byteFee
        )
        let nestedFee = try checkedMultiply(
            try checkedMultiply(nestedInputCount, 23),
            byteFee
        )
        return try checkedAdd(
            checkedAdd(plan.feeEstimate, nestedFee), additionalOutputFee
        )
    }

    private static func selectionSatisfies(
        inputs: [Input],
        requestedAtomic: Int64,
        minimumRequiredFee: Int64,
        customBudget: Int64?,
        usesMaximumBalance: Bool
    ) -> Bool {
        let targetFee = customBudget ?? minimumRequiredFee
        guard targetFee >= minimumRequiredFee else { return false }
        let available = atomicSum(inputs)
        if usesMaximumBalance {
            let amount = available.subtractingReportingOverflow(targetFee)
            return !amount.overflow && amount.partialValue > 0
        }
        let spent = requestedAtomic.addingReportingOverflow(targetFee)
        guard !spent.overflow, available >= spent.partialValue else {
            return false
        }
        return true // Any sub-threshold remainder is folded into the fee below.
    }

    private static func v2SigningInput(
        draft: SendDraft,
        inputs: [Input],
        requestedAtomic: Int64,
        byteFee: Int64,
        options: SendBitcoinFamilyOptions,
        changeAddress: String,
        recipientAddress: String,
        recipientScript: Data?,
        opReturnPayload: Data?
    ) throws -> BitcoinV2SigningInput {
        let v2Inputs = try inputs.map {
            try v2Input($0, sequence: options.inputSequence(for: .bitcoin))
        }
        return BitcoinV2SigningInput.with {
            $0.builder = BitcoinV2TransactionBuilder.with {
                $0.version = .v2
                $0.inputs = v2Inputs
                $0.inputSelector = options.coinSelection.selectedUTXOs
                    .isEmpty ? .selectDescending : .useAll
                $0.feePerVb = byteFee
                $0.fixedDustThreshold = 0 // Apply script-specific recipient/change checks after selection.
                if draft.usesMaximumBalance {
                    $0.maxAmountOutput = SendBitcoinV2OutputBuilder.recipientOutput(
                        value: nil,
                        address: recipientAddress,
                        script: recipientScript
                    )
                } else {
                    $0.outputs = [
                        SendBitcoinV2OutputBuilder.recipientOutput(
                            value: requestedAtomic,
                            address: recipientAddress,
                            script: recipientScript
                        )
                    ]
                    if let opReturnPayload {
                        $0.outputs.append(
                            SendBitcoinV2OutputBuilder.opReturnOutput(payload: opReturnPayload)
                        )
                    }
                    $0.changeOutput = BitcoinV2Output.with {
                        $0.toAddress = changeAddress
                    }
                }
            }
            $0.publicKeys = uniquePublicKeys(inputs)
            $0.chainInfo = bitcoinChainInfo()
        }
    }

    private static func exactBudgetSigningInput(
        original: BitcoinV2SigningInput,
        plan: BitcoinV2TransactionPlan,
        availableInputs: [Input],
        requestedAtomic: Int64,
        totalBudgetAtomic: String,
        minimumRequiredFee: Int64,
        usesMaximumBalance: Bool,
        changeAddress: String,
        recipientAddress: String,
        recipientScript: Data?,
        opReturnPayload: Data?
    ) throws -> BitcoinV2SigningInput {
        let targetFee = try SendAtomicAmount.int64(totalBudgetAtomic)
        guard targetFee >= minimumRequiredFee else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("custom_fee_budget_below_required")
        }
        let selected = try selectedInputs(
            plan: plan,
            availableInputs: availableInputs
        )
        let available = atomicSum(selected)
        let recipientMinimum = SendBitcoinDustPolicy.recipientMinimum(chain: .bitcoin,
            script: recipientScript ?? BitcoinScript.lockScriptForAddress(address: recipientAddress, coin: .bitcoin).data)
        let changeMinimum = SendBitcoinDustPolicy.changeMinimum(chain: .bitcoin,
            script: BitcoinScript.lockScriptForAddress(address: changeAddress, coin: .bitcoin).data)
        let sendAmount: Int64
        let change: Int64
        if usesMaximumBalance {
            let result = available.subtractingReportingOverflow(targetFee)
            guard !result.overflow, result.partialValue >= recipientMinimum else {
                throw SendTransactionSubmissionError
                    .insufficientAssetBalance
            }
            sendAmount = result.partialValue
            change = 0
        } else {
            let spent = requestedAtomic.addingReportingOverflow(targetFee)
            guard !spent.overflow, available >= spent.partialValue else {
                throw SendTransactionSubmissionError
                    .insufficientNetworkFeeBalance
            }
            guard requestedAtomic >= recipientMinimum else {
                throw SendTransactionSubmissionError.invalidAmount
            }
            sendAmount = requestedAtomic
            let remainder = available - spent.partialValue
            change = remainder < changeMinimum ? 0 : remainder
        }
        var fixed = original
        let sequence = original.builder.inputs.first?.sequence.sequence
            ?? UInt32.max
        fixed.builder.inputs = try selected.map {
            try v2Input($0, sequence: sequence)
        }
        fixed.builder.inputSelector = .useAll
        fixed.builder.feePerVb = 0
        fixed.builder.clearMaxAmountOutput()
        fixed.builder.clearChangeOutput()
        fixed.builder.outputs = [
            SendBitcoinV2OutputBuilder.recipientOutput(
                value: sendAmount,
                address: recipientAddress,
                script: recipientScript
            )
        ]
        if let opReturnPayload {
            fixed.builder.outputs.append(
                SendBitcoinV2OutputBuilder.opReturnOutput(payload: opReturnPayload)
            )
        }
        if change > 0 {
            guard !changeAddress.isEmpty else {
                throw invalidProviderResponse(
                    code: "missing_v2_change_address"
                )
            }
            fixed.builder.outputs.append(
                BitcoinV2Output.with {
                    $0.value = change
                    $0.toAddress = changeAddress
                }
            )
        }
        fixed.publicKeys = uniquePublicKeys(selected)
        return fixed
    }

    private static func v2Input(
        _ input: Input,
        sequence: UInt32
    ) throws -> BitcoinV2Input {
        guard let hash = Data(
            bitcoinHex: input.output.outpoint.transactionHash
        ), hash.count == 32,
        let outputIndex = input.output.outpoint.wireOutputIndex else {
            throw invalidProviderResponse(code: "invalid_v2_outpoint")
        }
        return try BitcoinV2Input.with {
            $0.outPoint = UtxoOutPoint.with {
                $0.hash = Data(hash.reversed())
                $0.vout = outputIndex
            }
            $0.value = try SendAtomicAmount.int64(
                input.output.valueAtomic
            )
            $0.sighashType = BitcoinSigHashType.all.rawValue
            $0.sequence = BitcoinV2Input.Sequence.with {
                $0.sequence = sequence
            }
            $0.scriptBuilder = BitcoinV2Input.InputBuilder.with {
                switch input.owner.addressType {
                case .bip44, .brdLegacy:
                    $0.p2Pkh = BitcoinV2PublicKeyOrHash.with {
                        $0.pubkey = input.publicKey.data
                    }
                case .bip84, .brdSegwit:
                    $0.p2Wpkh = BitcoinV2PublicKeyOrHash.with {
                        $0.pubkey = input.publicKey.data
                    }
                case .bip49:
                    // Nested P2WPKH uses the same BIP143 digest and witness
                    // as native P2WPKH. The required redeem-program scriptSig
                    // is inserted after Wallet Core signs the transaction.
                    $0.p2Wpkh = BitcoinV2PublicKeyOrHash.with {
                        $0.pubkey = input.publicKey.data
                    }
                case .bip86:
                    $0.p2TrKeyPath = input.publicKey.data
                }
            }
        }
    }

    private static func selectedInputs(
        plan: BitcoinV2TransactionPlan,
        availableInputs: [Input]
    ) throws -> [Input] {
        let availableByID = Dictionary(
            uniqueKeysWithValues: availableInputs.map {
                ($0.output.id, $0)
            }
        )
        return try plan.inputs.map { input in
            let id = "\(Data(input.outPoint.hash.reversed()).hexString):\(input.outPoint.vout)"
            guard let value = availableByID[id] else {
                throw invalidProviderResponse(
                    code: "v2_plan_selected_unknown_input"
                )
            }
            return value
        }
    }

    private static func atomicSum(_ inputs: [Input]) -> Int64 {
        inputs.reduce(into: Int64(0)) { value, input in
            guard let amount = Int64(input.output.valueAtomic) else {
                value = Int64.max
                return
            }
            let result = value.addingReportingOverflow(amount)
            value = result.overflow ? Int64.max : result.partialValue
        }
    }

    private static func uniquePublicKeys(
        _ inputs: [Input]
    ) -> [Data] {
        Array(Set(inputs.map(\.publicKey.data))).sorted {
            $0.lexicographicallyPrecedes($1)
        }
    }

    private static func bitcoinChainInfo() -> BitcoinV2ChainInfo {
        BitcoinV2ChainInfo.with {
            $0.p2PkhPrefix = 0
            $0.p2ShPrefix = 5
            $0.hrp = "bc"
        }
    }

    private static func v2PlanError(
        _ plan: BitcoinV2TransactionPlan
    ) -> SendTransactionSubmissionError {
        if plan.error == .errorNotEnoughUtxos
            || plan.error == .errorLowBalance
            || plan.error == .errorMissingInputUtxos {
            return .insufficientAssetBalance
        }
        return .signing(
            code: String(plan.error.rawValue),
            message: SendTransactionSubmissionError
                .sanitizedMessage(plan.errorMessage)
        )
    }

    private static func checkedAdd(
        _ left: Int64,
        _ right: Int64
    ) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result.partialValue
    }

    private static func checkedSubtract(
        _ left: Int64,
        _ right: Int64
    ) throws -> Int64 {
        let result = left.subtractingReportingOverflow(right)
        guard !result.overflow else {
            throw SendTransactionSubmissionError.amountOutOfRange
        }
        return result.partialValue
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
}
