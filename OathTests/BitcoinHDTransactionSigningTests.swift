import CryptoKit
import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct BitcoinHDTransactionSigningTests {
    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"

    @Test(arguments: BitcoinHDAddressType.allCases, [false, true])
    func exactFiveSatBudgetCanBeSignedForEveryAddressType(
        addressType: BitcoinHDAddressType, usesMaximum: Bool
    ) throws {
        let credential = try WalletRecoveryCredential(mnemonic: Self.mnemonic)
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let owner = try derivation.deriveAddress(wallet: wallet, addressType: addressType,
            branch: .external, index: 0)
        let change = try derivation.deriveAddress(wallet: wallet, addressType: addressType,
            branch: .change, index: 0)
        let recipient = try derivation.deriveAddress(wallet: wallet, addressType: .bip84,
            branch: .external, index: 10)
        let outputs = (0..<2).map { index in
            SendBitcoinUTXO(networkID: "bitcoin", outpoint: SendBitcoinOutpoint(
                transactionHash: String(repeating: "11", count: 32), outputIndex: index),
                valueAtomic: "50000", blockHeight: 800_000, confirmations: 10, owner: owner)
        }
        let options = SendBitcoinFamilyOptions(coinSelection: .manual(outputs), replaceByFee: true)
        let draft = SendDraft(request: .manualEntry(networkID: "bitcoin"),
            asset: Self.bitcoinAsset(sourceAddress: owner.address), recipient: recipient.address,
            amount: "0.0005", note: nil, bitcoinFamilyOptions: options, usesMaximumBalance: usesMaximum)
        let budget = try BitcoinSilentPaymentTransactionSigner.estimatedNetworkFeeAtomic(
            outputs: outputs, accountMarker: owner.derivationPath, requestedAtomic: 50_000,
            byteFee: 5, totalBudgetAtomic: nil, options: options, sourceAddress: change.address,
            recipientAddress: recipient.address, usesMaximumBalance: usesMaximum)
        let signed = try SendBitcoinHDTransactionSigner.sign(draft: draft,
            material: SendResolvedSigningMaterial(walletID: "test-wallet", account: Self.account(owner),
                privateKey: Data(), bitcoinHDRecoveryCredential: credential),
            outputs: outputs, requestedAtomic: 50_000, byteFee: 5,
            fee: SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "5",
                secondaryValue: nil, totalBudgetAtomic: budget),
            options: options, changeAddress: change.address, recipientAddress: recipient.address)
        let parsed = try ParsedBitcoinTransaction(signed.encoded)
        let finalized = try SendBitcoinNestedSegwitTransaction.finalize(
            encoded: signed.encoded, nestedPublicKeysByOutpointID: [:])
        #expect(signed.feeAtomic == budget)
        #expect(try #require(Int64(budget)) >= finalized.virtualSize * 5)
        #expect(parsed.outputs.reduce(Int64(0)) { $0 + $1.value } + (Int64(budget) ?? 0) == 100_000)
    }

    @Test(arguments: BitcoinHDAddressType.allCases, [0, 1, 7, 20])
    func signsAndSerializesEverySupportedAddressType(
        _ addressType: BitcoinHDAddressType, addressIndex: Int
    ) throws {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let owner = try derivation.deriveAddress(
            wallet: wallet,
            addressType: addressType,
            branch: .external,
            index: addressIndex
        )
        let recipient = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: addressIndex + 10
        )
        let change = try derivation.deriveAddress(
            wallet: wallet,
            addressType: addressType,
            branch: .change,
            index: addressIndex
        )
        let output = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash:
                    "000102030405060708090a0b0c0d0e0f"
                    + "101112131415161718191a1b1c1d1e1f",
                outputIndex: 3
            ),
            valueAtomic: "100000",
            blockHeight: 800_000,
            confirmations: 10,
            owner: owner
        )
        let opReturnMessage = "Aperture ₿ ✅"
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual([output]),
            replaceByFee: true,
            opReturnMessage: opReturnMessage
        )
        let draft = SendDraft(
            request: .manualEntry(
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ),
            asset: Self.bitcoinAsset(sourceAddress: owner.address),
            recipient: recipient.address,
            amount: "0.0005",
            note: nil,
            bitcoinFamilyOptions: options
        )
        let material = SendResolvedSigningMaterial(
            walletID: "test-wallet",
            account: Self.account(owner),
            privateKey: Data(),
            bitcoinHDRecoveryCredential: credential
        )
        let signed = try SendBitcoinHDTransactionSigner.sign(
            draft: draft,
            material: material,
            outputs: [output],
            requestedAtomic: 50_000,
            byteFee: 2,
            fee: SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: "2",
                secondaryValue: nil
            ),
            options: options,
            changeAddress: change.address,
            recipientAddress: recipient.address
        )

        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        #expect(signed.transactionID == transaction.transactionID)
        #expect(signed.amountAtomic == "50000")
        #expect(try #require(Int64(signed.feeAtomic)) >= Int64((transaction.weight + 3) / 4) * 2)
        #expect(signed.changeAddress == change.address)
        #expect(transaction.inputs.count == 1)
        #expect(transaction.outputs.count == 3)
        #expect(transaction.inputs[0].previousOutputIndex == 3)
        #expect(transaction.inputs[0].sequence == 0xffff_fffd)

        let recipientScript = BitcoinScript.lockScriptForAddress(
            address: recipient.address,
            coin: .bitcoin
        ).data
        let changeScript = BitcoinScript.lockScriptForAddress(
            address: change.address,
            coin: .bitcoin
        ).data
        #expect(transaction.outputs.contains {
            $0.value == 50_000 && $0.script == recipientScript
        })
        #expect(transaction.outputs.contains {
            $0.script == changeScript
        })
        let opReturnPayload = Data(opReturnMessage.utf8)
        let opReturnScript = Data([
            0x6a,
            UInt8(opReturnPayload.count),
        ]) + opReturnPayload
        #expect(transaction.outputs.contains {
            $0.value == 0 && $0.script == opReturnScript
        })
        let totalOutput = transaction.outputs.reduce(Int64(0)) {
            $0 + $1.value
        }
        #expect(totalOutput + (Int64(signed.feeAtomic) ?? 0) == 100_000)

        let input = transaction.inputs[0]
        switch addressType {
        case .bip44, .brdLegacy:
            #expect(!transaction.hasWitness)
            #expect(!input.script.isEmpty)
            #expect(input.witness.isEmpty)
        case .bip49:
            #expect(transaction.hasWitness)
            let redeem = BitcoinScript.buildPayToWitnessPubkeyHash(
                hash: try #require(
                    PublicKey(data: owner.publicKey, type: .secp256k1)
                ).bitcoinKeyHash
            ).data
            #expect(input.script == Data([UInt8(redeem.count)]) + redeem)
            #expect(input.witness.count == 2)
        case .bip84, .brdSegwit:
            #expect(transaction.hasWitness)
            #expect(input.script.isEmpty)
            #expect(input.witness.count == 2)
        case .bip86:
            #expect(transaction.hasWitness)
            #expect(input.script.isEmpty)
            #expect(input.witness.count == 1)
            #expect(input.witness[0].count == 64)
        }
    }

    @Test
    func signsOneTransactionAcrossEverySupportedAddressType() throws {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let owners = try BitcoinHDAddressType.allCases.enumerated().map {
            offset, addressType in
            try derivation.deriveAddress(
                wallet: wallet,
                addressType: addressType,
                branch: .external,
                index: offset
            )
        }
        let recipient = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: 20
        )
        let change = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip86,
            branch: .change,
            index: 20
        )
        let outputs = owners.enumerated().map { offset, owner in
            SendBitcoinUTXO(
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                outpoint: SendBitcoinOutpoint(
                    transactionHash: String(
                        repeating: String(format: "%02x", offset + 1),
                        count: 32
                    ),
                    outputIndex: offset
                ),
                valueAtomic: "25000",
                blockHeight: 800_000 + Int64(offset),
                confirmations: 10,
                owner: owner
            )
        }
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual(outputs),
            replaceByFee: true
        )
        let draft = SendDraft(
            request: .manualEntry(
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ),
            asset: Self.bitcoinAsset(sourceAddress: owners[0].address),
            recipient: recipient.address,
            amount: "0.00085",
            note: nil,
            bitcoinFamilyOptions: options
        )
        let material = SendResolvedSigningMaterial(
            walletID: "test-wallet",
            account: Self.account(owners[0]),
            privateKey: Data(),
            bitcoinHDRecoveryCredential: credential
        )

        let signed = try SendBitcoinHDTransactionSigner.sign(
            draft: draft,
            material: material,
            outputs: outputs,
            requestedAtomic: 85_000,
            byteFee: 2,
            fee: SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: "2",
                secondaryValue: nil
            ),
            options: options,
            changeAddress: change.address,
            recipientAddress: recipient.address
        )

        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        #expect(signed.transactionID == transaction.transactionID)
        #expect(transaction.hasWitness)
        #expect(transaction.inputs.count == BitcoinHDAddressType.allCases.count)
        #expect(transaction.outputs.count == 2)
        #expect(signed.amountAtomic == "85000")
        #expect(signed.changeAddress == change.address)
        #expect(transaction.inputs.allSatisfy {
            $0.sequence == 0xffff_fffd
        })

        let recipientScript = BitcoinScript.lockScriptForAddress(
            address: recipient.address,
            coin: .bitcoin
        ).data
        let changeScript = BitcoinScript.lockScriptForAddress(
            address: change.address,
            coin: .bitcoin
        ).data
        #expect(transaction.outputs.contains {
            $0.value == 85_000 && $0.script == recipientScript
        })
        #expect(transaction.outputs.contains {
            $0.script == changeScript
        })
        let totalOutput = transaction.outputs.reduce(Int64(0)) {
            $0 + $1.value
        }
        #expect(totalOutput + (Int64(signed.feeAtomic) ?? 0) == Int64(owners.count) * 25_000)

        for input in transaction.inputs {
            let outputIndex = Int(input.previousOutputIndex)
            let owner = try #require(
                owners.indices.contains(outputIndex)
                    ? owners[outputIndex]
                    : nil
            )
            switch owner.addressType {
            case .bip44, .brdLegacy:
                #expect(!input.script.isEmpty)
                #expect(input.witness.isEmpty)
            case .bip49:
                let redeem = BitcoinScript.buildPayToWitnessPubkeyHash(
                    hash: try #require(
                        PublicKey(
                            data: owner.publicKey,
                            type: .secp256k1
                        )
                    ).bitcoinKeyHash
                ).data
                #expect(input.script == Data([UInt8(redeem.count)]) + redeem)
                #expect(input.witness.count == 2)
            case .bip84, .brdSegwit:
                #expect(input.script.isEmpty)
                #expect(input.witness.count == 2)
            case .bip86:
                #expect(input.script.isEmpty)
                #expect(input.witness.count == 1)
                #expect(input.witness[0].count == 64)
            }
        }
    }

    @Test
    func signsTwoHundredSixtyMixedInputsAcrossCompactSizeBoundary()
        throws
    {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let owners = try BitcoinHDAddressType.allCases.enumerated().map {
            offset, addressType in
            try derivation.deriveAddress(
                wallet: wallet,
                addressType: addressType,
                branch: .external,
                index: offset
            )
        }
        let recipient = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: 500
        )
        let change = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip86,
            branch: .change,
            index: 500
        )
        let inputCount = 260
        let outputs = (0..<inputCount).map { offset in
            let owner = owners[offset % owners.count]
            return SendBitcoinUTXO(
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                outpoint: SendBitcoinOutpoint(
                    transactionHash: String(
                        repeating: String(
                            format: "%02x",
                            (offset % 251) + 1
                        ),
                        count: 32
                    ),
                    outputIndex: offset
                ),
                valueAtomic: "10000",
                blockHeight: 820_000 + Int64(offset),
                confirmations: 10,
                owner: owner
            )
        }
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual(outputs),
            replaceByFee: true
        )
        let draft = SendDraft(
            request: .manualEntry(
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ),
            asset: Self.bitcoinAsset(sourceAddress: owners[0].address),
            recipient: recipient.address,
            amount: "0.02",
            note: nil,
            bitcoinFamilyOptions: options
        )
        let material = SendResolvedSigningMaterial(
            walletID: "test-wallet",
            account: Self.account(owners[0]),
            privateKey: Data(),
            bitcoinHDRecoveryCredential: credential
        )

        let signed = try SendBitcoinHDTransactionSigner.sign(
            draft: draft,
            material: material,
            outputs: outputs,
            requestedAtomic: 2_000_000,
            byteFee: 2,
            fee: SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: "2",
                secondaryValue: nil
            ),
            options: options,
            changeAddress: change.address,
            recipientAddress: recipient.address
        )

        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        #expect(signed.transactionID == transaction.transactionID)
        #expect(transaction.inputs.count == inputCount)
        #expect(transaction.outputs.count == 2)
        #expect(Set(transaction.inputs.map(\.previousOutputIndex)).count == inputCount)
        #expect(transaction.inputs.allSatisfy {
            $0.sequence == 0xffff_fffd
        })
        for input in transaction.inputs {
            let owner = owners[
                Int(input.previousOutputIndex) % owners.count
            ]
            switch owner.addressType {
            case .bip44, .brdLegacy:
                #expect(!input.script.isEmpty)
                #expect(input.witness.isEmpty)
            case .bip49:
                #expect(!input.script.isEmpty)
                #expect(input.witness.count == 2)
            case .bip84, .brdSegwit:
                #expect(input.script.isEmpty)
                #expect(input.witness.count == 2)
            case .bip86:
                #expect(input.script.isEmpty)
                #expect(input.witness.count == 1)
                #expect(input.witness[0].count == 64)
            }
        }
        let totalOutput = transaction.outputs.reduce(Int64(0)) {
            $0 + $1.value
        }
        #expect(
            totalOutput + (Int64(signed.feeAtomic) ?? 0)
                == Int64(inputCount * 10_000)
        )
    }

    @Test
    func signsOneTransactionAcrossHDAndSilentPaymentInputs() throws {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let owners = try BitcoinHDAddressType.allCases.enumerated().map {
            offset, addressType in
            try derivation.deriveAddress(
                wallet: wallet,
                addressType: addressType,
                branch: .external,
                index: offset
            )
        }
        let recipient = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: 40
        )
        let change = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip86,
            branch: .change,
            index: 40
        )
        let standardOutputs = owners.enumerated().map { offset, owner in
            SendBitcoinUTXO(
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                outpoint: SendBitcoinOutpoint(
                    transactionHash: String(
                        repeating: String(format: "%02x", offset + 31),
                        count: 32
                    ),
                    outputIndex: offset
                ),
                valueAtomic: "30000",
                blockHeight: 810_000 + Int64(offset),
                confirmations: 10,
                owner: owner
            )
        }
        let silentTransactionHash = String(repeating: "ef", count: 32)
        let silentPublicKey = try #require(Data(hexString:
            "3e9fce73d4e77a4809908e3c3a2e54ee"
                + "147b9312dc5044a193d1fc85de46e3c1"
        ))
        let silentPrivateKey = try #require(Data(hexString:
            "91a38c5747d7dc15b2c9600fef41231a"
                + "d48ccb46be2cfa60215c81ce46bfb668"
        ))
        let silentOwner = BitcoinSilentPaymentOutput(
            walletID: "test-wallet",
            transactionHash: silentTransactionHash,
            outputIndex: 4,
            valueAtomic: try BitcoinFamilyAtomicInteger(
                validating: "30000"
            ),
            scriptPubKey: Data([0x51, 0x20]) + silentPublicKey,
            outputPublicKey: silentPublicKey,
            blockHeight: 810_004,
            blockTimestamp: nil,
            isSpent: false,
            spentByTransactionHash: nil
        )
        let silentOutput = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: silentTransactionHash,
                outputIndex: 4
            ),
            valueAtomic: "30000",
            blockHeight: 810_004,
            confirmations: 10,
            silentPaymentOwner: silentOwner
        )
        let outputs = standardOutputs + [silentOutput]
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual(outputs),
            replaceByFee: true
        )
        let draft = SendDraft(
            request: .manualEntry(
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ),
            asset: Self.bitcoinAsset(sourceAddress: owners[0].address),
            recipient: recipient.address,
            amount: "0.002",
            note: nil,
            bitcoinFamilyOptions: options
        )

        let signed = try BitcoinSilentPaymentTransactionSigner.sign(
            draft: draft,
            credential: credential,
            outputs: outputs,
            silentPaymentPrivateKeys: [
                silentOutput.id: silentPrivateKey
            ],
            requestedAtomic: 200_000,
            byteFee: 2,
            fee: SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: "2",
                secondaryValue: nil
            ),
            options: options,
            changeAddress: change.address,
            recipientAddress: recipient.address
        )

        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        #expect(signed.transactionID == transaction.transactionID)
        #expect(signed.spentOutpointIDs == Set(outputs.map(\.id)))
        #expect(transaction.inputs.count == owners.count + 1)
        #expect(transaction.outputs.count == 2)
        #expect(transaction.inputs.allSatisfy {
            $0.sequence == 0xffff_fffd
        })
        #expect(!transaction.inputs[0].script.isEmpty)
        #expect(transaction.inputs[0].witness.isEmpty)
        #expect(!transaction.inputs[1].script.isEmpty)
        #expect(transaction.inputs[1].witness.count == 2)
        #expect(transaction.inputs[2].script.isEmpty)
        #expect(transaction.inputs[2].witness.count == 2)
        #expect(transaction.inputs[3].script.isEmpty)
        #expect(transaction.inputs[3].witness.count == 1)
        #expect(transaction.inputs[3].witness[0].count == 64)
        #expect(!transaction.inputs[4].script.isEmpty)
        #expect(transaction.inputs[4].witness.isEmpty)
        #expect(transaction.inputs[5].script.isEmpty)
        #expect(transaction.inputs[5].witness.count == 2)
        let silentInput = try #require(transaction.inputs.last)
        #expect(silentInput.script.isEmpty)
        #expect(silentInput.witness.count == 1)
        #expect(try #require(silentInput.witness.first).count == 64)
        let totalOutput = transaction.outputs.reduce(Int64(0)) {
            $0 + $1.value
        }
        #expect(totalOutput + (Int64(signed.feeAtomic) ?? 0) == Int64(outputs.count) * 30_000)
    }

    @Test
    func automaticSelectionAddsAnInputForNestedSegwitOverhead()
        throws
    {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let owners = try (0..<2).map {
            try derivation.deriveAddress(
                wallet: wallet,
                addressType: .bip49,
                branch: .external,
                index: $0
            )
        }
        let recipient = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: 30
        )
        let change = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .change,
            index: 30
        )
        let values = [50_000, 20_000]
        let outputs = owners.enumerated().map { offset, owner in
            SendBitcoinUTXO(
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                outpoint: SendBitcoinOutpoint(
                    transactionHash: String(
                        repeating: String(format: "%02x", offset + 11),
                        count: 32
                    ),
                    outputIndex: offset
                ),
                valueAtomic: String(values[offset]),
                blockHeight: 800_100 + Int64(offset),
                confirmations: 10,
                owner: owner
            )
        }
        let options = SendBitcoinFamilyOptions(
            coinSelection: .automatic,
            replaceByFee: false
        )
        let draft = SendDraft(
            request: .manualEntry(
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ),
            asset: Self.bitcoinAsset(sourceAddress: owners[0].address),
            recipient: recipient.address,
            amount: "0.0004988",
            note: nil,
            bitcoinFamilyOptions: options
        )
        let material = SendResolvedSigningMaterial(
            walletID: "test-wallet",
            account: Self.account(owners[0]),
            privateKey: Data(),
            bitcoinHDRecoveryCredential: credential
        )

        let signed = try SendBitcoinHDTransactionSigner.sign(
            draft: draft,
            material: material,
            outputs: outputs,
            requestedAtomic: 49_880,
            byteFee: 1,
            fee: SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: "1",
                secondaryValue: nil
            ),
            options: options,
            changeAddress: change.address,
            recipientAddress: recipient.address
        )

        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        #expect(transaction.inputs.count == 2)
        #expect(transaction.inputs.allSatisfy {
            !$0.script.isEmpty && $0.witness.count == 2
        })
        let totalOutput = transaction.outputs.reduce(Int64(0)) {
            $0 + $1.value
        }
        #expect(totalOutput + (Int64(signed.feeAtomic) ?? 0) == 70_000)
        #expect((Int64(signed.feeAtomic) ?? 0) >= 1)
    }

    private static func bitcoinAsset(
        sourceAddress: String
    ) -> SendAssetChoice {
        SendAssetChoice(
            id: "bitcoin:native",
            name: "Bitcoin",
            symbol: "BTC",
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            networkName: "Bitcoin",
            blockchain: .bitcoin,
            contractAddress: nil,
            decimals: 8,
            logoSource: .nativeCoin(blockchain: .bitcoin),
            networkLogoSource: .nativeCoin(blockchain: .bitcoin),
            balance: 0.001,
            fiatValue: 0,
            balanceAtomic: "100000",
            sourceAddress: sourceAddress
        )
    }

    private static func account(
        _ owner: BitcoinHDDerivedAddress
    ) -> DBWalletAccountRecord {
        DBWalletAccountRecord(
            id: "test-wallet:bitcoin:0",
            walletID: "test-wallet",
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            address: owner.address,
            normalizedAddress: owner.address.lowercased(),
            label: nil,
            derivationPath: owner.derivationPath,
            accountIndex: 0,
            publicKey: owner.publicKey.hexString,
            isWatchOnly: false,
            isEnabled: true,
            createdAt: 0,
            updatedAt: 0,
            lastSyncedAt: nil
        )
    }
}

