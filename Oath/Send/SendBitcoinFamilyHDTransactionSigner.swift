import Foundation
import WalletCore

enum SendBitcoinFamilyHDTransactionSigner {
    static func input(draft: SendDraft, chain: BitcoinFamilyChain, outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64, byteFee: Int64, options: SendBitcoinFamilyOptions,
        changeAddress: String, recipientAddress: String) throws -> BitcoinSigningInput {
        guard chain.supportsFamilyHD, !outputs.isEmpty, chain.coin.validate(address: changeAddress),
              chain.coin.validate(address: recipientAddress) else { throw SendTransactionSubmissionError.invalidRecipient }
        let options = try options.normalized(for: chain)
        var scripts: [String: Data] = [:]
        let utxos = try outputs.map { output -> BitcoinUnspentTransaction in
            guard output.isValid, output.networkID == chain.networkID, let owner = output.owner,
                  output.silentPaymentOwner == nil, output.muunOwner == nil,
                  let publicKey = PublicKey(data: owner.publicKey, type: .secp256k1),
                  try BitcoinFamilyHDDerivation.address(chain: chain, type: owner.addressType,
                    branch: owner.branch, index: owner.index, publicKey: publicKey) == owner,
                  let hash = Data(bitcoinHex: output.outpoint.transactionHash), hash.count == 32 else {
                throw SendTransactionSubmissionError.derivedAddressMismatch
            }
            if owner.addressType == .bip49 {
                let lock = BitcoinScript.lockScriptForAddress(address: owner.address, coin: chain.coin)
                guard let scriptHash = lock.matchPayToScriptHash() else {
                    throw SendTransactionSubmissionError.derivedAddressMismatch
                }
                scripts[scriptHash.hexString] = BitcoinScript.buildPayToWitnessPubkeyHash(hash: publicKey.bitcoinKeyHash).data
            }
            return try BitcoinUnspentTransaction.with {
                $0.outPoint.hash = Data(hash.reversed())
                $0.outPoint.index = try SendBitcoinTransactionService.checkedWireOutputIndex(output.outpoint.outputIndex,
                    networkID: chain.networkID)
                $0.outPoint.sequence = options.inputSequence(for: chain)
                $0.script = owner.scriptPubKey
                $0.amount = try SendAtomicAmount.int64(output.valueAtomic)
            }
        }
        let changeScript = BitcoinScript.lockScriptForAddress(address: changeAddress, coin: chain.coin).data
        let recipientScript = BitcoinScript.lockScriptForAddress(address: recipientAddress, coin: chain.coin).data
        return BitcoinSigningInput.with {
            $0.hashType = BitcoinScript.hashTypeForCoin(coinType: chain.coin)
            $0.coinType = chain.coin.rawValue
            $0.amount = requestedAtomic
            $0.byteFee = byteFee
            $0.toAddress = recipientAddress
            $0.changeAddress = changeAddress
            $0.utxo = utxos
            $0.scripts = scripts
            $0.useMaxAmount = draft.usesMaximumBalance
            $0.useMaxUtxo = !options.coinSelection.selectedUTXOs.isEmpty
            $0.disableDustFilter = $0.useMaxUtxo
            $0.fixedDustThreshold = SendBitcoinDustPolicy.changeMinimum(chain: chain, script: changeScript)
            if chain != .dogecoin {
                $0.fixedDustThreshold = max($0.fixedDustThreshold,
                    SendBitcoinDustPolicy.recipientMinimum(chain: chain, script: recipientScript))
            }
        }
    }

