import Foundation
import Testing
import WalletCore
@testable import Aperture

struct BitcoinLargeOPReturnSigningTests {
    @Test(arguments: BitcoinHDAddressType.allCases, [false, true])
    func signsLargeMessagesWithNormalAndMaximumAmounts(
        _ type: BitcoinHDAddressType, maximum: Bool
    ) throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [type], value: 1_000_000)
        for count in [256, 1_131, 65_535, 65_536, 99_000] {
            let message = String(repeating: "x", count: count)
            let signed = try fixture.sign(message: message, manual: true, usesMaximumBalance: maximum)
            let transaction = try ParsedBitcoinTransaction(signed.encoded)
            try verify(transaction, signed: signed, message: message, available: 1_000_000)
            #expect(transaction.outputs[0].script == fixture.recipientScript)
            #expect(transaction.outputs.count == (maximum ? 2 : 3))
            if maximum {
                #expect(signed.changeAddress == nil)
            } else {
                #expect(signed.amountAtomic == "100000")
                #expect(signed.changeAddress == fixture.change)
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func largeMaximumSupportsMixedInputsSilentRecipientsAndCustomFees(
        silentRecipient: Bool, customBudget: Bool
    ) throws {
        let fixture = try BitcoinOPReturnSigningFixture(
            types: BitcoinHDAddressType.allCases, silentRecipient: silentRecipient, value: 1_000_000
        )
        let message = String(repeating: "exact ₿\n", count: 7_000)
        let signed = try fixture.sign(message: message, budget: customBudget ? "200000" : nil)
        try fixture.verify(signed, message: message, budget: customBudget ? 200_000 : nil)
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        try verify(transaction, signed: signed, message: message, available: Int64(fixture.outputs.count) * 1_000_000)
    }

    @Test(arguments: [PrivateKeyImportFormat.wifCompressed, .wifUncompressed,
                      .extendedLegacy, .extendedNestedSegwit, .extendedNativeSegwit, .rawSecp256k1])
    func importedKeyFormatsPreserveLargeMessages(_ format: PrivateKeyImportFormat) throws {
        let key = try #require(PrivateKey(data: Data(repeating: 0x42, count: 32)))
        let source = try BitcoinFamilyDerivationService().derive(
            privateKey: key.data, chain: .bitcoin, format: format, derivationPath: format.accountMarker
        )
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let message = String(repeating: "x", count: 65_536)
        let options = SendBitcoinFamilyOptions.automatic.replacingOPReturnMessage(message)
        let output = SendBitcoinUTXO(
            networkID: "bitcoin", outpoint: .init(transactionHash: String(repeating: "12", count: 32), outputIndex: 0),
            valueAtomic: "1000000", blockHeight: 1, confirmations: 1
        )
        let signed = try BitcoinSilentPaymentTransactionSigner.signSingleKey(
            draft: fixture.draft(options: options), privateKey: key.data, format: format,
            outputs: [output], requestedAtomic: 100_000, byteFee: 2,
            fee: BitcoinOPReturnSigningFixture.fee(), options: options,
            senderAddress: source.address, recipientAddress: fixture.recipient
        )
        try verify(ParsedBitcoinTransaction(signed.encoded), signed: signed,
                   message: message, available: 1_000_000)
    }

    @Test(arguments: BitcoinHDAddressType.standardTypes)
    func compressedWIFV2PreservesLargeMessages(_ type: BitcoinHDAddressType) throws {
        let key = try #require(PrivateKey(data: Data(repeating: 0x42, count: 32)))
        let addresses = try BitcoinHDDerivationService().singleKeyAddresses(
            privateKeyData: key.data, format: .wifCompressed
        )
        let source = try #require(addresses.first { $0.addressType == .bip84 })
        let owner = try #require(addresses.first { $0.addressType == type })
        let output = BitcoinOPReturnSigningFixture.output(owner: owner, index: 0, value: 1_000_000)
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let message = String(repeating: "x", count: 65_536)
        let options = SendBitcoinFamilyOptions.automatic.replacingOPReturnMessage(message)
        let signed = try SendBitcoinSingleKeyTransactionSigner.sign(
            draft: fixture.draft(options: options), privateKeyData: key.data,
            format: .wifCompressed, outputs: [output], requestedAtomic: 100_000,
            byteFee: 2, fee: BitcoinOPReturnSigningFixture.fee(), options: options,
            senderAddress: source.address, changeAddress: source.address,
            recipientAddress: fixture.recipient
        )
        try verify(ParsedBitcoinTransaction(signed.encoded), signed: signed,
                   message: message, available: 1_000_000)
    }

    @Test
    func inputWeightReducesUsablePayloadBeforeAuthorizationOrBroadcast() throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let message = String(repeating: "x", count: 99_994)
        #expect(SendBitcoinOPReturn.acceptsEditableInput(message))
        // Script fits exactly, but the transaction's inputs/recipient cannot fit.
        #expect(throws: SendTransactionSubmissionError.self) { try fixture.sign(message: message) }
        let options = SendBitcoinFamilyOptions.automatic.replacingOPReturnMessage(message)
        #expect(throws: SendTransactionSubmissionError.self) {
            try BitcoinSilentPaymentTransactionSigner.estimatedNetworkFeeAtomic(
                outputs: fixture.outputs, accountMarker: nil, requestedAtomic: 100_000,
                byteFee: 2, totalBudgetAtomic: nil, options: options,
                sourceAddress: fixture.owners[0].address, recipientAddress: fixture.recipient,
                usesMaximumBalance: true
            )
        }
        let fits = String(repeating: "x", count: 99_800)
        let signed = try fixture.sign(message: fits)
        try SendBitcoinTransactionPolicy.validateEncoded(signed.encoded)
        try verify(ParsedBitcoinTransaction(signed.encoded), signed: signed,
                   message: fits, available: 1_000_000)
        let mixed = try BitcoinOPReturnSigningFixture(types: BitcoinHDAddressType.allCases, value: 1_000_000)
        #expect(throws: SendTransactionSubmissionError.self) { try mixed.sign(message: fits) }
    }

    @Test
    func rejectsPlainTransferBudgetForLargeMessage() throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let plain = try fixture.sign(message: "")
        #expect(throws: SendTransactionSubmissionError.feeQuoteUnavailable("custom_fee_budget_below_required")) {
            try fixture.sign(message: String(repeating: "x", count: 65_536), budget: plain.feeAtomic)
        }
    }

    @Test
    func HTTPRequestPreservesCompleteLargeSignedTransaction() async throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let signed = try fixture.sign(message: String(repeating: "x", count: 99_800))
        let rawHex = signed.encoded.hexString
        // Intercept the production HTTP client: no network or funds are used.
        let client = SendBitcoinFamilyHTTPAPIClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.host == "mempool.space")
            #expect(request.url?.path == "/api/tx")
            #expect(request.httpBody == Data(rawHex.utf8))
            #expect(rawHex.utf8.count > 199_600)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (Data(signed.transactionID.utf8), response)
        }
        let result = try await client.broadcast(
            chain: .bitcoin, rawTransactionHex: rawHex, expectedTransactionID: signed.transactionID
        )
        #expect(result.transactionID == signed.transactionID)
    }

    private func verify(_ transaction: ParsedBitcoinTransaction,
                        signed: SendBitcoinSignedTransaction, message: String,
                        available: Int64) throws {
        let nullData = transaction.outputs.filter { $0.script.first == 0x6a }
        #expect(nullData.count == 1)
        let output = try #require(nullData.first)
        #expect(output.value == 0)
        #expect(try BitcoinOPReturnScriptTests.decodePayload(output.script) == Data(message.utf8))
        #expect(output.script.count <= 100_000)
        #expect(transaction.weight <= 400_000)
        #expect(transaction.transactionID == signed.transactionID)
        let fee = try #require(Int64(signed.feeAtomic))
        #expect(fee + transaction.outputs.reduce(0) { $0 + $1.value } == available)
        #expect(fee >= Int64((transaction.weight + 3) / 4) * 2)
        try SendBitcoinTransactionPolicy.validateEncoded(signed.encoded)
    }
}
