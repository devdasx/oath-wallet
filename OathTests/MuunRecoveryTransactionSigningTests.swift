import CryptoKit
import Foundation
import P256K
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct MuunRecoveryTransactionSigningTests {
    @Test(arguments: MuunRecoveryAddressVersion.allCases)
    func customFeeFoldsDustAndSpendsAllManualInputs(version: MuunRecoveryAddressVersion) throws {
        let material = try Self.material()
        let owner = try MuunRecoveryAddressFactory.derive(material: material, version: version,
            branch: .external, addressIndex: 0)
        let recipient = try MuunRecoveryAddressFactory.derive(material: material, version: .v5,
            branch: .external, addressIndex: 30)
        let change = try MuunRecoveryAddressFactory.derive(material: material, version: .v5,
            branch: .change, addressIndex: 30)
        let outputs = (0..<2).map { index in SendBitcoinUTXO(networkID: "bitcoin",
            outpoint: .init(transactionHash: String(repeating: "cd", count: 32), outputIndex: index),
            valueAtomic: "1000000", blockHeight: 800_000, confirmations: 10, muunOwner: owner) }
        let options = SendBitcoinFamilyOptions.automatic.replacingCoinSelection(.manual(outputs))
        let budget: Int64 = 10_000
        for changeAmount: Int64 in [0, 329, 330] {
            let amount = 2_000_000 - budget - changeAmount
            let draft = SendDraft(request: .manualEntry(networkID: "bitcoin"),
                asset: Self.bitcoinAsset(sourceAddress: owner.address), recipient: recipient.address,
                amount: SendDecimalAmount.userUnits(fromAtomicUnits: String(amount), decimals: 8), note: nil,
                bitcoinFamilyOptions: options)
            let fee = SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "2", secondaryValue: nil,
                totalBudgetAtomic: String(budget))
            let signed = try SendMuunRecoveryTransactionSigner.sign(draft: draft, material: material,
                outputs: outputs, requestedAtomic: amount, byteFee: 2, fee: fee, options: options,
                changeAddress: change.address, recipientAddress: recipient.address)
            let wire = try ParsedBitcoinTransaction(signed.encoded)
            let expectedFee = budget + (changeAmount < 330 ? changeAmount : 0)
            #expect(wire.inputs.count == 2)
            #expect(wire.outputs.count == (changeAmount < 330 ? 1 : 2))
            #expect(signed.feeAtomic == String(expectedFee))
            #expect(wire.outputs.reduce(Int64(0)) { $0 + $1.value } + expectedFee == 2_000_000)
        }
    }

    @Test(arguments: MuunRecoveryAddressVersion.allCases, [20, 256, 65_536, 99_000])
    func serializesEachRecoveryVersionIndependently(
        _ version: MuunRecoveryAddressVersion, payloadBytes: Int
    ) throws {
        let material = try Self.material()
        let owner = try MuunRecoveryAddressFactory.derive(
            material: material,
            version: version,
            branch: .external,
            addressIndex: 0
        )
        let output = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: String(repeating: "cd", count: 32),
                outputIndex: version.rawValue
            ),
            valueAtomic: "1000000",
            blockHeight: 800_000,
            confirmations: 10,
            muunOwner: owner
        )
        let recipient = try MuunRecoveryAddressFactory.derive(
            material: material,
            version: .v5,
            branch: .external,
            addressIndex: 30
        )
        let change = try MuunRecoveryAddressFactory.derive(
            material: material,
            version: .v5,
            branch: .change,
            addressIndex: 30
        )
        let opReturnMessage = String(repeating: "x", count: payloadBytes)
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual([output]),
            replaceByFee: false,
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
        let signed = try SendMuunRecoveryTransactionSigner.sign(
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
        let transaction = try #require(
            try? ParsedBitcoinTransaction(signed.encoded)
        )
        #expect(transaction.inputs.count == 1)
        #expect(transaction.outputs.count == 3)
        #expect(transaction.transactionID == signed.transactionID)
        #expect(transaction.hasWitness == (version != .v2))
        let opReturnPayload = Data(opReturnMessage.utf8)
        let nullData = try #require(transaction.outputs.first { $0.script.first == 0x6a })
        #expect(nullData.value == 0)
        #expect(try BitcoinOPReturnScriptTests.decodePayload(nullData.script) == opReturnPayload)
        #expect(transaction.weight <= 400_000)
        #expect(try #require(Int64(signed.feeAtomic)) >= Int64((transaction.weight + 3) / 4) * 2)

    }

    @Test(arguments: [0, 65_536])
    func signsAndVerifiesMixedV2ThroughV5Inputs(payloadBytes: Int) throws {
        let material = try Self.material()
        let owners = try MuunRecoveryAddressFactory.deriveAll(
            material: material,
            branch: .external,
            addressIndex: 0
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
                valueAtomic: "100000",
                blockHeight: 800_000 + Int64(offset),
                confirmations: 10,
                muunOwner: owner
            )
        }
        let recipient = try MuunRecoveryAddressFactory.derive(
            material: material,
            version: .v5,
            branch: .external,
            addressIndex: 10
        )
        let change = try MuunRecoveryAddressFactory.derive(
            material: material,
            version: .v5,
            branch: .change,
            addressIndex: 10
        )
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual(outputs),
            replaceByFee: true,
            opReturnMessage: String(repeating: "m", count: payloadBytes)
        )
        let draft = SendDraft(
            request: .manualEntry(
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ),
            asset: Self.bitcoinAsset(sourceAddress: owners[3].address),
            recipient: recipient.address,
            amount: "0.003",
            note: nil,
            bitcoinFamilyOptions: options
        )
        let fee = SendResolvedNetworkFee(
            model: .utxoPerVByte,
            primaryValue: "2",
            secondaryValue: nil
        )

        let signed = try SendMuunRecoveryTransactionSigner.sign(
            draft: draft,
            material: material,
            outputs: outputs,
            requestedAtomic: payloadBytes == 0 ? 300_000 : 200_000,
            byteFee: 2,
            fee: fee,
            options: options,
            changeAddress: change.address,
            recipientAddress: recipient.address
        )
        let transaction = try #require(
            try? ParsedBitcoinTransaction(signed.encoded)
        )
        #expect(transaction.hasWitness)
        #expect(transaction.inputs.count == 4)
        #expect(transaction.outputs.count == (payloadBytes == 0 ? 2 : 3))
        #expect(transaction.transactionID == signed.transactionID)
        #expect(signed.spentOutpointIDs == Set(outputs.map(\.id)))
        #expect(transaction.inputs.allSatisfy {
            $0.sequence == 0xffff_fffd
        })

        for index in transaction.inputs.indices {
            let input = transaction.inputs[index]
            let owner = owners[index]
            let keys = try MuunRecoveryDerivation.keys(
                material: material,
                branch: owner.branch,
                contactIndex: owner.contactIndex,
                addressIndex: owner.addressIndex
            )
            let multisig = MuunRecoveryAddressFactory.multisigScript(
                userPublicKey: keys.user.publicKey,
                muunPublicKey: keys.muun.publicKey
            )
            switch owner.version {
            case .v2:
                let pushes = try #require(
                    try? Self.legacyMultisigPushes(input.script)
                )
                #expect(pushes.script == multisig)
                #expect(input.witness.isEmpty)
                let digest = Self.legacyDigest(
                    inputs: outputs,
                    multisigScript: multisig,
                    signingIndex: index,
                    sequence: input.sequence,
                    outputs: transaction.outputs
                )
                try Self.expectECDSA(
                    pushes.userSignature,
                    publicKey: keys.user.publicKey,
                    digest: digest
                )
                try Self.expectECDSA(
                    pushes.muunSignature,
                    publicKey: keys.muun.publicKey,
                    digest: digest
                )
            case .v3:
                #expect(input.witness.count == 4)
                #expect(input.witness[0].isEmpty)
                #expect(input.witness[3] == multisig)
                let redeem = Data([0x00, 0x20])
                    + Self.sha256(multisig)
                #expect(input.script == Data([0x22]) + redeem)
                try Self.expectSegwitSignatures(
                    input: input,
                    keys: keys,
                    inputs: outputs,
                    signingIndex: index,
                    outputs: transaction.outputs
                )
            case .v4:
                #expect(input.script.isEmpty)
                #expect(input.witness.count == 4)
                #expect(input.witness[0].isEmpty)
                #expect(input.witness[3] == multisig)
                try Self.expectSegwitSignatures(
                    input: input,
                    keys: keys,
                    inputs: outputs,
                    signingIndex: index,
                    outputs: transaction.outputs
                )
            case .v5:
                #expect(input.script.isEmpty)
                let signatureData = try #require(input.witness.first)
                #expect(input.witness.count == 1)
                #expect(signatureData.count == 64)
                let digest = Self.taprootDigest(
                    inputs: outputs,
                    signingIndex: index,
                    sequence: input.sequence,
                    outputs: transaction.outputs
                )
                let signature = try P256K.Schnorr.SchnorrSignature(
                    dataRepresentation: signatureData
                )
                let outputKey = P256K.Schnorr.XonlyKey(
                    dataRepresentation: Data(owner.scriptPubKey.suffix(32))
                )
                #expect(outputKey.isValidSignature(
                    signature,
                    for: HashDigest(Array(digest))
                ))
            }
        }

        let totalOutput = transaction.outputs.reduce(Int64(0)) {
            $0 + $1.value
        }
        #expect(totalOutput + (Int64(signed.feeAtomic) ?? 0) == 400_000)
        let witnessBytes = Self.witnessSerializedSize(transaction.inputs)
        let strippedSize = signed.encoded.count - witnessBytes
        let weight = strippedSize * 4 + witnessBytes
        let virtualSize = (weight + 3) / 4
        #expect((Int64(signed.feeAtomic) ?? 0) >= Int64(virtualSize * 2))
    }

    @Test
    func exactCustomFeeAndMaximumBalancePreserveAtomicInvariant() throws {
        let material = try Self.material()
        let owner = try MuunRecoveryAddressFactory.derive(
            material: material,
            version: .v5,
            branch: .external,
            addressIndex: 0
        )
        let output = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: String(repeating: "ab", count: 32),
                outputIndex: 7
            ),
            valueAtomic: "100000",
            blockHeight: 800_000,
            confirmations: 10,
            muunOwner: owner
        )
        let recipient = try MuunRecoveryAddressFactory.derive(
            material: material,
            version: .v4,
            branch: .external,
            addressIndex: 20
        )
        let change = try MuunRecoveryAddressFactory.derive(
            material: material,
            version: .v5,
            branch: .change,
            addressIndex: 20
        )
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual([output]),
            replaceByFee: false
        )
        let draft = SendDraft(
            request: .manualEntry(
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ),
            asset: Self.bitcoinAsset(sourceAddress: owner.address),
            recipient: recipient.address,
            amount: "0.00099",
            note: nil,
            bitcoinFamilyOptions: options,
            usesMaximumBalance: true
        )
        let signed = try SendMuunRecoveryTransactionSigner.sign(
            draft: draft,
            material: material,
            outputs: [output],
            requestedAtomic: 99_000,
            byteFee: 2,
            fee: SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: "2",
                secondaryValue: nil,
                totalBudgetAtomic: "1000"
            ),
            options: options,
            changeAddress: change.address,
            recipientAddress: recipient.address
        )
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        #expect(signed.amountAtomic == "99000")
        #expect(signed.feeAtomic == "1000")
        #expect(signed.changeAddress == nil)
        #expect(transaction.outputs.count == 1)
        #expect(transaction.outputs[0].value == 99_000)
    }

    private static func expectSegwitSignatures(
        input: ParsedBitcoinTransaction.Input,
        keys: MuunRecoveryDerivedKeyPair,
        inputs: [SendBitcoinUTXO],
        signingIndex: Int,
        outputs: [ParsedBitcoinTransaction.Output]
    ) throws {
        let digest = segwitDigest(
            inputs: inputs,
            multisigScript: input.witness[3],
            signingIndex: signingIndex,
            sequence: input.sequence,
            outputs: outputs
        )
        try expectECDSA(
            input.witness[1],
            publicKey: keys.user.publicKey,
            digest: digest
        )
        try expectECDSA(
            input.witness[2],
            publicKey: keys.muun.publicKey,
            digest: digest
        )
    }

    private static func expectECDSA(
        _ encoded: Data,
        publicKey: Data,
        digest: Data
    ) throws {
        #expect(encoded.last == 0x01)
        let signature = try P256K.Signing.ECDSASignature(
            derRepresentation: encoded.dropLast()
        )
        let key = try P256K.Signing.PublicKey(
            dataRepresentation: publicKey,
            format: .compressed
        )
        #expect(key.isValidSignature(
            signature,
            for: HashDigest(Array(digest))
        ))
    }

    private static func legacyMultisigPushes(
        _ script: Data
    ) throws -> (
        userSignature: Data,
        muunSignature: Data,
        script: Data
    ) {
        var reader = TestScriptReader(data: script)
        #expect(try reader.readByte() == 0x00)
        let user = try reader.readPush()
        let muun = try reader.readPush()
        let multisig = try reader.readPush()
        #expect(reader.isAtEnd)
        return (user, muun, multisig)
    }

    private static func legacyDigest(
        inputs: [SendBitcoinUTXO],
        multisigScript: Data,
        signingIndex: Int,
        sequence: UInt32,
        outputs: [ParsedBitcoinTransaction.Output]
    ) -> Data {
        var data = Data()
        data.appendTestUInt32LE(2)
        data.appendTestCompactSize(inputs.count)
        for (index, input) in inputs.enumerated() {
            data.append(serializedOutpoint(input))
            data.appendTestScript(
                index == signingIndex ? multisigScript : Data()
            )
            data.appendTestUInt32LE(sequence)
        }
        data.append(serializedOutputs(outputs))
        data.appendTestUInt32LE(0)
        data.appendTestUInt32LE(1)
        return doubleSHA256(data)
    }

    private static func segwitDigest(
        inputs: [SendBitcoinUTXO],
        multisigScript: Data,
        signingIndex: Int,
        sequence: UInt32,
        outputs: [ParsedBitcoinTransaction.Output]
    ) -> Data {
        var prevouts = Data()
        var sequences = Data()
        for input in inputs {
            prevouts.append(serializedOutpoint(input))
            sequences.appendTestUInt32LE(sequence)
        }
        var data = Data()
        data.appendTestUInt32LE(2)
        data.append(doubleSHA256(prevouts))
        data.append(doubleSHA256(sequences))
        data.append(serializedOutpoint(inputs[signingIndex]))
        data.appendTestScript(multisigScript)
        data.appendTestUInt64LE(
            UInt64(Int64(inputs[signingIndex].valueAtomic) ?? 0)
        )
        data.appendTestUInt32LE(sequence)
        data.append(doubleSHA256(serializedOutputsOnly(outputs)))
        data.appendTestUInt32LE(0)
        data.appendTestUInt32LE(1)
        return doubleSHA256(data)
    }

    private static func taprootDigest(
        inputs: [SendBitcoinUTXO],
        signingIndex: Int,
        sequence: UInt32,
        outputs: [ParsedBitcoinTransaction.Output]
    ) -> Data {
        var prevouts = Data()
        var amounts = Data()
        var scripts = Data()
        var sequences = Data()
        for input in inputs {
            prevouts.append(serializedOutpoint(input))
            amounts.appendTestUInt64LE(
                UInt64(Int64(input.valueAtomic) ?? 0)
            )
            scripts.appendTestScript(input.muunOwner?.scriptPubKey ?? Data())
            sequences.appendTestUInt32LE(sequence)
        }
        var message = Data([0x00, 0x00])
        message.appendTestUInt32LE(2)
        message.appendTestUInt32LE(0)
        message.append(sha256(prevouts))
        message.append(sha256(amounts))
        message.append(sha256(scripts))
        message.append(sha256(sequences))
        message.append(sha256(serializedOutputsOnly(outputs)))
        message.append(0x00)
        message.appendTestUInt32LE(UInt32(signingIndex))
        return Data(SHA256.taggedHash(
            tag: Data("TapSighash".utf8),
            data: message
        ))
    }

    private static func serializedOutpoint(
        _ output: SendBitcoinUTXO
    ) -> Data {
        var data = Data(
            (Data(hexString: output.outpoint.transactionHash) ?? Data())
                .reversed()
        )
        data.appendTestUInt32LE(output.outpoint.wireOutputIndex ?? 0)
        return data
    }

    private static func serializedOutputs(
        _ outputs: [ParsedBitcoinTransaction.Output]
    ) -> Data {
        var data = Data()
        data.appendTestCompactSize(outputs.count)
        data.append(serializedOutputsOnly(outputs))
        return data
    }

    private static func serializedOutputsOnly(
        _ outputs: [ParsedBitcoinTransaction.Output]
    ) -> Data {
        var data = Data()
        for output in outputs {
            data.appendTestUInt64LE(UInt64(output.value))
            data.appendTestScript(output.script)
        }
        return data
    }

    private static func witnessSerializedSize(
        _ inputs: [ParsedBitcoinTransaction.Input]
    ) -> Int {
        2 + inputs.reduce(0) { total, input in
            total + testCompactSizeLength(input.witness.count)
                + input.witness.reduce(0) {
                    $0 + testCompactSizeLength($1.count) + $1.count
                }
        }
    }

    private static func material() throws -> MuunRecoveryKeyMaterial {
        try MuunRecoveryKeyDecryptor.recover(
            firstEncryptedKey:
                "5TnX1czXD6sQEPbpjNANzkwS9XSgRdv3Kk7Z5UuaJSa9WUUwK74cebE3oN2or9jc"
                + "wAGMVtWVDgTubeYWS44uAMTrAC46dcEtpfK5adYA7QbZnJASci9STGG74Yu1LUSw"
                + "L6veJ8SJeakHPWH3wXC",
            secondEncryptedKey:
                "5TnX1vYSm7mQVFu76ftUDBcowWnq153iYkAx59TdGD2Z4EU4QzBiHTxSHKKVEXRJ"
                + "GhLy9omLa3kmT94A5E58Fe4tHMvdG5U6zN5z4YWLeroYbUak27kJDs3Gsz7a4vwx"
                + "qNYeUWTxKLi3qXagR1Q",
            recoveryCode: "LA2Q-48Z3-25JR-S5JB-5SUS-HXHJ-RCMM-8YUA"
        )
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
            balance: 0.004,
            fiatValue: 0,
            balanceAtomic: "400000",
            sourceAddress: sourceAddress
        )
    }

    private static func sha256(_ data: Data) -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }

    private static func doubleSHA256(_ data: Data) -> Data {
        sha256(sha256(data))
    }

    private static func testCompactSizeLength(_ value: Int) -> Int {
        if value < 0xfd { return 1 }
        if value <= Int(UInt16.max) { return 3 }
        if UInt64(value) <= UInt64(UInt32.max) { return 5 }
        return 9
    }
}