    static func selectionPlan(draft: SendDraft, chain: BitcoinFamilyChain, outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64, byteFee: Int64, fee: SendResolvedNetworkFee, options: SendBitcoinFamilyOptions,
        changeAddress: String, recipientAddress: String) throws -> SendBitcoinSelectionPlan {
        let input = try input(draft: draft, chain: chain, outputs: outputs, requestedAtomic: requestedAtomic,
            byteFee: byteFee, options: options, changeAddress: changeAddress, recipientAddress: recipientAddress)
        let plan = try SendBitcoinTransactionService.dustSafePlan(input: input, chain: chain, fee: fee)
        let selected = try selectedOutputs(plan, outputs: outputs)
        return SendBitcoinSelectionPlan(outputs: selected, feeAtomic: String(plan.fee), recipientAmountAtomic: String(plan.amount))
    }

    static func sign(draft: SendDraft, material: SendResolvedSigningMaterial, chain: BitcoinFamilyChain,
        outputs: [SendBitcoinUTXO], requestedAtomic: Int64, byteFee: Int64, fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions, changeAddress: String, recipientAddress: String) throws -> SendBitcoinSignedTransaction {
        guard let credential = material.bitcoinHDRecoveryCredential else { throw SendTransactionSubmissionError.secretUnavailable }
        var input = try input(draft: draft, chain: chain, outputs: outputs, requestedAtomic: requestedAtomic,
            byteFee: byteFee, options: options, changeAddress: changeAddress, recipientAddress: recipientAddress)
        let plan = try SendBitcoinTransactionService.dustSafePlan(input: input, chain: chain, fee: fee)
        let selected = try selectedOutputs(plan, outputs: outputs)
        var keys = Set<Data>()
        input.privateKey = try selected.compactMap { output in
            guard let owner = output.owner else { throw SendTransactionSubmissionError.derivedAddressMismatch }
            let key = try BitcoinFamilyHDDerivation.privateKey(credential: credential, chain: chain, owner: owner).data
            return keys.insert(key).inserted ? key : nil
        }
        input.plan = plan
        let output: BitcoinSigningOutput = AnySigner.sign(input: input, coin: chain.coin)
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SendTransactionSubmissionError.signing(code: String(output.error.rawValue),
                message: SendTransactionSubmissionError.sanitizedMessage(output.errorMessage))
        }
        let finalized = try SendBitcoinNestedSegwitTransaction.finalize(encoded: output.encoded, nestedPublicKeysByOutpointID: [:])
        let minimum = finalized.virtualSize.multipliedReportingOverflow(by: byteFee)
        guard !minimum.overflow, plan.fee >= 0, plan.fee >= minimum.partialValue,
              output.transactionID.lowercased() == finalized.transactionID,
              let parsed = BitcoinRawTransaction(hex: finalized.encoded.hexString),
              parsed.inputs.count == selected.count,
              Set(parsed.inputs.map { "\($0.previousHash):\($0.previousIndex)" }) == Set(selected.map(\.id)),
              parsed.outputs.reduce(BitcoinFamilyAtomicInteger.zero, { $0.adding($1.value) })
                .adding(BitcoinFamilyAtomicInteger(UInt64(plan.fee))) == selected.reduce(.zero, {
                    $0.adding((try? BitcoinFamilyAtomicInteger(validating: $1.valueAtomic)) ?? .zero)
                }) else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable("family_hd_signed_plan_mismatch")
        }
        return SendBitcoinSignedTransaction(encoded: finalized.encoded, transactionID: finalized.transactionID,
            amountAtomic: String(plan.amount), feeAtomic: String(plan.fee),
            changeAddress: plan.change > 0 ? changeAddress : nil, spentOutpointIDs: Set(selected.map(\.id)))
    }

    private static func selectedOutputs(_ plan: BitcoinTransactionPlan, outputs: [SendBitcoinUTXO]) throws -> [SendBitcoinUTXO] {
        let ids = Set(plan.utxos.map { "\(Data($0.outPoint.hash.reversed()).hexString):\($0.outPoint.index)" })
        let selected = outputs.filter { ids.contains($0.id) }
        guard !selected.isEmpty, selected.count == ids.count else { throw SendTransactionSubmissionError.derivedAddressMismatch }
        return selected
    }
}
