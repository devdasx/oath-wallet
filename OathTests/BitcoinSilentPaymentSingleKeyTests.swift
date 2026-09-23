import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct BitcoinSilentPaymentSingleKeyTests {
    private static let recipient =
        "sp1qqgste7k9hx0qftg6qmwlkqtwuy6cycyavzmzj85c6qdfhjdpdjtdgqjuex"
        + "zk6murw56suy3e0rd2cgqvycxttddwsvgxe2usfpxumr70xc9pkqwv"

    @Test
    func feeTemplateUsesTaprootOutputSize() {
        let options = SendBitcoinFamilyOptions.automatic
        let silent = sendDraft(
            sourceAddress: "bc1qsource",
            options: options
        )
        let segwit = sendDraft(
            sourceAddress: "bc1qsource",
            recipient: "bc1qrecipient",
            options: options
        )
        #expect(
            SendNetworkFeeEstimator.templateUTXOVirtualBytes(draft: silent)
                == SendNetworkFeeEstimator.templateUTXOVirtualBytes(
                    draft: segwit
                ) + 12
        )
    }

    @Test
    func bip321PreservesBIP21ExtensionRules() throws {
        let request = try SendPaymentRequestParser.parse(
            "bitcoin:?sp=\(Self.recipient)&merchant-extension=1"
        )
        #expect(request.recipient == Self.recipient)
        #expect(throws: SendPaymentRequestError.unsupportedRequiredParameter) {
            try SendPaymentRequestParser.parse(
                "litecoin:ltc1qt36tu30tgk35tyzsve6jjq3dnhu2rm8l8v5q00"
                    + "?req-sp=\(Self.recipient)"
            )
        }
    }

    @Test(arguments: [
        PrivateKeyImportFormat.rawSecp256k1,
        .wifCompressed,
        .wifUncompressed,
        .extendedLegacy,
        .extendedNestedSegwit,
        .extendedNativeSegwit,
    ], [0, 1, 7, 20])
    func signsEverySupportedSingleKeyFormat(
        format: PrivateKeyImportFormat, outputIndex: Int
    ) throws {
        let privateKey = try data(
            "1e99423a4ed27608a15a2616f7f56c0dd94c0b1bb25b1f4f4e2f3f7f8a9b0c1d"
        )
        let account = try BitcoinFamilyDerivationService().derive(
            privateKey: privateKey,
            chain: .bitcoin,
            format: format,
            derivationPath: format.accountMarker
        )
        let transactionHash = String(repeating: "a5", count: 32)
        let output = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: transactionHash,
                outputIndex: outputIndex
            ),
            valueAtomic: "100000",
            blockHeight: 800_000,
            confirmations: 10
        )
        let opReturnMessage = "exact 🙂 bytes"
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual([output]),
            replaceByFee: true,
            opReturnMessage: opReturnMessage
        )
        let draft = sendDraft(
            sourceAddress: account.address,
            options: options
        )
        let signed = try BitcoinSilentPaymentTransactionSigner
            .signSingleKey(
                draft: draft,
                privateKey: privateKey,
                format: format,
                outputs: [output],
                requestedAtomic: 50_000,
                byteFee: 2,
                fee: SendResolvedNetworkFee(
                    model: .utxoPerVByte,
                    primaryValue: "2",
                    secondaryValue: nil
                ),
                options: options,
                senderAddress: account.address,
                recipientAddress: Self.recipient
            )
        let estimatedFee = try BitcoinSilentPaymentTransactionSigner
            .estimatedNetworkFeeAtomic(
                outputs: [output],
                accountMarker: format.accountMarker,
                requestedAtomic: 50_000,
                byteFee: 2,
                totalBudgetAtomic: nil,
                options: options,
                sourceAddress: account.address,
                recipientAddress: Self.recipient,
                usesMaximumBalance: false
            )
        let expected = try BitcoinSilentPaymentCrypto.destination(
            address: BitcoinSilentPaymentAddress(Self.recipient),
            inputs: [
                try BitcoinSilentPaymentInputSecret(
                    outpoint: outpoint(
                        txid: transactionHash,
                        outputIndex: UInt32(outputIndex)
                    ),
                    privateKey: privateKey,
                    isTaproot: false
                )
            ]
        )
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        let raw = try #require(
            BitcoinRawTransaction(hex: signed.encoded.hexString)
        )
        #expect(transaction.transactionID == signed.transactionID)
        #expect(raw.transactionID == signed.transactionID)
        #expect(estimatedFee == signed.feeAtomic)
        #expect(signed.spentOutpointIDs == [output.id])
        #expect(transaction.outputs.contains {
            $0.value == 50_000 && $0.script == expected.scriptPubKey
        })
        let opReturnPayload = Data(opReturnMessage.utf8)
        let opReturnScript = Data([
            0x6a,
            UInt8(opReturnPayload.count),
        ]) + opReturnPayload
        #expect(transaction.outputs.contains {
            $0.value == 0 && $0.script == opReturnScript
        })
    }

    @Test
    func compressedWIFOwnsAllStandardScriptsWhileUncompressedIsLegacyOnly()
        throws
    {
        let privateKey = try data(
            String(repeating: "00", count: 31) + "01"
        )
        let service = BitcoinHDDerivationService()
        let compressed = try service.singleKeyAddresses(
            privateKeyData: privateKey,
            format: .wifCompressed
        )
        let uncompressed = try service.singleKeyAddresses(
            privateKeyData: privateKey,
            format: .wifUncompressed
        )

        #expect(Set(compressed.map(\.addressType))
            == Set(BitcoinHDAddressType.standardTypes))
        #expect(Set(compressed.map(\.address)).count == 4)
        #expect(compressed.allSatisfy {
            BitcoinFamilyChain.bitcoin.coin.validate(address: $0.address)
        })
        #expect(uncompressed.count == 1)
        #expect(uncompressed.first?.addressType == .bip44)
        #expect(uncompressed.first?.address
            == "1EHNa6Q4Jz2uvNExL497mE43ikXhwF6kZm")
    }

    @Test
    func bitcoinWIFImportPreservesCompressionAndPreparesEveryOwnedScript()
        throws
    {
        let privateKey = try data(
            String(repeating: "00", count: 31) + "01"
        )
        var compressedPayload = Data([0x80])
        compressedPayload.append(privateKey)
        compressedPayload.append(0x01)
        var uncompressedPayload = Data([0x80])
        uncompressedPayload.append(privateKey)
        let compressedWIF = Base58.encode(data: compressedPayload)
        let uncompressedWIF = Base58.encode(data: uncompressedPayload)
        #expect(compressedWIF.hasPrefix("K") || compressedWIF.hasPrefix("L"))
        #expect(uncompressedWIF.hasPrefix("5"))

        let compressedDraft = try PrivateKeyImportService.importKey(
            compressedWIF,
            network: .bitcoin
        )
        let uncompressedDraft = try PrivateKeyImportService.importKey(
            uncompressedWIF,
            network: .bitcoin
        )
        guard case let .privateKey(
            compressedData,
            compressedNetwork,
            compressedFormat
        ) = compressedDraft.secret,
        case let .privateKey(
            uncompressedData,
            uncompressedNetwork,
            uncompressedFormat
        ) = uncompressedDraft.secret else {
            Issue.record("Expected Bitcoin private-key import drafts")
            return
        }
        #expect(compressedData == privateKey)
        #expect(compressedNetwork == .bitcoin)
        #expect(compressedFormat == .wifCompressed)
        #expect(uncompressedData == privateKey)
        #expect(uncompressedNetwork == .bitcoin)
        #expect(uncompressedFormat == .wifUncompressed)

        let derivation = BitcoinHDDerivationService()
        let compressedAddresses = try derivation.singleKeyAddresses(
            privateKeyData: compressedData,
            format: compressedFormat
        )
        let uncompressedAddresses = try derivation.singleKeyAddresses(
            privateKeyData: uncompressedData,
            format: uncompressedFormat
        )
        #expect(compressedAddresses.count == 4)
        let nativeSegWitAddress = compressedAddresses.first {
            $0.addressType == BitcoinHDAddressType.bip84
        }?.address
        #expect(compressedDraft.address == nativeSegWitAddress)
        #expect(uncompressedAddresses.count == 1)
        #expect(uncompressedDraft.address == uncompressedAddresses[0].address)
    }

    @Test
    func compressedWIFSignsMixedBIP44BIP49BIP84AndBIP86Inputs()
        throws
    {
        let privateKey = try data(
            "1e99423a4ed27608a15a2616f7f56c0dd94c0b1bb25b1f4f4e2f3f7f8a9b0c1d"
        )
        let addresses = try BitcoinHDDerivationService()
            .singleKeyAddresses(
                privateKeyData: privateKey,
                format: .wifCompressed
            )
        let outputs = addresses.enumerated().map { index, owner in
            SendBitcoinUTXO(
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                outpoint: SendBitcoinOutpoint(
                    transactionHash: String(
                        repeating: String(format: "%02x", index + 1),
                        count: 32
                    ),
                    outputIndex: index
                ),
                valueAtomic: "100000",
                blockHeight: 800_000,
                confirmations: 10,
                owner: owner
            )
        }
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual(outputs),
            replaceByFee: true
        )
        let source = try #require(
            addresses.first { $0.addressType == .bip84 }
        )
        let change = try #require(
            addresses.first { $0.addressType == .bip86 }
        )
        let recipientKey = try data(
            String(repeating: "00", count: 31) + "02"
        )
        let recipient = try #require(
            BitcoinHDDerivationService().singleKeyAddresses(
                privateKeyData: recipientKey,
                format: .wifCompressed
            ).first { $0.addressType == .bip84 }
        )
        let draft = sendDraft(
            sourceAddress: source.address,
            recipient: recipient.address,
            options: options
        )
        let signed = try SendBitcoinSingleKeyTransactionSigner.sign(
            draft: draft,
            privateKeyData: privateKey,
            format: .wifCompressed,
            outputs: outputs,
            requestedAtomic: 200_000,
            byteFee: 2,
            fee: SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: "2",
                secondaryValue: nil
            ),
            options: options,
            senderAddress: source.address,
            changeAddress: change.address,
            recipientAddress: recipient.address
        )

        #expect(!signed.encoded.isEmpty)
        #expect(signed.transactionID.count == 64)
        #expect(signed.feeAtomic != "0")
        #expect(signed.changeAddress == change.address)
        #expect(BitcoinRawTransaction(hex: signed.encoded.hexString)?
            .transactionID == signed.transactionID)
    }

    private func sendDraft(
        sourceAddress: String,
        recipient: String = Self.recipient,
        options: SendBitcoinFamilyOptions
    ) -> SendDraft {
        SendDraft(
            request: .manualEntry(networkID: "bitcoin"),
            asset: SendAssetChoice(
                id: "bitcoin:native",
                name: "Bitcoin",
                symbol: "BTC",
                networkID: "bitcoin",
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
            amount: "0.0005",
            note: nil,
            bitcoinFamilyOptions: options
        )
    }

    private func outpoint(
        txid: String,
        outputIndex: UInt32
    ) throws -> Data {
        var result = Data(try data(txid).reversed())
        var littleEndian = outputIndex.littleEndian
        result.append(withUnsafeBytes(of: &littleEndian) { Data($0) })
        return result
    }

    private func data(_ hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else { throw FixtureError() }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw FixtureError()
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private struct FixtureError: Error {}
}
