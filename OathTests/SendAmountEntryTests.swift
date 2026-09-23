import Foundation
import Testing
@testable import Aperture

struct SendAmountEntryTests {
    private let currency = SendEntryTestFixtures.currency

    @Test
    func keypadNormalizesLeadingZerosDecimalAndDelete() {
        var state = SendAmountEntryState(draft: SendEntryTestFixtures.draft())
        let asset = SendEntryTestFixtures.ethereum
        let steps: [(SendAmountKey, String, Bool)] = [
            (.digit("0"), "0", true), (.digit("0"), "0", false),
            (.digit("2"), "2", true), (.decimal, "2.", true), (.decimal, "2.", false),
            (.digit("5"), "2.5", true), (.delete, "2.", true), (.delete, "2", true),
            (.delete, "", true), (.delete, "", false), (.decimal, "0.", true),
            (.clear, "", true), (.clear, "", false)
        ]
        for (key, text, expectedAccepted) in steps {
            let accepted = state.press(key, asset: asset)
            #expect(accepted == expectedAccepted)
            #expect(state.input == text)
            if text == "2." {
                #expect(state.assetAmount(asset: asset, currency: currency) == "2")
            }
        }
    }

    @Test(arguments: ["١", "۴", "９", "Ⅳ", "-", "+", "1e3", "12", " ", "\n", "", ","])
    func keypadRejectsAnythingOtherThanOneASCIIDigit(input: String) {
        #expect(SendAmountKeypadInput.applying(
            .digit(input), to: "1", maximumFractionDigits: 18
        ) == nil)
    }

    @Test(arguments: [0, 1, 6, 7, 8, 9, 18, 24])
    func precisionLimitMatchesNativeAndTokenDecimals(decimals: Int) {
        if decimals == 0 {
            #expect(SendAmountKeypadInput.applying(
                .decimal, to: "1", maximumFractionDigits: 0
            ) == nil)
        } else {
            let input = "0." + String(repeating: "1", count: decimals)
            #expect(SendAmountKeypadInput.applying(
                .digit("1"), to: input, maximumFractionDigits: decimals
            ) == nil)
            #expect(SendAmountKeypadInput.applying(
                .delete, to: input, maximumFractionDigits: decimals
            ) == String(input.dropLast()))
        }
        #expect(SendAmountKeypadInput.applying(
            .digit("9"), to: "1", maximumFractionDigits: decimals
        ) == "19")
    }

    @Test
    func untrustedURIPrecisionCanBeRepairedAndInputLengthIsBounded() {
        #expect(SendAmountKeypadInput.applying(
            .delete, to: "0.123456789", maximumFractionDigits: 6
        ) == "0.12345678")
        #expect(SendAmountKeypadInput.applying(
            .digit("1"), to: String(repeating: "1", count: 200), maximumFractionDigits: 18
        ) == nil)
    }

    @Test(arguments: AssetNetworkSelectorOption.allSupported)
    func independentStepsPreserveExactAmountsForEveryNativeNetwork(
        network: AssetNetworkSelectorOption
    ) throws {
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let draft = SendEntryTestFixtures.draft(asset: asset)
        let amount = "0." + String(repeating: "0", count: asset.decimals - 1) + "1"
        var entry = SendAmountEntryState(draft: draft)
        for character in amount {
            let accepted = entry.press(character == "." ? .decimal : .digit(String(character)), asset: asset)
            #expect(accepted)
        }
        let review = try #require(entry.reviewDraft(from: draft, currency: currency))
        #expect(review.recipient == draft.recipient)
        #expect(review.asset == asset)
        #expect(review.amount == amount)
        #expect(try SendAtomicAmount.fromUserUnits(review.amount!, decimals: asset.decimals) == "1")
        #expect(review.usesMaximumBalance == false)
    }

    @Test
    func invalidZeroAndOverBalanceAmountsCannotProceed() {
        let draft = SendEntryTestFixtures.draft()
        var entry = SendAmountEntryState(draft: draft)
        #expect(entry.amountIssue(asset: draft.asset, currency: currency) == .required)
        for amount in ["0", "0.", "0.0", "-1", "١", "3", "nan"] {
            entry.input = amount
            #expect(entry.reviewDraft(from: draft, currency: currency) == nil)
        }
        entry.input = "2.000000000000000001"
        #expect(entry.amountIssue(asset: draft.asset, currency: currency) == .exceedsBalance)
        entry.input = "0.0000000000000000001"
        #expect(entry.amountIssue(asset: draft.asset, currency: currency) == .precision(18))
    }

    @Test
    func modeConversionUsesSelectedLocalCurrencyWithoutBinaryFloatingPoint() throws {
        let draft = SendEntryTestFixtures.draft(amount: "0.01")
        let aed = WalletCurrencyContext(code: "AED", ratePerUSD: Decimal(string: "3.6725")!)
        var entry = SendAmountEntryState(draft: draft)
        try entry.changeMode(to: .localCurrency, asset: draft.asset, currency: aed)
        #expect(entry.input == "110.175")
        #expect(entry.maximumFractionDigits(for: draft.asset) == 8)
        #expect(entry.reviewDraft(from: draft, currency: aed)?.amount == "0.01")
        try entry.changeMode(to: .asset, asset: draft.asset, currency: aed)
        #expect(entry.input == "0.01")
    }

    @Test
    func unpricedAssetStaysInNativeModeAndDoesNotDiscardInput() throws {
        let priced = SendEntryTestFixtures.ethereum
        let unpriced = SendAssetChoice(
            id: priced.id, name: priced.name, symbol: priced.symbol,
            networkID: priced.networkID, networkName: priced.networkName,
            blockchain: priced.blockchain, contractAddress: nil, decimals: priced.decimals,
            logoSource: priced.logoSource, networkLogoSource: priced.networkLogoSource,
            balance: priced.balance, fiatValue: 0
        )
        let draft = SendEntryTestFixtures.draft(asset: unpriced, amount: "0.5")
        var entry = SendAmountEntryState(draft: draft)
        entry.applyPreferredMode(.localCurrency, asset: unpriced, currency: currency)
        #expect(entry.mode == .asset)
        #expect(entry.input == "0.5")
        #expect(entry.reviewDraft(from: draft, currency: currency)?.amount == "0.5")
        #expect(throws: SendAmountEntryConversionError.pricingUnavailable) {
            try entry.changeMode(to: .localCurrency, asset: unpriced, currency: currency)
        }
    }

    @Test
    func maxKeepsExactAtomicBalanceAcrossModesAndBackNavigation() throws {
        let near = SendAssetChoice(
            id: "near:native", name: "NEAR", symbol: "NEAR", networkID: "near", networkName: "NEAR",
            blockchain: .near, contractAddress: nil, decimals: 24,
            logoSource: .nativeCoin(blockchain: .near), networkLogoSource: .nativeCoin(blockchain: .near),
            balance: Decimal(string: "5.515555838897961624934314")!, fiatValue: 10,
            balanceAtomic: "5515555838897961624934314"
        )
        let draft = SendEntryTestFixtures.draft(asset: near)
        var entry = SendAmountEntryState(draft: draft)
        try entry.applyMaximum(asset: near, currency: currency)
        #expect(entry.input == "5.515555838897961624934314")
        try entry.changeMode(to: .localCurrency, asset: near, currency: currency)
        #expect(entry.input == "10")
        var cache: [SendDraft: SendAmountEntryState] = [:]
        cache[draft] = entry
        let restored = try #require(cache[draft])
        #expect(restored == entry)
        let review = try #require(restored.reviewDraft(from: draft, currency: currency))
        #expect(review.amount == "5.515555838897961624934314")
        #expect(review.usesMaximumBalance)
        let acceptedUnicode = entry.press(.digit("١"), asset: near)
        #expect(!acceptedUnicode)
        #expect(entry.usesMaximumBalance)
        let acceptedDelete = entry.press(.delete, asset: near)
        #expect(acceptedDelete)
        #expect(!entry.usesMaximumBalance)
    }

    @Test
    func restoredInputDoesNotReapplyPreferredModeOrLoseDecimalInProgress() throws {
        let draft = SendEntryTestFixtures.draft()
        var entry = SendAmountEntryState(draft: draft)
        entry.applyPreferredMode(.localCurrency, asset: draft.asset, currency: currency)
        for key in [SendAmountKey.digit("1"), .decimal, .digit("0")] {
            let accepted = entry.press(key, asset: draft.asset)
            #expect(accepted)
        }
        entry.applyPreferredMode(.asset, asset: draft.asset, currency: currency)
        #expect(entry.mode == .localCurrency)
        #expect(entry.input == "1.0")
    }

    @Test
    func reviewKeepsMemoNoteFeeAndManualCoinSelection() throws {
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == "bitcoin" })
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let draft = SendEntryTestFixtures.draft(asset: asset, amount: "0.1", memo: "reference")
        let output = SendBitcoinUTXO(
            networkID: asset.networkID,
            outpoint: SendBitcoinOutpoint(transactionHash: String(repeating: "a", count: 64), outputIndex: 0),
            valueAtomic: "20000000", blockHeight: 1, confirmations: 1
        )
        var entry = SendAmountEntryState(draft: draft)
        entry.note = "  Invoice 42  "
        entry.feePolicy = .preset(.economy)
        entry.bitcoinFamilyOptions = .automatic.replacingCoinSelection(.manual([output]))
        let review = try #require(entry.reviewDraft(from: draft, currency: currency))
        #expect(review.request.memo == "reference")
        #expect(review.note == "Invoice 42")
        #expect(review.feePolicy == entry.feePolicy)
        #expect(review.bitcoinFamilyOptions == entry.bitcoinFamilyOptions)
        #expect(review.preparedNetworkFee == nil)
        entry.input = "0.3"
        #expect(entry.coinControlIssue(asset: asset, currency: currency) == .insufficientSelectedValue)
        #expect(entry.reviewDraft(from: draft, currency: currency) == nil)
    }
}