struct ParsedBitcoinTransaction {
    struct Input {
        let previousOutputIndex: UInt32
        let script: Data
        let sequence: UInt32
        var witness: [Data]
    }

    struct Output {
        let value: Int64
        let script: Data
    }

    let hasWitness: Bool
    let inputs: [Input]
    let outputs: [Output]
    let transactionID: String
    let weight: Int

    init(_ data: Data) throws {
        var reader = BitcoinTransactionReader(data)
        let version = try reader.read(count: 4)
        let witnessMarker = reader.remainingCount >= 2
            && reader.peek() == 0
            && reader.peek(offset: 1) != 0
        if witnessMarker {
            _ = try reader.readByte()
            _ = try reader.readByte()
        }
        let bodyStart = reader.offset
        let inputCount = try reader.readVariableInteger()
        var parsedInputs: [Input] = []
        parsedInputs.reserveCapacity(inputCount)
        for _ in 0..<inputCount {
            _ = try reader.read(count: 32)
            let previousOutputIndex = try reader.readUInt32()
            let script = try reader.readVariableData()
            let sequence = try reader.readUInt32()
            parsedInputs.append(
                Input(
                    previousOutputIndex: previousOutputIndex,
                    script: script,
                    sequence: sequence,
                    witness: []
                )
            )
        }
        let outputCount = try reader.readVariableInteger()
        var parsedOutputs: [Output] = []
        parsedOutputs.reserveCapacity(outputCount)
        for _ in 0..<outputCount {
            let value = try reader.readInt64()
            let script = try reader.readVariableData()
            parsedOutputs.append(Output(value: value, script: script))
        }
        let bodyEnd = reader.offset
        if witnessMarker {
            for index in parsedInputs.indices {
                let count = try reader.readVariableInteger()
                var items: [Data] = []
                items.reserveCapacity(count)
                for _ in 0..<count {
                    items.append(try reader.readVariableData())
                }
                parsedInputs[index].witness = items
            }
        }
        let lockTime = try reader.read(count: 4)
        guard reader.remainingCount == 0 else {
            throw BitcoinTransactionParseError.trailingBytes
        }

        var stripped = version
        stripped.append(data[bodyStart..<bodyEnd])
        stripped.append(lockTime)
        weight = stripped.count * 3 + data.count
        let firstHash = Data(SHA256.hash(data: stripped))
        let secondHash = Data(SHA256.hash(data: firstHash))
        transactionID = secondHash.reversed()
            .map { String(format: "%02x", $0) }
            .joined()
        hasWitness = witnessMarker
        inputs = parsedInputs
        outputs = parsedOutputs
    }
}