private enum MuunSignerTestError: Error {
    case truncated
    case invalidPush
}

private struct TestScriptReader {
    let data: Data
    private(set) var offset: Int

    init(data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    mutating func readByte() throws -> UInt8 {
        guard data.indices.contains(offset) else {
            throw MuunSignerTestError.truncated
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readPush() throws -> Data {
        let opcode = try readByte()
        let count: Int
        if opcode <= 75 {
            count = Int(opcode)
        } else if opcode == 0x4c {
            count = Int(try readByte())
        } else {
            throw MuunSignerTestError.invalidPush
        }
        guard count >= 0, offset + count <= data.endIndex else {
            throw MuunSignerTestError.truncated
        }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }
}

private extension Data {
    mutating func appendTestCompactSize(_ value: Int) {
        if value < 0xfd {
            append(UInt8(value))
        } else if value <= Int(UInt16.max) {
            append(0xfd)
            appendTestUInt16LE(UInt16(value))
        } else if UInt64(value) <= UInt64(UInt32.max) {
            append(0xfe)
            appendTestUInt32LE(UInt32(value))
        } else {
            append(0xff)
            appendTestUInt64LE(UInt64(value))
        }
    }

    mutating func appendTestScript(_ script: Data) {
        appendTestCompactSize(script.count)
        append(script)
    }

    mutating func appendTestUInt16LE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) {
            append(contentsOf: $0)
        }
    }

    mutating func appendTestUInt32LE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) {
            append(contentsOf: $0)
        }
    }

    mutating func appendTestUInt64LE(_ value: UInt64) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) {
            append(contentsOf: $0)
        }
    }
}
