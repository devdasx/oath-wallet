import Foundation
import WalletCore

struct SendBitcoinPlanningInputs: Sendable {
    let walletID: String
    let account: DBWalletAccountRecord
    let outputs: [SendBitcoinUTXO]
}

extension SendNetworkFeeEstimator {
    /// Uses the reviewed account and excludes pending spends before planning.
    func bitcoinPlanningInputs(draft: SendDraft) async throws -> SendBitcoinPlanningInputs {
        guard let chain = BitcoinFamilyChain(rawValue: draft.asset.networkID), draft.asset.isNative else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        let context = try await signingContext(for: draft)
        let requested = try draft.amount.map {
            try SendAtomicAmount.fromUserUnits($0, decimals: draft.asset.decimals)
        } ?? "0"
        let outputs = try await bitcoinOutputLoader(
            chain, context.account.address, context.walletID,
            SendBitcoinTransactionService.minimumExpectedUTXOValue(draft: draft, requestedAtomic: requested),
            Set(draft.bitcoinFamilyOptions.coinSelection.selectedUTXOs.map(\.id))
        )
        return SendBitcoinPlanningInputs(walletID: context.walletID, account: context.account, outputs: outputs)
    }

    func bitcoinFamilyPlan(
        draft: SendDraft,
        fee: SendResolvedNetworkFee,
        loadedInputs: SendBitcoinPlanningInputs? = nil
    ) async throws -> SendBitcoinSelectionPlan {
        guard let chain = BitcoinFamilyChain(
            rawValue: draft.asset.networkID
        ), draft.asset.isNative, let requestedAmount = draft.amount else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        let options = try draft.bitcoinFamilyOptions.normalized(
            for: chain
        )
        let requestedAtomic = try SendAtomicAmount.int64(
            SendAtomicAmount.fromUserUnits(
                requestedAmount,
                decimals: draft.asset.decimals
            )
        )
        let byteFee = try SendAtomicAmount.int64(fee.primaryValue)
        guard byteFee > 0 else {
            throw SendTransactionSubmissionError
                .feeQuoteUnavailable("zero_utxo_fee")
        }

        let context: SendBitcoinPlanningInputs
        if let loadedInputs {
            context = loadedInputs
        } else {
            context = try await bitcoinPlanningInputs(draft: draft)
        }
        let account = context.account
        let outputs = try SendBitcoinTransactionService.outputs(
            from: context.outputs,
            selection: options.coinSelection
        )
        if chain.supportsFamilyHD, outputs.contains(where: { $0.owner != nil }) {
            let descriptors = try await database.bitcoinFamilyHDDescriptors(walletID: context.walletID, chain: chain)
            guard let descriptor = descriptors.first(where: { $0.type == chain.familyHDDefaultType }) else {
                throw SendTransactionSubmissionError.accountUnavailable
            }
            let change = try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: .change, index: 0)
            return try SendBitcoinFamilyHDTransactionSigner.selectionPlan(draft: draft, chain: chain, outputs: outputs,
                requestedAtomic: requestedAtomic, byteFee: byteFee, fee: fee, options: options,
                changeAddress: change.address, recipientAddress: draft.recipient)
        }
        if chain == .bitcoin,
           account.derivationPath
            == MuunRecoveryKeyMaterial.accountMarker {
            return try SendMuunRecoveryTransactionSigner
                .selectionPlan(
                    outputs: outputs,
                    requestedAtomic: requestedAtomic,
                    byteFee: byteFee,
                    totalBudgetAtomic: fee.totalBudgetAtomic,
                    options: options,
                    recipientAddress: draft.recipient,
                    usesMaximumBalance: draft.usesMaximumBalance
                )
        }
        if chain == .bitcoin,
           (account.derivationPath == BitcoinImportedWalletMaterial.accountMarker
            || PrivateKeyImportFormat(accountMarker: account.derivationPath).map { [.wifCompressed, .wifUncompressed].contains($0) } == true),
           let wallet = try await database.bitcoinSingleKeyWallet(
               walletID: context.walletID
           ) {
            let preferredType = try await database
                .bitcoinReceiveAddressType(walletID: context.walletID)
            let changeAddress = wallet.address(for: preferredType)
                ?? wallet.address(for: wallet.defaultAddressType)
            guard let changeAddress else {
                throw SendTransactionSubmissionError.accountUnavailable
            }
            if PrivateKeyImportFormat(accountMarker: account.derivationPath) == .wifCompressed {
                return try SendBitcoinHDTransactionPlanner.prepare(
                    draft: draft, outputs: outputs, requestedAtomic: requestedAtomic,
                    byteFee: byteFee, fee: fee, options: options,
                    changeAddress: changeAddress.address, recipientAddress: draft.recipient
                ).selection
            }
            return try BitcoinSilentPaymentTransactionSigner
                .selectionPlan(
                    outputs: outputs,
                    accountMarker: account.derivationPath,
                    requestedAtomic: requestedAtomic,
                    byteFee: byteFee,
                    totalBudgetAtomic: fee.totalBudgetAtomic,
                    options: options,
                    sourceAddress: changeAddress.address,
                    recipientAddress: draft.recipient,
                    usesMaximumBalance: draft.usesMaximumBalance
                )
        }
        // Use the script-aware planner for every Bitcoin account. The legacy
        // Wallet Core planner is limited to the historical OP_RETURN size.
        if chain == .bitcoin {
            // Signing reserves change using the wallet's selected address type,
            // which need not match its account or any selected input address.
            let descriptors = try await database.bitcoinHDAccountDescriptors(walletID: context.walletID)
            if !descriptors.isEmpty, outputs.allSatisfy({ $0.owner != nil }) {
                let type = try await database.bitcoinReceiveAddressType(walletID: context.walletID)
                guard let descriptor = descriptors.first(where: { $0.addressType == type }) else {
                    throw SendTransactionSubmissionError.accountUnavailable
                }
                // Only the change script type affects selection. Public derivation
                // provides that type without allocating or reserving an address.
                let change = try BitcoinHDDerivationService().deriveAddress(
                    descriptor: descriptor, branch: .change, index: 0
                )
                return try SendBitcoinHDTransactionPlanner.prepare(
                    draft: draft, outputs: outputs, requestedAtomic: requestedAtomic,
                    byteFee: byteFee, fee: fee, options: options,
                    changeAddress: change.address, recipientAddress: draft.recipient
                ).selection
            }
            let changeOutputScriptSize: Int?
            if !descriptors.isEmpty {
                let type = try await database.bitcoinReceiveAddressType(walletID: context.walletID)
                changeOutputScriptSize = SendBitcoinTransactionPolicy.changeOutputScriptSize(for: type)
            } else {
                changeOutputScriptSize = nil
            }
            return try BitcoinSilentPaymentTransactionSigner
                .selectionPlan(
                    outputs: outputs,
                    accountMarker: account.derivationPath,
                    requestedAtomic: requestedAtomic,
                    byteFee: byteFee,
                    totalBudgetAtomic: fee.totalBudgetAtomic,
                    options: options,
                    sourceAddress: account.address,
                    recipientAddress: draft.recipient,
                    usesMaximumBalance: draft.usesMaximumBalance,
                    changeOutputScriptSize: changeOutputScriptSize
                )
        }
        let input = try SendBitcoinTransactionService.signingInput(
            draft: draft,
            accountMarker: account.derivationPath,
            nestedSegwitPublicKey: Self.bitcoinPublicKey(
                account.publicKey
            ),
            chain: chain,
            outputs: outputs,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            options: options,
            senderAddress: account.address,
            recipientAddress: draft.recipient
        )
        let adjustedPlan = try SendBitcoinTransactionService.dustSafePlan(input: input, chain: chain, fee: fee)
        let selectedIDs = Set(adjustedPlan.utxos.map {
            "\(Data($0.outPoint.hash.reversed()).hexString):\($0.outPoint.index)"
        })
        let selected = outputs.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty, selected.count == selectedIDs.count else {
            throw SendTransactionSubmissionError.signing(
                code: "plan_selected_unknown_output",
                message: WalletLocalization.string("send.submit.error.provider_invalid_response")
            )
        }
        return SendBitcoinSelectionPlan(outputs: selected, feeAtomic: String(adjustedPlan.fee),
                                        recipientAmountAtomic: String(adjustedPlan.amount))
    }

    /// Deducts a native fee shortfall from the recipient amount, using the real
    /// selected scripts, coin-control inputs and custom fee budget. Replan the
    /// selected outpoints so new deposits cannot expand an authorized sweep.
    func nativeBitcoinEstimate(
        draft: SendDraft, fee: SendResolvedNetworkFee,
        loadedInputs: SendBitcoinPlanningInputs? = nil
    ) async throws -> SendNetworkFeeEstimate {
        let inputs: SendBitcoinPlanningInputs
        if let loadedInputs { inputs = loadedInputs }
        else { inputs = try await bitcoinPlanningInputs(draft: draft) }
        guard let requested = draft.amount else { throw SendTransactionSubmissionError.invalidAmount }
        let requestedAtomic = try SendAtomicAmount.fromUserUnits(requested, decimals: draft.asset.decimals)
        if !draft.usesMaximumBalance {
            do {
                let plan = try await bitcoinFamilyPlan(draft: draft, fee: fee, loadedInputs: inputs)
                let amount = plan.recipientAmountAtomic ?? requestedAtomic
                return SendNetworkFeeEstimate(atomicAmount: plan.feeAtomic, nativeDecimals: draft.asset.decimals,
                    nativeTransferAmountAtomic: amount,
                    nativeMaximumInputs: amount != requestedAtomic ? plan.outputs : nil)
            } catch let error as SendTransactionSubmissionError {
                guard error == .insufficientAssetBalance || error == .insufficientNetworkFeeBalance else { throw error }
            }
        }
        let maximumPlan = try await bitcoinFamilyPlan(draft: draft.replacingMaximumBalance(true),
                                                     fee: fee, loadedInputs: inputs)
        let total = maximumPlan.outputs.reduce("0") { SendAtomicAmount.add($0, $1.valueAtomic) }
        let amount = try SendNativeTransferAmountResolver.resolve(requestedAtomic: requestedAtomic,
            balanceAtomic: total, unavailableAtomic: maximumPlan.feeAtomic,
            usesMaximumBalance: draft.usesMaximumBalance)
        let committedFee = try SendAtomicAmount.subtract(total, amount)
        return SendNetworkFeeEstimate(atomicAmount: committedFee,
            nativeDecimals: draft.asset.decimals, nativeTransferAmountAtomic: amount,
            nativeMaximumInputs: maximumPlan.outputs)
    }

    private static func bitcoinPublicKey(_ value: String?) -> PublicKey? {
        guard let value,
              let data = Data(hexString: value),
              data.count == 33 else {
            return nil
        }
        return PublicKey(data: data, type: .secp256k1)
    }

}
