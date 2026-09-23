import Foundation
import WalletCore

extension BitcoinSilentPaymentTransactionSigner {
    static func estimatedNetworkFeeAtomic(
        outputs: [SendBitcoinUTXO],
        accountMarker: String?,
        requestedAtomic: Int64,
        byteFee: Int64,
        totalBudgetAtomic: String?,
        options: SendBitcoinFamilyOptions,
        sourceAddress: String,
        recipientAddress: String,
        usesMaximumBalance: Bool,
        changeOutputScriptSize: Int? = nil
    ) throws -> String {
        try selectionPlan(
            outputs: outputs,
            accountMarker: accountMarker,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            totalBudgetAtomic: totalBudgetAtomic,
            options: options,
            sourceAddress: sourceAddress,
            recipientAddress: recipientAddress,
            usesMaximumBalance: usesMaximumBalance,
            changeOutputScriptSize: changeOutputScriptSize
        ).feeAtomic
    }

    static func selectionPlan(
        outputs: [SendBitcoinUTXO],
        accountMarker: String?,
        requestedAtomic: Int64,
        byteFee: Int64,
        totalBudgetAtomic: String?,
        options: SendBitcoinFamilyOptions,
        sourceAddress: String,
        recipientAddress: String,
        usesMaximumBalance: Bool,
        changeOutputScriptSize: Int? = nil
    ) throws -> SendBitcoinSelectionPlan {
        let recipientScriptSize = BitcoinSilentPaymentAddress
            .isValidMainnet(recipientAddress) ? 34 : BitcoinScript
            .lockScriptForAddress(
                address: recipientAddress,
                coin: .bitcoin
            ).data.count
        guard recipientScriptSize > 0 else {
            throw SendTransactionSubmissionError.invalidRecipient
        }
        let sourceScript = BitcoinScript.lockScriptForAddress(
            address: sourceAddress,
            coin: .bitcoin
        ).data
        guard !sourceScript.isEmpty else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        let opReturnScript = try SendBitcoinOPReturn.scriptPubKey(
            for: options.opReturnMessage
        )
        let format = PrivateKeyImportFormat(accountMarker: accountMarker)
        let inputs = try outputs.map { output in
            let value = try SendAtomicAmount.int64(output.valueAtomic)
            guard value > 0 else { throw invalidResponse("input_value") }
            let kind: InputKind
            let publicKeyLength: Int
            if let owner = output.owner {
                publicKeyLength = owner.publicKey.count
                switch owner.addressType {
                case .bip44, .brdLegacy: kind = .legacy
                case .bip49: kind = .nestedSegwit
                case .bip84, .brdSegwit: kind = .nativeSegwit
                case .bip86: kind = .taproot
                }
            } else if output.silentPaymentOwner != nil {
                kind = .taproot
                publicKeyLength = 32
            } else if let format {
                publicKeyLength = format == .wifUncompressed ? 65 : 33
                switch format {
                case .wifUncompressed, .extendedLegacy:
                    kind = .legacy
                case .extendedNestedSegwit:
                    kind = .nestedSegwit
                case .rawSecp256k1, .wifCompressed,
                     .extendedNativeSegwit:
                    kind = .nativeSegwit
                case .solanaSeed, .solanaKeypair, .rawEd25519:
                    throw SendTransactionSubmissionError.secretUnavailable
                }
            } else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            return InputMaterial(
                output: output,
                value: value,
                scriptPubKey: sourceScript,
                privateKey: Data(),
                publicKey: Data(repeating: 0, count: publicKeyLength),
                kind: kind
            )
        }
        let selection = try select(
            inputs: inputs,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            customFee: try totalBudgetAtomic.map(SendAtomicAmount.int64),
            recipientScriptSize: recipientScriptSize,
            changeScriptSize: changeOutputScriptSize ?? sourceScript.count,
            opReturnScriptSize: opReturnScript?.count,
            usesMaximumBalance: usesMaximumBalance,
            automatic: options.coinSelection.selectedUTXOs.isEmpty
        )
        return SendBitcoinSelectionPlan(
            outputs: selection.inputs.map(\.output), feeAtomic: String(selection.fee)
        )
    }
}
