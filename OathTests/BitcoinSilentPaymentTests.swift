import CryptoKit
import Foundation
import GRDB
import P256K
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct BitcoinSilentPaymentTests {
    private static let vectorAddress =
        "sp1qqgste7k9hx0qftg6qmwlkqtwuy6cycyavzmzj85c6qdfhjdpdjtdgqjuex"
        + "zk6murw56suy3e0rd2cgqvycxttddwsvgxe2usfpxumr70xc9pkqwv"

    @Test
    func addressCodecAcceptsOfficialVectorAndUserSample() throws {
        let official = try BitcoinSilentPaymentAddress(Self.vectorAddress)
        #expect(official.encoded == Self.vectorAddress)
        #expect(
            official.scanPublicKey.hexString
                == "0220bcfac5b99e04ad1a06ddfb016ee13582609d60b6291e98d01a9bc9a16c96d4"
        )
        #expect(
            official.spendPublicKey.hexString
                == "025cc9856d6f8375350e123978daac200c260cb5b5ae83106cab90484dcd8fcf36"
        )

        let userSample =
            "sp1qqvtmgkffyptnzpksadwgy9cnzmav6lj6ut5ukvqsfyg02ca3nupkcq3euzr"
            + "jdat44jmvsdnvefurd8vpwxrgyln0z37tlljsfqllt7w7kcq6mng2"
        #expect(try BitcoinSilentPaymentAddress(userSample).encoded == userSample)
        #expect(!BitcoinSilentPaymentAddress.isValidMainnet("tsp1qqqqqq"))

        var invalidChecksum = userSample
        invalidChecksum.replaceSubrange(
            invalidChecksum.index(before: invalidChecksum.endIndex)...,
            with: "q"
        )
        #expect(!BitcoinSilentPaymentAddress.isValidMainnet(invalidChecksum))
    }

    @Test
    func rawTransactionParserRejectsOversizedLengthsWithoutOverflow() {
        let malformed = "0100000001"
            + String(repeating: "00", count: 36)
            + "ff" + "ffffffffffffff7f"
        #expect(BitcoinRawTransaction(hex: malformed) == nil)
    }

    @Test
    func senderMatchesOfficialSimpleTwoInputVector() throws {
        let address = try BitcoinSilentPaymentAddress(Self.vectorAddress)
        let inputs = try [
            BitcoinSilentPaymentInputSecret(
                outpoint: Self.outpoint(
                    txid: "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16",
                    vout: 0
                ),
                privateKey: try Self.data(
                    "eadc78165ff1f8ea94ad7cfdc54990738a4c53f6e0507b42154201b8e5dff3b1"
                ),
                isTaproot: false
            ),
            BitcoinSilentPaymentInputSecret(
                outpoint: Self.outpoint(
                    txid: "a1075db55d416d3ca199f55b6084e2115b9345e16c5cf302fc80e9d5fbf5d48d",
                    vout: 0
                ),
                privateKey: try Self.data(
                    "93f5ed907ad5b2bdbbdcb5d9116ebc0a4e1f92f910d5260237fa45a9408aad16"
                ),
                isTaproot: false
            ),
        ]

        let destination = try BitcoinSilentPaymentCrypto.destination(
            address: address,
            inputs: inputs
        )
        #expect(
            destination.outputPublicKey.hexString
                == "3e9fce73d4e77a4809908e3c3a2e54ee147b9312dc5044a193d1fc85de46e3c1"
        )
        #expect(
            destination.sharedSecretTweak.hexString
                == "f438b40179a3c4262de12986c0e6cce0634007cdc79c1dcd3e20b9ebc2e7eef6"
        )
        #expect(
            destination.scriptPubKey.hexString
                == "51203e9fce73d4e77a4809908e3c3a2e54ee147b9312dc5044a193d1fc85de46e3c1"
        )
    }

    @Test
    func senderMatchesOfficialMixedParityTaprootVector() throws {
        let address = try BitcoinSilentPaymentAddress(Self.vectorAddress)
        let inputs = try [
            BitcoinSilentPaymentInputSecret(
                outpoint: Self.outpoint(
                    txid: "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16",
                    vout: 0
                ),
                privateKey: try Self.data(
                    "eadc78165ff1f8ea94ad7cfdc54990738a4c53f6e0507b42154201b8e5dff3b1"
                ),
                isTaproot: true
            ),
            BitcoinSilentPaymentInputSecret(
                outpoint: Self.outpoint(
                    txid: "a1075db55d416d3ca199f55b6084e2115b9345e16c5cf302fc80e9d5fbf5d48d",
                    vout: 0
                ),
                privateKey: try Self.data(
                    "1d37787c2b7116ee983e9f9c13269df29091b391c04db94239e0d2bc2182c3bf"
                ),
                isTaproot: true
            ),
        ]

        let destination = try BitcoinSilentPaymentCrypto.destination(
            address: address,
            inputs: inputs
        )
        #expect(
            destination.outputPublicKey.hexString
                == "77cab7dd12b10259ee82c6ea4b509774e33e7078e7138f568092241bf26b99f1"
        )
        #expect(
            destination.sharedSecretTweak.hexString
                == "f5382508609771068ed079b24e1f72e4a17ee6d1c979066bf1d4e2a5676f09d4"
        )
    }

    @Test
    func receiverMatchesOfficialSimpleTwoInputVector() throws {
        let material = BitcoinSilentPaymentKeyMaterial(
            version: BitcoinSilentPaymentKeyMaterial.currentVersion,
            walletID: "vector-wallet",
            scanPrivateKey: try Self.data(
                "0f694e068028a717f8af6b9411f9a133dd3565258714cc226594b34db90c1f2c"
            ),
            spendPrivateKey: try Self.data(
                "9d6ad855ce3417ef84e836892e5a56392bfba05fa5d97ccea30e266f540e08b3"
            ),
            address: Self.vectorAddress
        )
        let outputKey = try Self.data(
            "3e9fce73d4e77a4809908e3c3a2e54ee147b9312dc5044a193d1fc85de46e3c1"
        )
        let matches = try BitcoinSilentPaymentCrypto.locateOutputs(
            keyMaterial: material,
            tweakPublicKey: try Self.data(
                "024ac253c216532e961988e2a8ce266a447c894c781e52ef6cee902361db960004"
            ),
            transactionOutputs: [Data([0x51, 0x20]) + outputKey]
        )
        let match = try #require(matches.first)
        #expect(matches.count == 1)
        #expect(match.outputIndex == 0)
        #expect(match.outputCounter == 0)
        #expect(match.label == nil)
        #expect(match.outputPublicKey == outputKey)
        #expect(
            match.privateKey.hexString
                == "91a38c5747d7dc15b2c9600fef41231ad48ccb46be2cfa60215c81ce46bfb668"
        )
    }

    @Test
    func decodesVerifiedFrigateNotificationSchema() throws {
        let payload = Data(
            """
            {"jsonrpc":"2.0","method":"blockchain.silentpayments.subscribe","params":{"subscription":{"address":"\(Self.vectorAddress)","labels":[0],"start_height":964741},"progress":1.0,"history":[]},"id":1}
            """.utf8
        )
        let preserved = BitcoinFamilyLosslessJSON
            .preservingNumberLexemes(in: payload)
        let response = try JSONDecoder().decode(
            BitcoinSilentPaymentFrigateResponse.self,
            from: preserved
        )
        #expect(response.id?.value == 1)
        #expect(
            response.method == "blockchain.silentpayments.subscribe"
        )
        let parameters = try #require(response.params?.object)
        #expect(parameters["progress"]?.string == "1.0")
        #expect(parameters["history"]?.array?.isEmpty == true)
        #expect(
            parameters["subscription"]?.object?["address"]?.string
                == Self.vectorAddress
        )
    }

    @Test
    func parsesBareAndBIP321SilentPaymentRequests() throws {
        let bare = try SendPaymentRequestParser.parse(Self.vectorAddress)
        #expect(bare.recipient == Self.vectorAddress)
        #expect(bare.candidateNetworkIDs == [
            BitcoinFamilyChain.bitcoin.networkID
        ])

        let uri = try SendPaymentRequestParser.parse(
            "bitcoin:?sp=\(Self.vectorAddress)&amount=0.00125"
        )
        #expect(uri.source == .bitcoinURI)
        #expect(uri.recipient == Self.vectorAddress)
        #expect(uri.requestedNetworkID == BitcoinFamilyChain.bitcoin.networkID)
        #expect(uri.requestedAsset == .native)
        #expect(uri.requestedAmount == .userUnits("0.00125"))

        let fallback = try SendPaymentRequestParser.parse(
            "bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
                + "?sp=\(Self.vectorAddress)&amount=0.0005"
        )
        #expect(fallback.recipient == Self.vectorAddress)
        #expect(fallback.requestedAmount == .userUnits("0.0005"))
    }

    @Test(arguments: BitcoinHDAddressType.allCases)
    func productionHDSignerSendsEveryInputTypeToSilentPayments(
        _ addressType: BitcoinHDAddressType
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
            index: 0
        )
        let change = try derivation.deriveAddress(
            wallet: wallet,
            addressType: addressType,
            branch: .change,
            index: 0
        )
        let transactionHash = String(
            repeating: String(format: "%02x", addressType.purposeNumber % 255),
            count: 32
        )
        let output = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: transactionHash,
                outputIndex: 1
            ),
            valueAtomic: "100000",
            blockHeight: 800_000,
            confirmations: 10,
            owner: owner
        )
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual([output]),
            replaceByFee: true
        )
        let draft = Self.draft(
            sourceAddress: owner.address,
            recipient: Self.vectorAddress,
            amount: "0.0005",
            options: options
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
            fee: Self.fee,
            options: options,
            changeAddress: change.address,
            recipientAddress: Self.vectorAddress
        )
        let privateKey = try derivation.privateKey(
            wallet: wallet,
            addressType: addressType,
            branch: .external,
            index: 0
        )
        let inputKey = addressType == .bip86
            ? try BitcoinSilentPaymentCrypto.taprootKeyPathPrivateKey(
                internalPrivateKey: privateKey.data
            )
            : privateKey.data
        let expected = try BitcoinSilentPaymentCrypto.destination(
            address: BitcoinSilentPaymentAddress(Self.vectorAddress),
            inputs: [
                try BitcoinSilentPaymentInputSecret(
                    outpoint: Self.outpoint(
                        txid: transactionHash,
                        vout: 1
                    ),
                    privateKey: inputKey,
                    isTaproot: addressType == .bip86
                )
            ]
        )
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        let rawTransaction = try #require(
            BitcoinRawTransaction(hex: signed.encoded.hexString)
        )
        #expect(signed.transactionID == transaction.transactionID)
        #expect(rawTransaction.transactionID == signed.transactionID)
        #expect(transaction.outputs.contains {
            $0.value == 50_000 && $0.script == expected.scriptPubKey
        })
    }

    @Test
    func signsStandardInputToSilentPaymentDestination() throws {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let owner = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: 0
        )
        let change = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .change,
            index: 0
        )
        let transactionHash =
            "000102030405060708090a0b0c0d0e0f"
            + "101112131415161718191a1b1c1d1e1f"
        let output = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: transactionHash,
                outputIndex: 3
            ),
            valueAtomic: "100000",
            blockHeight: 800_000,
            confirmations: 10,
            owner: owner
        )
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual([output]),
            replaceByFee: true
        )
        let draft = Self.draft(
            sourceAddress: owner.address,
            recipient: Self.vectorAddress,
            amount: "0.0005",
            options: options
        )
        let signed = try BitcoinSilentPaymentTransactionSigner.sign(
            draft: draft,
            credential: credential,
            outputs: [output],
            silentPaymentPrivateKeys: [:],
            requestedAtomic: 50_000,
            byteFee: 2,
            fee: Self.fee,
            options: options,
            changeAddress: change.address,
            recipientAddress: Self.vectorAddress
        )
        let privateKey = try derivation.privateKey(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: 0
        )
        let expected = try BitcoinSilentPaymentCrypto.destination(
            address: try BitcoinSilentPaymentAddress(Self.vectorAddress),
            inputs: [
                try BitcoinSilentPaymentInputSecret(
                    outpoint: Self.outpoint(
                        txid: transactionHash,
                        vout: 3
                    ),
                    privateKey: privateKey.data,
                    isTaproot: false
                )
            ]
        )
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        #expect(signed.transactionID == transaction.transactionID)
        #expect(signed.spentOutpointIDs == [output.id])
        #expect(transaction.inputs.count == 1)
        #expect(transaction.inputs[0].witness.count == 2)
        #expect(transaction.outputs.contains {
            $0.value == 50_000 && $0.script == expected.scriptPubKey
        })
    }

    @Test
    func signsMixedStandardAndSilentPaymentInputsToSilentPaymentDestination()
        throws
    {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let standardOwner = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: 2
        )
        let change = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .change,
            index: 2
        )
        let standardHash = String(repeating: "cd", count: 32)
        let silentHash = String(repeating: "ab", count: 32)
        let outputPublicKey = try Self.data(
            "3e9fce73d4e77a4809908e3c3a2e54ee147b9312dc5044a193d1fc85de46e3c1"
        )
        let outputPrivateKey = try Self.data(
            "91a38c5747d7dc15b2c9600fef41231ad48ccb46be2cfa60215c81ce46bfb668"
        )
        let silentScript = Data([0x51, 0x20]) + outputPublicKey
        let silentOwner = BitcoinSilentPaymentOutput(
            walletID: "test-wallet",
            transactionHash: silentHash,
            outputIndex: 2,
            valueAtomic: try BitcoinFamilyAtomicInteger(
                validating: "70000"
            ),
            scriptPubKey: silentScript,
            outputPublicKey: outputPublicKey,
            blockHeight: 800_000,
            blockTimestamp: nil,
            isSpent: false,
            spentByTransactionHash: nil
        )
        let standardOutput = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: standardHash,
                outputIndex: 1
            ),
            valueAtomic: "60000",
            blockHeight: 800_000,
            confirmations: 10,
            owner: standardOwner
        )
        let silentOutput = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: silentHash,
                outputIndex: 2
            ),
            valueAtomic: "70000",
            blockHeight: 800_000,
            confirmations: 10,
            silentPaymentOwner: silentOwner
        )
        let outputs = [standardOutput, silentOutput]
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual(outputs),
            replaceByFee: true
        )
        let draft = Self.draft(
            sourceAddress: standardOwner.address,
            recipient: Self.vectorAddress,
            amount: "0.001",
            options: options
        )
        let signed = try BitcoinSilentPaymentTransactionSigner.sign(
            draft: draft,
            credential: credential,
            outputs: outputs,
            silentPaymentPrivateKeys: [
                silentOutput.id: outputPrivateKey
            ],
            requestedAtomic: 100_000,
            byteFee: 2,
            fee: Self.fee,
            options: options,
            changeAddress: change.address,
            recipientAddress: Self.vectorAddress
        )
        let standardPrivateKey = try derivation.privateKey(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: 2
        )
        let expected = try BitcoinSilentPaymentCrypto.destination(
            address: try BitcoinSilentPaymentAddress(Self.vectorAddress),
            inputs: [
                try BitcoinSilentPaymentInputSecret(
                    outpoint: Self.outpoint(txid: standardHash, vout: 1),
                    privateKey: standardPrivateKey.data,
                    isTaproot: false
                ),
                try BitcoinSilentPaymentInputSecret(
                    outpoint: Self.outpoint(txid: silentHash, vout: 2),
                    privateKey: outputPrivateKey,
                    isTaproot: true
                ),
            ]
        )
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        #expect(signed.transactionID == transaction.transactionID)
        #expect(signed.spentOutpointIDs == Set(outputs.map(\.id)))
        #expect(transaction.inputs.count == 2)
        #expect(transaction.inputs[0].witness.count == 2)
        #expect(transaction.inputs[1].witness.count == 1)
        #expect(transaction.outputs.contains {
            $0.value == 100_000 && $0.script == expected.scriptPubKey
        })
    }

    @Test
    func spendsUnconfirmedSilentPaymentOutputWithValidTaprootSignature()
        throws
    {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let recipient = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: 11
        )
        let change = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .change,
            index: 11
        )
        let transactionHash = String(repeating: "ab", count: 32)
        let outputPublicKey = try Self.data(
            "3e9fce73d4e77a4809908e3c3a2e54ee147b9312dc5044a193d1fc85de46e3c1"
        )
        let outputPrivateKey = try Self.data(
            "91a38c5747d7dc15b2c9600fef41231ad48ccb46be2cfa60215c81ce46bfb668"
        )
        let script = Data([0x51, 0x20]) + outputPublicKey
        let owner = BitcoinSilentPaymentOutput(
            walletID: "test-wallet",
            transactionHash: transactionHash,
            outputIndex: 2,
            valueAtomic: try BitcoinFamilyAtomicInteger(
                validating: "100000"
            ),
            scriptPubKey: script,
            outputPublicKey: outputPublicKey,
            blockHeight: nil,
            blockTimestamp: nil,
            isSpent: false,
            spentByTransactionHash: nil
        )
        let output = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: transactionHash,
                outputIndex: 2
            ),
            valueAtomic: "100000",
            blockHeight: 0,
            confirmations: 0,
            silentPaymentOwner: owner
        )
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual([output]),
            replaceByFee: true
        )
        let draft = Self.draft(
            sourceAddress: recipient.address,
            recipient: recipient.address,
            amount: "0.0005",
            options: options
        )
        let signed = try BitcoinSilentPaymentTransactionSigner.sign(
            draft: draft,
            credential: credential,
            outputs: [output],
            silentPaymentPrivateKeys: [output.id: outputPrivateKey],
            requestedAtomic: 50_000,
            byteFee: 2,
            fee: Self.fee,
            options: options,
            changeAddress: change.address,
            recipientAddress: recipient.address
        )
        let estimatedFee = try BitcoinSilentPaymentTransactionSigner
            .estimatedNetworkFeeAtomic(
                outputs: [output],
                accountMarker: nil,
                requestedAtomic: 50_000,
                byteFee: 2,
                totalBudgetAtomic: nil,
                options: options,
                sourceAddress: change.address,
                recipientAddress: recipient.address,
                usesMaximumBalance: false
            )
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        let input = try #require(transaction.inputs.first)
        let witness = try #require(input.witness.first)
        #expect(signed.transactionID == transaction.transactionID)
        #expect(estimatedFee == signed.feeAtomic)
        #expect(signed.spentOutpointIDs == [output.id])
        #expect(input.script.isEmpty)
        #expect(input.witness.count == 1)
        #expect(witness.count == 64)
        #expect(transaction.outputs.contains {
            $0.value == 50_000
                && $0.script == recipient.scriptPubKey
        })

        let digest = Self.taprootDigest(
            transactionHash: transactionHash,
            outputIndex: 2,
            inputValue: 100_000,
            inputScript: script,
            sequence: input.sequence,
            outputs: transaction.outputs
        )
        let signature = try P256K.Schnorr.SchnorrSignature(
            dataRepresentation: witness
        )
        let publicKey = P256K.Schnorr.XonlyKey(
            dataRepresentation: outputPublicKey
        )
        #expect(
            publicKey.isValidSignature(
                signature,
                for: HashDigest(Array(digest))
            )
        )
    }

    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"

    private static let fee = SendResolvedNetworkFee(
        model: .utxoPerVByte,
        primaryValue: "2",
        secondaryValue: nil
    )

    private static func draft(
        sourceAddress: String,
        recipient: String,
        amount: String,
        options: SendBitcoinFamilyOptions
    ) -> SendDraft {
        SendDraft(
            request: .manualEntry(
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ),
            asset: SendAssetChoice(
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
            ),
            recipient: recipient,
            amount: amount,
            note: nil,
            bitcoinFamilyOptions: options
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

    private static func taprootDigest(
        transactionHash: String,
        outputIndex: UInt32,
        inputValue: UInt64,
        inputScript: Data,
        sequence: UInt32,
        outputs: [ParsedBitcoinTransaction.Output]
    ) -> Data {
        let prevout = (try? outpoint(
            txid: transactionHash,
            vout: outputIndex
        )) ?? Data()
        let amounts = littleEndian(inputValue)
        let scripts = Data([UInt8(inputScript.count)]) + inputScript
        let sequences = littleEndian(sequence)
        var serializedOutputs = Data()
        for output in outputs {
            serializedOutputs.append(
                littleEndian(UInt64(output.value))
            )
            serializedOutputs.append(UInt8(output.script.count))
            serializedOutputs.append(output.script)
        }
        var message = Data([0x00, 0x00])
        message.append(littleEndian(UInt32(2)))
        message.append(littleEndian(UInt32(0)))
        message.append(hash(prevout))
        message.append(hash(amounts))
        message.append(hash(scripts))
        message.append(hash(sequences))
        message.append(hash(serializedOutputs))
        message.append(0x00)
        message.append(littleEndian(UInt32(0)))
        let tagHash = hash(Data("TapSighash".utf8))
        return hash(tagHash + tagHash + message)
    }

    private static func hash(_ data: Data) -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }

    private static func littleEndian<T: FixedWidthInteger>(
        _ value: T
    ) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func outpoint(txid: String, vout: UInt32) throws -> Data {
        var result = Data(try data(txid).reversed())
        var littleEndian = vout.littleEndian
        result.append(
            withUnsafeBytes(of: &littleEndian) { Data($0) }
        )
        return result
    }

    private static func data(_ hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else {
            throw FixtureError.invalidHex
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw FixtureError.invalidHex
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private enum FixtureError: Error {
        case invalidHex
    }
}
