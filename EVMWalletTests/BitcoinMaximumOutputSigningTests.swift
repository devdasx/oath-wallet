import Foundation
import Testing
import WalletCore
@testable import Aperture

struct BitcoinMaximumOutputSigningTests {
    @Test(arguments: BitcoinHDAddressType.allCases, BitcoinHDAddressType.allCases)
    func reviewBudgetCoversSelectedChangeAddressType(
        inputType: BitcoinHDAddressType, changeType: BitcoinHDAddressType
    ) throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [inputType], value: 1_000_000)
        let change = try BitcoinHDDerivationService().deriveAddress(
            credential: fixture.credential, addressType: changeType, branch: .change, index: 0
        ).address
        for message in ["", String(repeating: "x", count: 1_131)] {
            let options = SendBitcoinFamilyOptions.automatic.replacingOPReturnMessage(message)
            let budget = try BitcoinSilentPaymentTransactionSigner.estimatedNetworkFeeAtomic(
                outputs: fixture.outputs, accountMarker: nil, requestedAtomic: 100_000,
                byteFee: 2, totalBudgetAtomic: nil, options: options,
                sourceAddress: fixture.owners[0].address, recipientAddress: fixture.recipient,
                usesMaximumBalance: false,
                changeOutputScriptSize: SendBitcoinTransactionPolicy.changeOutputScriptSize(for: changeType)
            )
            let automatic = try fixture.sign(message: message,
                usesMaximumBalance: false, changeAddress: change)
            #expect(try #require(Int64(budget)) >= #require(Int64(automatic.feeAtomic)))
            let signed = try fixture.sign(message: message, budget: budget,
                usesMaximumBalance: false, changeAddress: change)
            #expect(signed.feeAtomic == budget)
            let transaction = try SendBitcoinNestedSegwitTransaction.finalize(
                encoded: signed.encoded, nestedPublicKeysByOutpointID: [:]
            )
            #expect(try #require(Int64(budget)) >= transaction.virtualSize * 2)
            #expect(signed.changeAddress == change)
        }
    }

    @Test
    func oldAccountAddressEstimateUnderfundsTaprootChange() throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let change = try BitcoinHDDerivationService().deriveAddress(
            credential: fixture.credential, addressType: .bip86, branch: .change, index: 0
        ).address
        let oldBudget = try BitcoinSilentPaymentTransactionSigner.estimatedNetworkFeeAtomic(
            outputs: fixture.outputs, accountMarker: nil, requestedAtomic: 100_000,
            byteFee: 2, totalBudgetAtomic: nil, options: .automatic,
            sourceAddress: fixture.owners[0].address, recipientAddress: fixture.recipient,
            usesMaximumBalance: false
        )
        #expect(throws: SendTransactionSubmissionError.feeQuoteUnavailable("custom_fee_budget_below_required")) {
            try fixture.sign(message: "", budget: oldBudget, usesMaximumBalance: false, changeAddress: change)
        }
    }

    @Test(arguments: BitcoinHDAddressType.allCases, [false, true])
    func maximumPreservesOPReturnAndFee(
        _ type: BitcoinHDAddressType,
        customBudget: Bool
    ) throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [type])
        for message in ["a", String(repeating: "a", count: 75),
                        String(repeating: "a", count: 76),
                        String(repeating: "a", count: 80), "Aperture ₿ ✅"] {
            for manual in [false, true] {
                let signed = try fixture.sign(
                    message: message, manual: manual,
                    budget: customBudget ? "2000" : nil
                )
                try fixture.verify(signed, message: message,
                                   budget: customBudget ? 2000 : nil)
            }
        }
    }

    @Test(arguments: BitcoinHDAddressType.allCases, [false, true])
    func maximumSilentPaymentKeepsExplicitRecipient(
        _ type: BitcoinHDAddressType,
        customBudget: Bool
    ) throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [type], silentRecipient: true)
        for message in ["", "Aperture ₿ ✅"] {
            let signed = try fixture.sign(
                message: message, budget: customBudget ? "2000" : nil
            )
            try fixture.verify(signed, message: message,
                               budget: customBudget ? 2000 : nil)
        }
    }

    @Test(arguments: [false, true])
    func maximumSpendsMixedInputTypes(silentRecipient: Bool) throws {
        let fixture = try BitcoinOPReturnSigningFixture(
            types: BitcoinHDAddressType.allCases,
            silentRecipient: silentRecipient
        )
        let signed = try fixture.sign(message: "Mixed inputs", manual: true)
        try fixture.verify(signed, message: "Mixed inputs")
    }

    @Test(arguments: BitcoinHDAddressType.standardTypes)
    func compressedWIFMaximumPreservesOPReturn(_ type: BitcoinHDAddressType) throws {
        let key = try #require(PrivateKey(data: Data(repeating: 0x42, count: 32)))
        let addresses = try BitcoinHDDerivationService().singleKeyAddresses(
            privateKeyData: key.data, format: .wifCompressed
        )
        let source = try #require(addresses.first { $0.addressType == .bip84 })
        let owner = try #require(addresses.first { $0.addressType == type })
        let output = BitcoinOPReturnSigningFixture.output(owner: owner, index: 0)
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84])
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual([output]), replaceByFee: true,
            opReturnMessage: "Imported key"
        )
        let signed = try SendBitcoinSingleKeyTransactionSigner.sign(
            draft: fixture.draft(options: options), privateKeyData: key.data,
            format: .wifCompressed, outputs: [output], requestedAtomic: 100_000,
            byteFee: 2, fee: BitcoinOPReturnSigningFixture.fee(), options: options,
            senderAddress: source.address, changeAddress: source.address,
            recipientAddress: fixture.recipient
        )
        try fixture.verify(signed, message: "Imported key")
    }

    @Test
    func rejectsFeeBudgetBelowCompleteOutputSize() throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84])
        let noMessage = try fixture.sign(message: "")
        // Enough for a plain Max transfer, but not its additional 80-byte output.
        #expect(throws: SendTransactionSubmissionError.feeQuoteUnavailable(
            "custom_fee_budget_below_required"
        )) {
            try fixture.sign(message: String(repeating: "a", count: 80),
                             budget: noMessage.feeAtomic)
        }
    }

    @Test
    func rejectsMaximumBelowDustAfterOPReturnFee() throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 690)
        // Plain P2WPKH Max fits; OP_RETURN leaves 286 sat, below its 294-sat threshold.
        _ = try fixture.sign(message: "")
        #expect(throws: SendTransactionSubmissionError.insufficientAssetBalance) {
            try fixture.sign(message: String(repeating: "a", count: 80))
        }
    }

}
