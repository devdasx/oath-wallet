import Foundation
import Testing
import WalletCore
@testable import Aperture

struct SendBitcoinFamilyDustPolicyTests {
    @Test(arguments: [BitcoinFamilyChain.bitcoin, .bitcoinCash, .litecoin])
    func thresholdsFollowOutputScriptAndChain(chain: BitcoinFamilyChain) {
        let p2pkh = Data([0x76, 0xa9, 0x14]) + Data(repeating: 1, count: 20) + Data([0x88, 0xac])
        let p2sh = Data([0xa9, 0x14]) + Data(repeating: 1, count: 20) + Data([0x87])
        let scale: Int64 = chain == .litecoin ? 10 : 1
        #expect(SendBitcoinDustPolicy.recipientMinimum(chain: chain, script: p2pkh) == 546 * scale)
        #expect(SendBitcoinDustPolicy.recipientMinimum(chain: chain, script: p2sh) == 540 * scale)
        if chain != .bitcoinCash {
            #expect(SendBitcoinDustPolicy.recipientMinimum(chain: chain,
                script: Data([0, 20]) + Data(repeating: 1, count: 20)) == 294 * scale)
            #expect(SendBitcoinDustPolicy.recipientMinimum(chain: chain,
                script: Data([0x51, 32]) + Data(repeating: 1, count: 32)) == 330 * scale)
        }
        #expect(SendBitcoinDustPolicy.recipientMinimum(chain: chain, script: Data([0x6a, 1, 1])) == 0)
    }

    @Test
    func slicedWitnessScriptsUseTheirActualStartIndex() {
        let bytes = Data(repeating: 0xff, count: 80) + Data([0, 20]) + Data(repeating: 1, count: 20)
        let script = bytes.suffix(22)
        #expect(script.startIndex != 0)
        #expect(SendBitcoinDustPolicy.recipientMinimum(chain: .bitcoin, script: script) == 294)
        #expect(SendBitcoinDustPolicy.recipientMinimum(chain: .litecoin, script: script) == 2_940)
    }

    @Test(arguments: [BitcoinFamilyChain.bitcoinCash, .litecoin, .dogecoin], [0, -1, 1, 2])
    func customChangeBoundaryMatchesReviewAndSignedWire(chain: BitcoinFamilyChain, offset: Int) async throws {
        let fixture = try Fixture(chain: chain, amount: 5_000_000)
        let threshold = SendBitcoinDustPolicy.changeMinimum(chain: chain, script: fixture.script)
        let remainder = offset == 2 ? 0 : threshold + Int64(offset)
        let budget = fixture.total - fixture.input.amount - remainder
        let fee = fixture.fee(budget: budget)
        let plan = try SendBitcoinTransactionService.dustSafePlan(input: fixture.input, chain: chain, fee: fee)
        let folds = remainder > 0 && remainder < threshold
        #expect(plan.change == (folds ? 0 : remainder))
        #expect(plan.fee == budget + (folds ? remainder : 0))
        #expect(plan.amount == fixture.input.amount)
        try fixture.verifyWire(plan)
        let context = SendBitcoinPlanningInputs(walletID: "dust-test",
            account: CoinControlTestFixtures.account(address: fixture.sender, networkID: chain.networkID),
            outputs: fixture.outputs)
        let review = try await SendNetworkFeeEstimator(database: WalletDatabase.temporary())
            .bitcoinFamilyPlan(draft: fixture.draft, fee: fee, loadedInputs: context)
        #expect(review.feeAtomic == String(plan.fee))
        #expect(review.recipientAmountAtomic == String(plan.amount))
    }

    @Test(arguments: [BitcoinFamilyChain.bitcoinCash, .litecoin, .dogecoin])
    func automaticDustChangeIsFoldedWithoutReducingRecipient(chain: BitcoinFamilyChain) throws {
        var fixture = try Fixture(chain: chain, amount: 5_000_000)
        var raw = fixture.input
        raw.fixedDustThreshold = 0
        let probe: BitcoinTransactionPlan = AnySigner.plan(input: raw, coin: chain.coin)
        let threshold = SendBitcoinDustPolicy.changeMinimum(chain: chain, script: fixture.script)
        fixture.input.amount = fixture.total - probe.fee - threshold + 1
        let plan = try SendBitcoinTransactionService.dustSafePlan(input: fixture.input, chain: chain, fee: fixture.fee())
        #expect(plan.change == 0)
        #expect(plan.fee == probe.fee + threshold - 1)
        #expect(plan.amount == fixture.input.amount)
        try fixture.verifyWire(plan)
    }

    @Test
    func dogecoinHardDustAndSoftDustHaveDifferentRules() throws {
        var fixture = try Fixture(chain: .dogecoin, amount: 100_000)
        let plan = try SendBitcoinTransactionService.dustSafePlan(input: fixture.input, chain: .dogecoin, fee: fixture.fee())
        var raw = fixture.input
        raw.fixedDustThreshold = 0
        let base: BitcoinTransactionPlan = AnySigner.plan(input: raw, coin: .dogecoin)
        #expect(plan.fee == base.fee + 1_000_000)
        #expect(plan.amount == 100_000)
        try fixture.verifyWire(plan)
        fixture.input.amount = 99_999
        #expect(throws: (any Error).self) {
            try SendBitcoinTransactionService.dustSafePlan(input: fixture.input, chain: .dogecoin, fee: fixture.fee())
        }
    }

    @Test(arguments: [BitcoinFamilyChain.bitcoinCash, .litecoin, .dogecoin])
    func manualInputsAndMessageSurviveDustFolding(chain: BitcoinFamilyChain) throws {
        var fixture = try Fixture(chain: chain, amount: 5_000_000, manual: true)
        fixture.input.utxo = (0..<3).map { index in
            var utxo = fixture.input.utxo[0]
            utxo.outPoint.index = UInt32(index)
            utxo.amount = index == 2 ? 1_958 : 5_000_000
            return utxo
        }
        fixture.input.outputOpReturn = Data("Aperture".utf8)
        let total: Int64 = 10_001_958
        let budget = total - fixture.input.amount - 100
        let plan = try SendBitcoinTransactionService.dustSafePlan(input: fixture.input, chain: chain,
            fee: fixture.fee(budget: budget))
        #expect(plan.utxos.count == 3)
        #expect(plan.availableAmount == total)
        #expect(plan.change == 0)
        var signing = fixture.input
        signing.plan = plan
        let signed: BitcoinSigningOutput = AnySigner.sign(input: signing, coin: chain.coin)
        #expect(signed.error == .ok)
        let wire = try ParsedBitcoinTransaction(signed.encoded)
        #expect(wire.inputs.count == 3)
        #expect(wire.outputs.count == 2)
        #expect(wire.outputs.contains { $0.value == 0 && $0.script.first == 0x6a })
        #expect(wire.outputs.reduce(Int64(0)) { $0 + $1.value } + plan.fee == total)
    }

    @Test
    func dogecoinSelectsEnoughInputsForSmallRecipientSurcharge() throws {
        var fixture = try Fixture(chain: .dogecoin, amount: 100_000)
        fixture.input.utxo = (0..<2).map { index in
            var utxo = fixture.input.utxo[0]
            utxo.outPoint.index = UInt32(index)
            utxo.amount = 1_000_000
            return utxo
        }
        let plan = try SendBitcoinTransactionService.dustSafePlan(input: fixture.input, chain: .dogecoin, fee: fixture.fee())
        #expect(plan.utxos.count == 2)
        #expect(plan.amount == 100_000)
        #expect(plan.change == 0)
        #expect(plan.fee == 1_900_000)
        try fixture.verifyWire(plan)
    }

    @Test
    func customFeeExceptionCannotBurnOrdinaryChange() {
        #expect(SendBitcoinDustPolicy.allowsFee(1_545, budget: 1_000, change: 0, minimumChange: 546))
        #expect(!SendBitcoinDustPolicy.allowsFee(1_546, budget: 1_000, change: 0, minimumChange: 546))
        #expect(!SendBitcoinDustPolicy.allowsFee(999, budget: 1_000, change: 0, minimumChange: 546))
        #expect(!SendBitcoinDustPolicy.allowsFee(1_100, budget: 1_000, change: 546, minimumChange: 546))
    }

    private struct Fixture {
        let chain: BitcoinFamilyChain
        let total: Int64 = 10_000_000
        let sender: String
        let script: Data
        let outputs: [SendBitcoinUTXO]
        let draft: SendDraft
        var input: BitcoinSigningInput

        init(chain: BitcoinFamilyChain, amount: Int64, manual: Bool = false) throws {
            self.chain = chain
            // Public deterministic test keys with invented outpoints; never broadcast.
            let key = try #require(PrivateKey(data: Data(repeating: 1, count: 32)))
            let recipientKey = try #require(PrivateKey(data: Data(repeating: 2, count: 32)))
            sender = chain.coin.deriveAddress(privateKey: key)
            let recipient = chain.coin.deriveAddress(privateKey: recipientKey)
            script = BitcoinScript.lockScriptForAddress(address: sender, coin: chain.coin).data
            outputs = [SendBitcoinUTXO(networkID: chain.networkID,
                outpoint: .init(transactionHash: String(repeating: "ab", count: 32), outputIndex: 0),
                valueAtomic: String(total), blockHeight: 800_000, confirmations: 10)]
            let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == chain.networkID })
            let asset = try SendEntryTestFixtures.nativeChoice(for: network)
            let options = SendBitcoinFamilyOptions.automatic.replacingCoinSelection(manual ? .manual(outputs) : .automatic)
            draft = SendEntryTestFixtures.draft(asset: asset, amount: SendDecimalAmount.userUnits(fromAtomicUnits: String(amount), decimals: 8))
                .replacing(recipient: recipient, amount: SendDecimalAmount.userUnits(fromAtomicUnits: String(amount), decimals: 8), note: nil)
                .replacingBitcoinFamilyOptions(options)
            input = try SendBitcoinTransactionService.signingInput(draft: draft, accountMarker: nil,
                nestedSegwitPublicKey: nil, chain: chain, outputs: outputs, requestedAtomic: amount,
                byteFee: chain == .dogecoin ? 1_000 : 1, options: options, senderAddress: sender, recipientAddress: recipient)
            input.privateKey = [key.data]
        }

        func fee(budget: Int64? = nil) -> SendResolvedNetworkFee {
            .init(model: .utxoPerVByte, primaryValue: chain == .dogecoin ? "1000" : "1",
                  secondaryValue: nil, totalBudgetAtomic: budget.map(String.init))
        }

        func verifyWire(_ plan: BitcoinTransactionPlan) throws {
            var signing = input
            signing.plan = plan
            let signed: BitcoinSigningOutput = AnySigner.sign(input: signing, coin: chain.coin)
            #expect(signed.error == .ok)
            let wire = try ParsedBitcoinTransaction(signed.encoded)
            #expect(wire.outputs.count == (plan.change == 0 ? 1 : 2))
            #expect(wire.outputs[0].value == plan.amount)
            #expect(wire.outputs.reduce(Int64(0)) { $0 + $1.value } + plan.fee == plan.availableAmount)
            for output in wire.outputs {
                #expect(output.value >= SendBitcoinDustPolicy.recipientMinimum(chain: chain, script: output.script))
            }
        }
    }
}