private enum BitcoinTransactionParseError: Error {
    case truncated
    case invalidVariableInteger
    case integerOverflow
    case trailingBytes
}

private struct BitcoinTransactionReader {
    let data: Data
    private(set) var offset = 0

    var remainingCount: Int { data.count - offset }

    init(_ data: Data) {
        self.data = data
    }

    func peek(offset additionalOffset: Int = 0) -> UInt8? {
        let index = offset + additionalOffset
        guard data.indices.contains(index) else { return nil }
        return data[index]
    }

    mutating func readByte() throws -> UInt8 {
        guard let value = peek() else {
            throw BitcoinTransactionParseError.truncated
        }
        offset += 1
        return value
    }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, remainingCount >= count else {
            throw BitcoinTransactionParseError.truncated
        }
        let start = offset
        offset += count
        return data[start..<offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try read(count: 2)
        return bytes.enumerated().reduce(UInt16(0)) {
            $0 | (UInt16($1.element) << UInt16($1.offset * 8))
        }
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try read(count: 4)
        return bytes.enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try read(count: 8)
        return bytes.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
    }

    mutating func readInt64() throws -> Int64 {
        let value = try readUInt64()
        guard value <= UInt64(Int64.max) else {
            throw BitcoinTransactionParseError.integerOverflow
        }
        return Int64(value)
    }

    mutating func readVariableInteger() throws -> Int {
        let prefix = try readByte()
        let value: UInt64
        switch prefix {
        case 0..<0xfd:
            value = UInt64(prefix)
        case 0xfd:
            value = UInt64(try readUInt16())
            guard value >= 0xfd else {
                throw BitcoinTransactionParseError
                    .invalidVariableInteger
            }
        case 0xfe:
            value = UInt64(try readUInt32())
            guard value > UInt64(UInt16.max) else {
                throw BitcoinTransactionParseError
                    .invalidVariableInteger
            }
        case 0xff:
            value = try readUInt64()
            guard value > UInt64(UInt32.max) else {
                throw BitcoinTransactionParseError
                    .invalidVariableInteger
            }
        default:
            throw BitcoinTransactionParseError.invalidVariableInteger
        }
        guard let count = Int(exactly: value), count <= remainingCount else {
            throw BitcoinTransactionParseError.integerOverflow
        }
        return count
    }

    mutating func readVariableData() throws -> Data {
        try read(count: readVariableInteger())
    }
}
