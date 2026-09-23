import Foundation
import WalletCore

enum SendBitcoinSingleKeyTransactionSigner {
    static func sign(
        draft: SendDraft,
        privateKeyData: Data,
        format: PrivateKeyImportFormat,
        outputs: [SendBitcoinUTXO],
        requestedAtomic: Int64,
        byteFee: Int64,
        fee: SendResolvedNetworkFee,
        options: SendBitcoinFamilyOptions,
        senderAddress: String,
        changeAddress: String,
        recipientAddress: String
    ) throws -> SendBitcoinSignedTransaction {
        guard [.wifCompressed, .wifUncompressed].contains(format),
              let privateKey = PrivateKey(data: privateKeyData),
              !outputs.isEmpty else {
            throw SendTransactionSubmissionError.secretUnavailable
        }
        let addresses = try BitcoinHDDerivationService()
            .singleKeyAddresses(
                privateKeyData: privateKeyData,
                format: format
            )
        let byType = Dictionary(
            uniqueKeysWithValues: addresses.map {
                ($0.addressType, $0)
            }
        )
        let primaryType: BitcoinHDAddressType = format == .wifCompressed
            ? .bip84 : .bip44
        guard byType[primaryType]?.address == senderAddress,
              addresses.contains(where: {
                  $0.address == changeAddress
              }) else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }

        // Wallet Core's generic Bitcoin signer always serializes compressed
        // public keys. Keep uncompressed (`5...`) WIF spending on the custom
        // signer, which serializes the original 65-byte SEC public key.
        if format == .wifUncompressed {
            let unownedOutputs = outputs.map { output in
                SendBitcoinUTXO(
                    networkID: output.networkID,
                    outpoint: output.outpoint,
                    valueAtomic: output.valueAtomic,
                    blockHeight: output.blockHeight,
                    confirmations: output.confirmations
                )
            }
            let signingOptions: SendBitcoinFamilyOptions
            switch options.coinSelection {
            case .automatic:
                signingOptions = options
            case .manual:
                signingOptions = options.replacingCoinSelection(
                    .manual(unownedOutputs)
                )
            }
            return try BitcoinSilentPaymentTransactionSigner.signSingleKey(
                draft: draft,
                privateKey: privateKeyData,
                format: format,
                outputs: unownedOutputs,
                requestedAtomic: requestedAtomic,
                byteFee: byteFee,
                fee: fee,
                options: signingOptions,
                senderAddress: senderAddress,
                recipientAddress: recipientAddress
            )
        }

        let publicKey = privateKey.getPublicKeySecp256k1(
            compressed: format == .wifCompressed
        )
        let owned = try outputs.map { output in
            guard output.networkID
                    == BitcoinFamilyChain.bitcoin.networkID,
                  output.silentPaymentOwner == nil,
                  let owner = output.owner,
                  let expected = byType[owner.addressType],
                  expected == owner,
                  expected.publicKey == publicKey.data else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            return SendBitcoinHDTransactionSigner.OwnedInput(
                output: output,
                owner: owner,
                privateKey: privateKey,
                publicKey: publicKey
            )
        }
        return try SendBitcoinHDTransactionSigner.signV2(
            draft: draft,
            inputs: owned,
            requestedAtomic: requestedAtomic,
            byteFee: byteFee,
            fee: fee,
            options: options,
            changeAddress: changeAddress,
            recipientAddress: recipientAddress,
            silentPaymentAddress: try? BitcoinSilentPaymentAddress(
                recipientAddress
            )
        )
    }
}
