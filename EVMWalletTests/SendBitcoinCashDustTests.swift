import Foundation
import Testing
import WalletCore
@testable import Aperture

struct SendBitcoinCashDustTests {
    @Test
    func realWalletCoreLegacyPlanCanCreateDustButProductionPlanDoesNot() throws {
        let input = try fixtureInput(amount: 999_400)
        var legacy = input
        legacy.dustPolicy = nil
        let old: BitcoinTransactionPlan = AnySigner.plan(input: legacy, coin: .bitcoinCash)
        #expect(old.error == .ok)
        #expect(old.change > 0 && old.change < 546)

        let fixed: BitcoinTransactionPlan = AnySigner.plan(input: input, coin: .bitcoinCash)
        #expect(input.fixedDustThreshold == 546)
        #expect(fixed.error == .ok)
        #expect(fixed.change == 0)
        #expect(fixed.amount == 999_400)
        #expect(fixed.fee == 600)
        #expect(fixed.amount + fixed.change + fixed.fee == fixed.availableAmount)
    }

    @Test(arguments: [1, 148, 545])
    func tinyRecipientIsRejectedBeforeBroadcast(amount: Int) throws {
        let plan: BitcoinTransactionPlan = AnySigner.plan(input: try fixtureInput(amount: Int64(amount)), coin: .bitcoinCash)
        #expect(plan.error != .ok)
    }

    @Test
    func customFeeFoldsDustChangeIntoReviewedTotal() throws {
        let input = try fixtureInput(amount: 998_000)
        let plan: BitcoinTransactionPlan = AnySigner.plan(input: input, coin: .bitcoinCash)
        #expect(plan.change >= 546)
        let target = plan.fee + plan.change - 400
        let fee = SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "1", secondaryValue: nil,
                                        totalBudgetAtomic: String(target))
        let adjusted = try SendBitcoinTransactionService.applyingCustomFeeBudget(fee, to: plan,
            usesMaximumBalance: false, minimumOutput: input.fixedDustThreshold)
        #expect(adjusted.change == 0)
        #expect(adjusted.fee == target + 400)
        #expect(adjusted.amount == plan.amount)
        #expect(adjusted.amount + adjusted.fee == adjusted.availableAmount)
    }

    @Test
    func exactNoChangeAndThresholdChangeRemainSpendable() throws {
        let input = try fixtureInput(amount: 998_000)
        let plan: BitcoinTransactionPlan = AnySigner.plan(input: input, coin: .bitcoinCash)
        for change: Int64 in [0, 546] {
            let target = plan.fee + plan.change - change
            let fee = SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "1", secondaryValue: nil,
                                            totalBudgetAtomic: String(target))
            let adjusted = try SendBitcoinTransactionService.applyingCustomFeeBudget(fee, to: plan,
                usesMaximumBalance: false, minimumOutput: input.fixedDustThreshold)
            #expect(adjusted.change == change)
            #expect(adjusted.amount + adjusted.fee + adjusted.change == adjusted.availableAmount)
        }
    }

    @Test
    func maximumCustomFeeCannotLeaveDustRecipient() throws {
        let input = try fixtureInput(amount: 1_000_000, maximum: true)
        let plan: BitcoinTransactionPlan = AnySigner.plan(input: input, coin: .bitcoinCash)
        let fee = SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "1", secondaryValue: nil,
                                        totalBudgetAtomic: "999600")
        #expect(throws: SendTransactionSubmissionError.feeQuoteUnavailable("custom_fee_would_create_dust_amount")) {
            try SendBitcoinTransactionService.applyingCustomFeeBudget(fee, to: plan,
                usesMaximumBalance: true, minimumOutput: input.fixedDustThreshold)
        }
    }

    @Test
    func reviewAndSignedWireOutputsAgreeAfterDustIsRemoved() async throws {
        let asset = try SendRecipientHistoryTestFixtures.asset(networkID: "bitcoin_cash")
        let draft = SendEntryTestFixtures.draft(asset: asset, amount: "0.009994")
        let account = CoinControlTestFixtures.account(address: draft.recipient, networkID: "bitcoin_cash")
        let input = try fixtureInput(amount: 999_400)
        let plan: BitcoinTransactionPlan = AnySigner.plan(input: input, coin: .bitcoinCash)
        let context = SendBitcoinPlanningInputs(walletID: "test-wallet", account: account, outputs: [utxo])
        let estimator = SendNetworkFeeEstimator(database: try WalletDatabase.temporary())
        let review = try await estimator.bitcoinFamilyPlan(draft: draft,
            fee: .init(model: .utxoPerVByte, primaryValue: "1", secondaryValue: nil), loadedInputs: context)
        #expect(review.feeAtomic == String(plan.fee))
        #expect(review.recipientAmountAtomic == String(plan.amount))
        // Public deterministic test key; never used with funded accounts.
        let key = try #require(PrivateKey(data: Data(repeating: 1, count: 32)))
        let address = CoinType.bitcoinCash.deriveAddress(privateKey: key)
        var signing = input
        signing.changeAddress = address
        signing.utxo[0].script = BitcoinScript.lockScriptForAddress(address: address, coin: .bitcoinCash).data
        signing.privateKey = [key.data]
        let signingPlan: BitcoinTransactionPlan = AnySigner.plan(input: signing, coin: .bitcoinCash)
        #expect(signingPlan.fee == plan.fee)
        #expect(signingPlan.amount == plan.amount)
        signing.plan = signingPlan
        let signed: BitcoinSigningOutput = AnySigner.sign(input: signing, coin: .bitcoinCash)
        #expect(signed.error == .ok)
        let wire = try ParsedBitcoinTransaction(signed.encoded)
        #expect(wire.outputs.count == 1)
    }

    private var utxo: SendBitcoinUTXO {
        .init(networkID: "bitcoin_cash", outpoint: .init(transactionHash: String(repeating: "ab", count: 32),
            outputIndex: 0), valueAtomic: "1000000", blockHeight: 800_000, confirmations: 10)
    }

    private func fixtureInput(amount: Int64, maximum: Bool = false) throws -> BitcoinSigningInput {
        let asset = try SendRecipientHistoryTestFixtures.asset(networkID: "bitcoin_cash")
        let draft = SendEntryTestFixtures.draft(asset: asset, amount: "0.01").replacingMaximumBalance(maximum)
        return try SendBitcoinTransactionService.signingInput(draft: draft, accountMarker: nil,
            nestedSegwitPublicKey: nil, chain: .bitcoinCash, outputs: [utxo], requestedAtomic: amount,
            byteFee: 1, options: .automatic, senderAddress: draft.recipient, recipientAddress: draft.recipient)
    }
}
