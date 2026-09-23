import Foundation
import Testing
import WalletCore
@testable import Aperture

struct SendBitcoinSelectionPlanTests {
    @Test(arguments: BitcoinHDAddressType.allCases, [false, true])
    func reviewDeductsFeesFromFullNativeAmounts(type: BitcoinHDAddressType, maximum: Bool) async throws {
        let fixture = try CoinControlTestFixtures.make(types: [type])
        let database = try WalletDatabase.temporary()
        let estimator = SendNetworkFeeEstimator(database: database)
        let draft = fixture.draft(amount: "0.00049999", maximum: maximum, manual: true)
        let fee = SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "5", secondaryValue: nil)
        let estimate = try await estimator.nativeBitcoinEstimate(draft: draft, fee: fee, loadedInputs: fixture.inputs)
        let net = try #require(estimate.nativeTransferAmountAtomic)
        #expect(SendAtomicAmount.add(net, estimate.atomicAmount) == "50000")
        #expect(SendAtomicAmount.compare(net, "49999") == .orderedAscending)
        let reviewed = estimate.applyingNativeAmount(to: draft)
        #expect(reviewed.usesMaximumBalance)
        #expect(reviewed.bitcoinFamilyOptions.coinSelection.selectedUTXOs.map(\.id) == fixture.inputs.outputs.map(\.id))
        let plan = try await estimator.bitcoinFamilyPlan(draft: reviewed, fee: estimate.applyingNativeFee(to: fee), loadedInputs: fixture.inputs)
        #expect(plan.feeAtomic == estimate.atomicAmount)
    }

    @Test(arguments: [BitcoinFamilyChain.bitcoinCash, .litecoin, .dogecoin], [false, true])
    func nativeFamilyFullAmountPaysItsOwnFee(chain: BitcoinFamilyChain, maximum: Bool) async throws {
        let database = try WalletDatabase.temporary()
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == chain.networkID })
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let draft = SendEntryTestFixtures.draft(asset: asset, amount: "10").replacingMaximumBalance(maximum)
        let output = SendBitcoinUTXO(networkID: chain.networkID, outpoint: SendBitcoinOutpoint(
            transactionHash: String(repeating: "ab", count: 32), outputIndex: 0),
            valueAtomic: "1000000000", blockHeight: 800000, confirmations: 10)
        let context = SendBitcoinPlanningInputs(walletID: "test-wallet",
            account: CoinControlTestFixtures.account(address: draft.recipient, networkID: chain.networkID),
            outputs: [output])
        let fee = try SendResolvedNetworkFee.resolve(policy: .preset(.standard),
            quote: SendNetworkFeeAPIClient.defaultQuote(for: chain.networkID))
        let result = try await SendNetworkFeeEstimator(database: database).nativeBitcoinEstimate(
            draft: draft, fee: fee, loadedInputs: context)
        #expect(SendAtomicAmount.add(try #require(result.nativeTransferAmountAtomic), result.atomicAmount) == "1000000000")
    }

    @Test(arguments: BitcoinHDAddressType.allCases, [false, true])
    func publicPlanMatchesSignedInputs(type: BitcoinHDAddressType, maximum: Bool) throws {
        let fixture = try CoinControlTestFixtures.make(types: [type, .bip84, .bip86])
        let draft = fixture.draft(amount: maximum ? "0.0012" : "0.00065", maximum: maximum)
        let fee = SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "5", secondaryValue: nil)
        let requested: Int64 = maximum ? 120_000 : 65_000
        let plan = try SendBitcoinHDTransactionPlanner.prepare(
            draft: draft, outputs: fixture.inputs.outputs, requestedAtomic: requested,
            byteFee: 5, fee: fee, options: .automatic,
            changeAddress: fixture.change.address, recipientAddress: fixture.recipient.address
        )
        let signed = try SendBitcoinHDTransactionSigner.sign(
            draft: draft,
            material: SendResolvedSigningMaterial(walletID: "test-wallet", account: fixture.inputs.account,
                privateKey: Data(), bitcoinHDRecoveryCredential: fixture.credential),
            outputs: fixture.inputs.outputs, requestedAtomic: requested, byteFee: 5,
            fee: fee, options: .automatic, changeAddress: fixture.change.address,
            recipientAddress: fixture.recipient.address
        )
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        #expect(Set(transaction.inputs.map { Int($0.previousOutputIndex) })
            == Set(plan.selection.outputs.map(\.outpoint.outputIndex)))
        #expect(signed.feeAtomic == plan.selection.feeAtomic)
        #expect(plan.selection.outputs.count == (maximum ? 3 : 2))
        #expect(draft.bitcoinFamilyOptions.coinSelection == .automatic)
    }

    @Test
    func selectionIncludesExtraInputForFeeAndExactCustomBudget() throws {
        let fixture = try CoinControlTestFixtures.make(types: [.bip49, .bip84, .bip86])
        let draft = fixture.draft(amount: "0.000499")
        let fee = SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "5",
            secondaryValue: nil, totalBudgetAtomic: "5000")
        let plan = try SendBitcoinHDTransactionPlanner.prepare(
            draft: draft, outputs: fixture.inputs.outputs, requestedAtomic: 49_900,
            byteFee: 5, fee: fee, options: .automatic,
            changeAddress: fixture.change.address, recipientAddress: fixture.recipient.address
        ).selection
        #expect(plan.outputs.count == 2)
        #expect(plan.feeAtomic == "5000")
    }

    @Test
    func insufficientFundsDoNotProduceASelection() throws {
        let fixture = try CoinControlTestFixtures.make(types: [.bip84])
        let draft = fixture.draft(amount: "0.01")
        #expect(throws: (any Error).self) {
            try SendBitcoinHDTransactionPlanner.prepare(draft: draft, outputs: fixture.inputs.outputs,
                requestedAtomic: 1_000_000, byteFee: 5,
                fee: SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "5", secondaryValue: nil),
                options: .automatic, changeAddress: fixture.change.address,
                recipientAddress: fixture.recipient.address)
        }
    }

    @Test(arguments: BitcoinHDAddressType.allCases)
    func outputTypeComesFromItsOwner(type: BitcoinHDAddressType) throws {
        let fixture = try CoinControlTestFixtures.make(types: [type])
        let output = try #require(fixture.inputs.outputs.first)
        let row = SendBitcoinCoinControlOutputPresentation(output: output, asset: fixture.asset,
            unitUSDPrice: 60_000, currency: SendEntryTestFixtures.currency,
            accountAddress: fixture.change.address)
        #expect(row.addressType == type.localizedName)
        #expect(!row.nativeAmount.isEmpty && row.localAmount != "—")
    }

    @Test
    func silentPaymentsRemainDistinctFromTaproot() throws {
        let fixture = try CoinControlTestFixtures.make(types: [.bip86])
        let hash = String(repeating: "ef", count: 32)
        let key = Data(repeating: 1, count: 32)
        let owner = BitcoinSilentPaymentOutput(walletID: "test-wallet", transactionHash: hash,
            outputIndex: 2, valueAtomic: try BitcoinFamilyAtomicInteger(validating: "10000"),
            scriptPubKey: Data([0x51, 0x20]) + key, outputPublicKey: key,
            blockHeight: 800_000, blockTimestamp: nil, isSpent: false, spentByTransactionHash: nil)
        let output = SendBitcoinUTXO(networkID: "bitcoin", outpoint: SendBitcoinOutpoint(
            transactionHash: hash, outputIndex: 2), valueAtomic: "10000", blockHeight: 800_000,
            confirmations: 1, silentPaymentOwner: owner)
        #expect(SendBitcoinCoinControlOutputPresentation.addressType(output: output, accountAddress: nil)
            == WalletLocalization.string("receive.bitcoin.address_type.silent_payments"))
        #expect(SendBitcoinCoinControlOutputPresentation.addressType(output: fixture.inputs.outputs[0], accountAddress: nil)
            == BitcoinHDAddressType.bip86.localizedName)
    }

    @Test(arguments: [BitcoinFamilyChain.bitcoinCash, .litecoin, .dogecoin])
    func legacyFamilySelectionUsesTheWalletCorePlan(chain: BitcoinFamilyChain) async throws {
        let database = try WalletDatabase.temporary()
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == chain.networkID })
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let draft = SendEntryTestFixtures.draft(asset: asset, amount: "0.1")
        let values = ["500000000", "300000000", "200000000"]
        let outputs = values.enumerated().map { index, value in
            SendBitcoinUTXO(networkID: chain.networkID, outpoint: SendBitcoinOutpoint(
                transactionHash: String(repeating: "ab", count: 32), outputIndex: index),
                valueAtomic: value, blockHeight: 800_000, confirmations: 1)
        }
        let account = CoinControlTestFixtures.account(address: draft.recipient, networkID: chain.networkID)
        let context = SendBitcoinPlanningInputs(walletID: "test-wallet", account: account, outputs: outputs)
        let fee = try SendResolvedNetworkFee.resolve(policy: .preset(.standard),
            quote: SendNetworkFeeAPIClient.defaultQuote(for: chain.networkID))
        let result = try await SendNetworkFeeEstimator(database: database).bitcoinFamilyPlan(
            draft: draft, fee: fee, loadedInputs: context)
        #expect(!result.outputs.isEmpty)
        #expect(result.outputs.count < outputs.count)
        for output in outputs {
            #expect(SendBitcoinCoinControlOutputPresentation.addressType(output: output,
                accountAddress: account.address) == "P2PKH")
        }
    }
}
