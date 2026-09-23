import Foundation
import P256K
import WalletCore

extension BitcoinSilentPaymentTransactionSigner {
    static func signImportedWallet(
        draft: SendDraft, material: BitcoinImportedWalletMaterial, outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64, byteFee: Int64, fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions, changeAddress: String, recipientAddress: String
    ) throws -> SendBitcoinSignedTransaction {
        guard !outputs.isEmpty, byteFee > 0 else { throw SendTransactionSubmissionError.secretUnavailable }
        let inputs = try outputs.map { output -> InputMaterial in
            guard output.networkID == "bitcoin", output.silentPaymentOwner == nil, let owner = output.owner else {
                throw SendTransactionSubmissionError.derivedAddressMismatch
            }
            let parts = owner.derivationPath.split(separator: ":")
            guard parts.count == 4, let id = Int(parts[1]), material.sources.indices.contains(id),
                  let branch = Int(parts[2]), let index = Int(parts[3]) else {
                throw SendTransactionSubmissionError.derivedAddressMismatch
            }
            let descriptor = material.sources[id].descriptor
            guard try descriptor.address(branch: branch, index: index, sourceID: String(id)) == owner else {
                throw SendTransactionSubmissionError.derivedAddressMismatch
            }
            let key = try material.privateKey(path: owner.derivationPath)
            let value = try SendAtomicAmount.int64(output.valueAtomic)
            guard value > 0 else { throw SendTransactionSubmissionError.invalidAmount }
            let kind: InputKind
            switch descriptor.script {
            case .pkh: kind = .legacy
            case .wpkh: kind = .nativeSegwit
            case .shWpkh: kind = .nestedSegwit
            case .tr, .rawtr: kind = .taproot
            }
            let signingKey = descriptor.script == .tr
                ? try BitcoinSilentPaymentCrypto.taprootKeyPathPrivateKey(internalPrivateKey: key) : key
            let publicKey = descriptor.script == .tr || descriptor.script == .rawtr
                ? Data(try P256K.Signing.PrivateKey(dataRepresentation: signingKey).publicKey.xonly.bytes) : owner.publicKey
            return InputMaterial(output: output, value: value, scriptPubKey: owner.scriptPubKey,
                                 privateKey: signingKey, publicKey: publicKey, kind: kind)
        }
        return try sign(draft: draft, inputs: inputs, requestedAtomic: requestedAtomic, byteFee: byteFee,
                        fee: fee, options: options, changeAddress: changeAddress, recipientAddress: recipientAddress)
    }
}
