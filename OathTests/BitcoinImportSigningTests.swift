import Foundation
import P256K
import Testing
import WalletCore
@testable import Aperture

struct BitcoinImportSigningTests {
    struct Scenario: Sendable, CustomTestStringConvertible {
        let source: String
        let rate: Int64
        var testDescription: String { "\(source), \(rate) sat/vB" }
        static let all = ["descriptor", "base64", "electrum", "descriptor-clear", "descriptor-encrypted", "legacy-clear", "legacy-encrypted"].flatMap { source in
            [Int64(2), 5].map { Scenario(source: source, rate: $0) }
        }
    }

    @Test(arguments: [false, true], Scenario.all)
    func verifiesEverySignatureInMixedKeyTransaction(maximum: Bool, scenario: Scenario) async throws {
        let rate = scenario.rate
        // Public fixture keys, never funded. Include an uncompressed legacy key.
        var sources: [BitcoinImportedWalletMaterial.Source] = []
        for (number, policy) in ["pkh", "wpkh", "sh(wpkh", "tr", "pkh", "rawtr"].enumerated() {
            let key = Data(repeating: 0, count: 31) + Data([UInt8(number + 1)])
            let wif = try BitcoinImportKeyEncoding.encode(.init(key: key, compressed: number != 4))
            let descriptor = "\(policy)(\(wif))" + (number == 2 ? ")" : "")
            sources.append(try .init(descriptor: BitcoinPrivateDescriptor(descriptor)))
        }
        if scenario.source == "electrum" {
            let names = ["custom-5-standard-clear.wallet", "custom-5-p2wpkh-clear.wallet",
                         "custom-5-p2wpkh-p2sh-clear.wallet", "electrum-segwit-clear.wallet", "electrum-old-clear.wallet"]
            sources = []
            for name in names {
                let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ElectrumImport/" + name)
                let imported = try await BitcoinImportFileParser.shared.parse(Data(contentsOf: url))
                sources.append(imported.sources[0])
            }
        }
        if scenario.source == "base64" {
            let vector = try BitcoinRawTaprootImportTests.vector(2)
            let key = try BitcoinPrivateDescriptor(vector.descriptor).key
            let imported = try await BitcoinImportFileParser.shared.parse(Data(key.base64EncodedString().utf8))
            sources = imported.sources
            #expect(sources.count == 5 && sources.last?.descriptor.script == .rawtr)
        }
        if scenario.source != "descriptor", scenario.source != "electrum", scenario.source != "base64" {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/BitcoinImport")
            let fixtures = try JSONDecoder().decode([BitcoinImportBackupTests.Fixture].self,
                from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
            let fixture = try #require(fixtures.first { $0.name == scenario.source })
            let imported = try await BitcoinImportFileParser.shared.parse(
                Data(contentsOf: directory.appendingPathComponent(scenario.source + ".dat")), password: fixture.password)
            sources = Array(imported.sources.prefix(5))
        }
        let material = try BitcoinImportedWalletMaterial(sources: sources).validated()
        let owners = try sources.enumerated().map { try $0.element.descriptor.address(index: $0.element.rangeStart, sourceID: String($0.offset)) }
        let changeAddress = try #require(owners.last).address
        let outputs = owners.enumerated().map { BitcoinOPReturnSigningFixture.output(owner: $0.element, index: $0.offset) }
        let recipient = try BitcoinOPReturnSigningFixture(types: [.bip84])
        let options = SendBitcoinFamilyOptions(coinSelection: .manual(outputs), replaceByFee: true, opReturnMessage: "Backup import")
        let template = recipient.draft(options: options, usesMaximumBalance: maximum)
        let draft = SendDraft(request: template.request, asset: template.asset, recipient: template.recipient,
            amount: "0.0005", note: nil, bitcoinFamilyOptions: options, usesMaximumBalance: maximum)
        let fee = SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: String(rate), secondaryValue: nil)
        let signed = try BitcoinSilentPaymentTransactionSigner.signImportedWallet(draft: draft, material: material,
            outputs: outputs, requestedAtomic: 50_000, byteFee: rate, fee: fee, options: options,
            changeAddress: changeAddress, recipientAddress: recipient.recipient)
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        #expect(transaction.inputs.count == outputs.count)
        #expect(transaction.transactionID == signed.transactionID)
        #expect(transaction.outputs.reduce(Int64(0)) { $0 + $1.value } + (Int64(signed.feeAtomic) ?? 0) == Int64(outputs.count) * 100_000)
        #expect(Int64(signed.feeAtomic)! >= Int64((transaction.weight + 3) / 4) * rate)
        let estimate = try BitcoinSilentPaymentTransactionSigner.estimatedNetworkFeeAtomic(outputs: outputs,
            accountMarker: BitcoinImportedWalletMaterial.accountMarker, requestedAtomic: 50_000, byteFee: rate,
            totalBudgetAtomic: nil, options: options, sourceAddress: changeAddress,
            recipientAddress: recipient.recipient, usesMaximumBalance: maximum)
        #expect(estimate == signed.feeAtomic)
        // Rebuild each consensus digest independently from the serialized outputs
        // and the known previous outputs; verify against the address's public key.
        for (index, input) in transaction.inputs.enumerated() {
            let previous = try #require(outputs.first { $0.outpoint.outputIndex == Int(input.previousOutputIndex) })
            let owner = try #require(previous.owner)
            let ordered = try transaction.inputs.map { entry in
                try #require(outputs.first { $0.outpoint.outputIndex == Int(entry.previousOutputIndex) })
            }
            if owner.addressType == .bip86 {
                #expect(input.script.isEmpty && input.witness.count == 1)
                let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: #require(input.witness.first))
                let publicKey = P256K.Schnorr.XonlyKey(dataRepresentation: Data(owner.scriptPubKey.suffix(32)))
                let digest = Self.taprootDigest(inputs: ordered, signingIndex: index, sequence: input.sequence, outputs: transaction.outputs)
                #expect(publicKey.isValidSignature(signature, for: HashDigest(Array(digest))))
            } else {
                let signature: Data
                let digest: Data
                if owner.addressType == .bip44 {
                    let length = Int(try #require(input.script.first))
                    signature = Data(input.script.dropFirst().prefix(length))
                    #expect(input.script.suffix(owner.publicKey.count) == owner.publicKey)
                    digest = Self.legacyDigest(inputs: ordered, multisigScript: owner.scriptPubKey,
                        signingIndex: index, sequence: input.sequence, outputs: transaction.outputs)
                } else {
                    signature = try #require(input.witness.first)
                    #expect(input.witness.count == 2 && input.witness.last == owner.publicKey)
                    let script = Data([0x76, 0xa9, 0x14]) + Hash.sha256RIPEMD(data: owner.publicKey) + Data([0x88, 0xac])
                    digest = Self.segwitDigest(inputs: ordered, multisigScript: script,
                        signingIndex: index, sequence: input.sequence, outputs: transaction.outputs)
                }
                #expect(signature.last == 1)
                let parsed = try P256K.Signing.ECDSASignature(derRepresentation: signature.dropLast())
                let key = try P256K.Signing.PublicKey(dataRepresentation: owner.publicKey,
                    format: owner.publicKey.count == 65 ? .uncompressed : .compressed)
                #expect(key.isValidSignature(parsed, for: HashDigest(Array(digest))))
            }
        }
        let foreignKey = try BitcoinImportKeyEncoding.encode(.init(key: Data(repeating: 0, count: 31) + Data([99]), compressed: true))
        let foreign = try BitcoinImportedWalletMaterial(sources: [.init(descriptor: BitcoinPrivateDescriptor("wpkh(\(foreignKey))"))]).validated()
        #expect(throws: (any Error).self) {
            try BitcoinSilentPaymentTransactionSigner.signImportedWallet(draft: draft, material: foreign,
                outputs: outputs, requestedAtomic: 50_000, byteFee: rate, fee: fee, options: options,
                changeAddress: changeAddress, recipientAddress: recipient.recipient)
        }
    }
    private static func legacyDigest(
        inputs: [SendBitcoinUTXO],
        multisigScript: Data,
        signingIndex: Int,
        sequence: UInt32,
        outputs: [ParsedBitcoinTransaction.Output]
    ) -> Data {
        var data = Data()
        data.appendImportTestUInt32LE(2)
        data.appendImportTestCompactSize(inputs.count)
        for (index, input) in inputs.enumerated() {
            data.append(serializedOutpoint(input))
            data.appendImportTestScript(
                index == signingIndex ? multisigScript : Data()
            )
            data.appendImportTestUInt32LE(sequence)
        }
        data.append(serializedOutputs(outputs))
        data.appendImportTestUInt32LE(0)
        data.appendImportTestUInt32LE(1)
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
            sequences.appendImportTestUInt32LE(sequence)
        }
        var data = Data()
        data.appendImportTestUInt32LE(2)
        data.append(doubleSHA256(prevouts))
        data.append(doubleSHA256(sequences))
        data.append(serializedOutpoint(inputs[signingIndex]))
        data.appendImportTestScript(multisigScript)
        data.appendImportTestUInt64LE(
            UInt64(Int64(inputs[signingIndex].valueAtomic) ?? 0)
        )
        data.appendImportTestUInt32LE(sequence)
        data.append(doubleSHA256(serializedOutputsOnly(outputs)))
        data.appendImportTestUInt32LE(0)
        data.appendImportTestUInt32LE(1)
        return doubleSHA256(data)
    }

    static func taprootDigest(
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
            amounts.appendImportTestUInt64LE(
                UInt64(Int64(input.valueAtomic) ?? 0)
            )
            scripts.appendImportTestScript(input.owner?.scriptPubKey ?? Data())
            sequences.appendImportTestUInt32LE(sequence)
        }
        var message = Data([0x00, 0x00])
        message.appendImportTestUInt32LE(2)
        message.appendImportTestUInt32LE(0)
        message.append(sha256(prevouts))
        message.append(sha256(amounts))
        message.append(sha256(scripts))
        message.append(sha256(sequences))
        message.append(sha256(serializedOutputsOnly(outputs)))
        message.append(0x00)
        message.appendImportTestUInt32LE(UInt32(signingIndex))
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
        data.appendImportTestUInt32LE(output.outpoint.wireOutputIndex ?? 0)
        return data
    }

    private static func serializedOutputs(
        _ outputs: [ParsedBitcoinTransaction.Output]
    ) -> Data {
        var data = Data()
        data.appendImportTestCompactSize(outputs.count)
        data.append(serializedOutputsOnly(outputs))
        return data
    }

    private static func serializedOutputsOnly(
        _ outputs: [ParsedBitcoinTransaction.Output]
    ) -> Data {
        var data = Data()
        for output in outputs {
            data.appendImportTestUInt64LE(UInt64(output.value))
            data.appendImportTestScript(output.script)
        }
        return data
    }

    private static func sha256(_ data: Data) -> Data { Hash.sha256(data: data) }
    private static func doubleSHA256(_ data: Data) -> Data { sha256(sha256(data)) }
}

private extension Data {
    mutating func appendImportTestUInt32LE(_ value: UInt32) {
        var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
    mutating func appendImportTestUInt64LE(_ value: UInt64) {
        var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
    mutating func appendImportTestCompactSize(_ value: Int) {
        if value < 253 { append(UInt8(value)) }
        else { append(253); append(UInt8(value & 255)); append(UInt8((value >> 8) & 255)) }
    }
    mutating func appendImportTestScript(_ value: Data) { appendImportTestCompactSize(value.count); append(value) }
}
