import Foundation
import Testing
import WalletCore
@testable import Aperture

struct BitcoinOPReturnSigningFixture {
    let credential: WalletRecoveryCredential
    let owners: [BitcoinHDDerivedAddress]
    let outputs: [SendBitcoinUTXO]
    let recipient: String
    let recipientScript: Data
    let change: String

    init(types: [BitcoinHDAddressType], silentRecipient: Bool = false,
         value: Int64 = 100_000) throws {
        credential = try WalletRecoveryCredential(mnemonic:
            "abandon abandon abandon abandon abandon abandon "
            + "abandon abandon abandon abandon abandon about")
        let wallet = try #require(credential.makeHDWallet())
        let service = BitcoinHDDerivationService()
        owners = try types.map {
            try service.deriveAddress(wallet: wallet, addressType: $0,
                                      branch: .external, index: 0)
        }
        outputs = owners.enumerated().map {
            Self.output(owner: $0.element, index: $0.offset, value: value)
        }
        change = try service.deriveAddress(
            wallet: wallet, addressType: types[0], branch: .change, index: 0
        ).address
        if silentRecipient {
            let scan = try #require(PrivateKey(data: Data(repeating: 0x22, count: 32)))
            let spend = try #require(PrivateKey(data: Data(repeating: 0x33, count: 32)))
            let address = try BitcoinSilentPaymentAddress(
                scanPublicKey: scan.getPublicKeySecp256k1(compressed: true).data,
                spendPublicKey: spend.getPublicKeySecp256k1(compressed: true).data
            )
            recipient = address.encoded
            let secrets = try zip(owners, outputs).map { owner, output in
                let key = try service.privateKey(
                    wallet: wallet, addressType: owner.addressType,
                    branch: .external, index: 0
                ).data
                let scalar = owner.addressType == .bip86
                    ? try BitcoinSilentPaymentCrypto.taprootKeyPathPrivateKey(
                        internalPrivateKey: key) : key
                let hash = try #require(Data(bitcoinHex: output.outpoint.transactionHash))
                var index = UInt32(output.outpoint.outputIndex).littleEndian
                let suffix = withUnsafeBytes(of: &index) { Data($0) }
                return try BitcoinSilentPaymentInputSecret(
                    outpoint: Data(hash.reversed()) + suffix, privateKey: scalar,
                    isTaproot: owner.addressType == .bip86
                )
            }
            recipientScript = try BitcoinSilentPaymentCrypto.destination(
                address: address, inputs: secrets
            ).scriptPubKey
        } else {
            recipient = try service.deriveAddress(
                wallet: wallet, addressType: .bip84, branch: .external, index: 10
            ).address
            recipientScript = BitcoinScript.lockScriptForAddress(
                address: recipient, coin: .bitcoin
            ).data
        }
    }

    static func output(owner: BitcoinHDDerivedAddress, index: Int,
                       value: Int64 = 100_000) -> SendBitcoinUTXO {
        SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: String(repeating: "12", count: 32),
                outputIndex: index
            ), valueAtomic: String(value), blockHeight: 0,
            confirmations: 0, owner: owner
        )
    }

    static func fee(budget: String? = nil) -> SendResolvedNetworkFee {
        SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "2",
                               secondaryValue: nil, totalBudgetAtomic: budget)
    }

    func draft(options: SendBitcoinFamilyOptions, usesMaximumBalance: Bool = true) -> SendDraft {
        SendDraft(
            request: .manualEntry(networkID: BitcoinFamilyChain.bitcoin.networkID),
            asset: SendAssetChoice(
                id: "bitcoin:native", name: "Bitcoin", symbol: "BTC",
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                networkName: "Bitcoin", blockchain: .bitcoin,
                contractAddress: nil, decimals: 8,
                logoSource: .nativeCoin(blockchain: .bitcoin),
                networkLogoSource: .nativeCoin(blockchain: .bitcoin),
                balance: 0.001, fiatValue: 0, balanceAtomic: "100000",
                sourceAddress: owners[0].address
            ), recipient: recipient, amount: "0.001", note: nil,
            bitcoinFamilyOptions: options, usesMaximumBalance: usesMaximumBalance
        )
    }

    func sign(message: String, manual: Bool = false,
              budget: String? = nil, usesMaximumBalance: Bool = true,
              changeAddress: String? = nil) throws -> SendBitcoinSignedTransaction {
        let owner = owners[0]
        let account = DBWalletAccountRecord(
            id: "fixture:bitcoin:0", walletID: "fixture",
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            address: owner.address, normalizedAddress: owner.address.lowercased(),
            label: nil, derivationPath: owner.derivationPath, accountIndex: 0,
            publicKey: owner.publicKey.hexString, isWatchOnly: false,
            isEnabled: true, createdAt: 0, updatedAt: 0, lastSyncedAt: nil
        )
        let options = SendBitcoinFamilyOptions(
            coinSelection: manual ? .manual(outputs) : .automatic,
            replaceByFee: true, opReturnMessage: message
        )
        return try SendBitcoinHDTransactionSigner.sign(
            draft: draft(options: options, usesMaximumBalance: usesMaximumBalance), material: SendResolvedSigningMaterial(
                walletID: "fixture", account: account, privateKey: Data(),
                bitcoinHDRecoveryCredential: credential
            ), outputs: outputs, requestedAtomic: 100_000, byteFee: 2,
            fee: Self.fee(budget: budget), options: options,
            changeAddress: changeAddress ?? change, recipientAddress: recipient
        )
    }

    func verify(_ signed: SendBitcoinSignedTransaction, message: String,
                budget: Int64? = nil) throws {
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        let fee = try #require(Int64(signed.feeAtomic))
        let amount = try #require(Int64(signed.amountAtomic))
        let available = try outputs.reduce(Int64(0)) {
            $0 + (try #require(Int64($1.valueAtomic)))
        }
        #expect(transaction.transactionID == signed.transactionID)
        #expect(signed.changeAddress == nil)
        #expect(transaction.inputs.count == outputs.count)
        #expect(transaction.inputs.allSatisfy { $0.sequence == 0xffff_fffd })
        #expect(transaction.outputs.count == (message.isEmpty ? 1 : 2))
        #expect(transaction.outputs[0].script == recipientScript)
        #expect(transaction.outputs[0].value == amount)
        #expect(amount >= 546)
        #expect(amount + fee == available)
        #expect(transaction.outputs.reduce(Int64(0)) { $0 + $1.value } + fee == available)
        if !message.isEmpty {
            let payload = Data(message.utf8)
            #expect(try BitcoinOPReturnScriptTests.decodePayload(transaction.outputs[1].script) == payload)
            #expect(transaction.outputs[1].value == 0)
        }
        // Decode the signed wire data to measure its fee, including witness weight.
        let measured = try SendBitcoinNestedSegwitTransaction.finalize(
            encoded: signed.encoded, nestedPublicKeysByOutpointID: [:]
        )
        #expect(fee >= measured.virtualSize * 2)
        if let budget { #expect(fee == budget) }
    }
}