struct SendBitcoinScriptDustSigningTests {
    @Test(arguments: BitcoinHDAddressType.allCases, BitcoinHDAddressType.allCases)
    func hdAndScriptAwareSignersAgreeAtChangeBoundaries(inputType: BitcoinHDAddressType, changeType: BitcoinHDAddressType) throws {
        let fixture = try CoinControlTestFixtures.make(types: [inputType])
        let change = try BitcoinHDDerivationService().deriveAddress(credential: fixture.credential,
            addressType: changeType, branch: .change, index: 0)
        let threshold = SendBitcoinDustPolicy.changeMinimum(chain: .bitcoin, script: change.scriptPubKey)
        let options = SendBitcoinFamilyOptions.automatic.replacingCoinSelection(.manual(fixture.inputs.outputs))
        let fee = SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "2", secondaryValue: nil, totalBudgetAtomic: "2000")
        for remainder in [Int64(0), threshold - 1, threshold, threshold + 1] {
            let amount = 50_000 - 2_000 - remainder
            let draft = fixture.draft(amount: SendDecimalAmount.userUnits(fromAtomicUnits: String(amount), decimals: 8))
                .replacingBitcoinFamilyOptions(options)
            let prepared = try SendBitcoinHDTransactionPlanner.prepare(draft: draft, outputs: fixture.inputs.outputs,
                requestedAtomic: amount, byteFee: 2, fee: fee, options: options,
                changeAddress: change.address, recipientAddress: fixture.recipient.address)
            let hd = try SendBitcoinHDTransactionSigner.sign(draft: draft,
                material: SendResolvedSigningMaterial(walletID: "test-wallet", account: fixture.inputs.account,
                    privateKey: Data(), bitcoinHDRecoveryCredential: fixture.credential),
                outputs: fixture.inputs.outputs, requestedAtomic: amount, byteFee: 2, fee: fee,
                options: options, changeAddress: change.address, recipientAddress: fixture.recipient.address)
            let custom = try BitcoinSilentPaymentTransactionSigner.sign(draft: draft, credential: fixture.credential,
                outputs: fixture.inputs.outputs, silentPaymentPrivateKeys: [:], requestedAtomic: amount,
                byteFee: 2, fee: fee, options: options, changeAddress: change.address, recipientAddress: fixture.recipient.address)
            let expectedFee = 2_000 + (remainder < threshold ? remainder : 0)
            #expect(prepared.feeAtomic == String(expectedFee))
            for signed in [hd, custom] {
                let wire = try ParsedBitcoinTransaction(signed.encoded)
                #expect(signed.feeAtomic == prepared.feeAtomic)
                #expect(wire.outputs.count == (remainder < threshold ? 1 : 2))
                #expect(wire.outputs[0].value == amount)
                #expect(wire.outputs.reduce(Int64(0)) { $0 + $1.value } + expectedFee == 50_000)
                #expect(expectedFee >= Int64((wire.weight + 3) / 4) * 2)
            }
        }
    }

    @Test(arguments: [false, true])
    func hdAutomaticAndSilentPaymentNeverEmitDustChange(silentRecipient: Bool) throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], silentRecipient: silentRecipient, value: 100_500)
        let signed = try fixture.sign(message: "", usesMaximumBalance: false)
        let wire = try ParsedBitcoinTransaction(signed.encoded)
        let threshold = SendBitcoinDustPolicy.changeMinimum(chain: .bitcoin,
            script: BitcoinScript.lockScriptForAddress(address: fixture.change, coin: .bitcoin).data)
        #expect(wire.outputs.allSatisfy { $0.value >= SendBitcoinDustPolicy.recipientMinimum(chain: .bitcoin, script: $0.script) })
        #expect(wire.outputs.count == 1 || wire.outputs.last!.value >= threshold)
        let total = wire.outputs.reduce(Int64(0)) { $0 + $1.value }
        let fee = try #require(Int64(signed.feeAtomic))
        #expect(total + fee == 100_500)
    }
}
