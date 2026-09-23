import Foundation
import GRDB
import Testing
@testable import Aperture

struct SendAmountInputPresentationTests {
    private let asset = SendEntryTestFixtures.ethereum
    private let usd = SendEntryTestFixtures.currency

    @Test(arguments: [false, true])
    func zeroBalanceWithoutCachedPriceFetchesTheSelectedAsset(isToken: Bool) async throws {
        let asset = SendEntryTestFixtures.zeroBalanceChoice(isToken: isToken)
        let database = try WalletDatabase.temporary()
        let price = await SendAmountPresentation.unitUSDPrice(
            for: asset, nativeUnitUSDPrice: nil, database: database
        ) { requested in
            #expect(requested.id == AssetIdentityKey.canonical(asset.id))
            #expect(requested.network == asset.blockchain)
            #expect(requested.balance == 0)
            return AssetUSDPrice(assetID: requested.id, price: 7,
                provider: "fixture", observedAt: Date())
        }
        #expect(price == 7)
    }

    @Test(arguments: [false, true])
    func zeroBalanceLoadsItsOwnCachedQuoteAndRestoresPreferredMode(isToken: Bool) async throws {
        let asset = SendEntryTestFixtures.zeroBalanceChoice(isToken: isToken)
        let database = try WalletDatabase.temporary()
        try await database.pool.write { db in
            try DBAssetRecord(
                id: AssetIdentityKey.canonical(asset.id), networkID: asset.networkID,
                assetType: (isToken ? DatabaseAssetType.fungibleToken : .native).rawValue,
                contractAddress: asset.contractAddress ?? "",
                normalizedContractAddress: asset.contractAddress ?? "",
                name: asset.name, symbol: asset.symbol, decimals: asset.decimals,
                trustWalletBlockchain: asset.blockchain.rawValue,
                trustWalletContractAddress: asset.contractAddress,
                isVerified: true, isSpam: false, createdAt: 0, updatedAt: 0,
                metadataUpdatedAt: nil
            ).save(db)
        }
        try await database.saveAssetUSDPrice(AssetUSDPrice(
            assetID: AssetIdentityKey.canonical(asset.id), price: 2,
            provider: "fixture", observedAt: Date()
        ))
        let price = await SendAmountPresentation.unitUSDPrice(
            for: asset, nativeUnitUSDPrice: isToken ? 3000 : nil, database: database
        )
        #expect(price == 2, "Tokens must never use the gas coin's price")
        let draft = SendEntryTestFixtures.draft(asset: asset, amount: "555")
        var entry = SendAmountEntryState(draft: draft)
        entry.applyPreferredMode(.localCurrency, asset: asset, currency: usd, unitUSDPrice: price)
        #expect(entry.mode == .localCurrency)
        #expect(entry.input == "1110")
        #expect(SendAmountInputPresentation(entry: entry, asset: asset,
            currency: usd, unitUSDPrice: price).counterpart == "555 \(asset.symbol)")
        #expect(entry.reviewDraft(from: draft, currency: usd, unitUSDPrice: price) == nil)
        try entry.changeMode(to: .asset, asset: asset, currency: usd, unitUSDPrice: price)
        #expect(entry.input == "555")
        #expect(SendAmountInputPresentation(entry: entry, asset: asset,
            currency: usd, unitUSDPrice: price).counterpart == "$1,110.00")
        let suppliedNative = await SendAmountPresentation.unitUSDPrice(
            for: asset, nativeUnitUSDPrice: 4, database: database
        )
        #expect(suppliedNative == (isToken ? 2 : 4))
    }

    @Test(arguments: ["", "0", "555"], [false, true])
    func zeroBalanceCanSwitchWithAnIndependentQuote(input: String, isToken: Bool) throws {
        let asset = SendEntryTestFixtures.zeroBalanceChoice(isToken: isToken)
        let draft = SendEntryTestFixtures.draft(asset: asset, amount: input)
        let currency = WalletCurrencyContext(code: "USD", ratePerUSD: 3)
        var entry = SendAmountEntryState(draft: draft)
        let price: Decimal = 2
        let pricing = try #require(SendAmountEntryConverter.pricing(
            asset: asset, currency: currency, unitUSDPrice: price
        ))
        #expect(pricing.balanceValue == 0)
        #expect(pricing.unitPrice == 6)
        #expect(SendAmountInputPresentation(entry: entry, asset: asset,
            currency: currency, unitUSDPrice: price).counterpart != nil)
        try entry.changeMode(to: .localCurrency, asset: asset, currency: currency, unitUSDPrice: price)
        #expect(entry.mode == .localCurrency)
        #expect(entry.input == (input == "555" ? "3330" : input))
        #expect(entry.reviewDraft(from: draft, currency: currency, unitUSDPrice: price) == nil)
        if input == "555" {
            #expect(entry.amountIssue(asset: asset, currency: currency, unitUSDPrice: price) == .exceedsBalance)
        }
        try entry.changeMode(to: .asset, asset: asset, currency: currency, unitUSDPrice: price)
        #expect(entry.input == input)
        #expect(entry.mode == .asset)
        for invalidPrice in [Decimal.zero, Decimal(-1)] {
            #expect(SendAmountEntryConverter.pricing(asset: asset, currency: currency,
                unitUSDPrice: invalidPrice) == nil)
        }
    }

    @Test
    func nativeEntryShowsLocalValueWithoutChangingTypedPrecision() throws {
        var entry = SendAmountEntryState(draft: SendEntryTestFixtures.draft(amount: "0.0100"))
        let display = SendAmountInputPresentation(entry: entry, asset: asset, currency: usd)
        #expect(display.unit == "ETH")
        #expect(display.currencyPrefix.isEmpty)
        #expect(display.counterpart == "$30.00")
        #expect(entry.input == "0.0100")
        entry.input = "1."
        #expect(SendAmountInputPresentation(entry: entry, asset: asset, currency: usd).counterpart == "$3,000.00")
        #expect(entry.input == "1.")
    }

    @Test
    func fiatEntryShowsTheExactQuantityUsedByReviewIncludingAtomicRounding() throws {
        let draft = SendEntryTestFixtures.draft()
        var entry = SendAmountEntryState(draft: draft)
        try entry.changeMode(to: .localCurrency, asset: asset, currency: usd)
        for input in ["1", "1.", "1.00", "1.12345678", "3"] {
            entry.input = input
            let display = SendAmountInputPresentation(entry: entry, asset: asset, currency: usd)
            let review = try #require(entry.reviewDraft(from: draft, currency: usd))
            #expect(display.unit == "USD")
            #expect(display.currencyPrefix == "$")
            #expect(display.counterpart == review.amount! + " ETH")
            #expect(entry.input == input)
        }
        entry.input = "1"
        #expect(SendAmountInputPresentation(entry: entry, asset: asset, currency: usd).counterpart
                == "0.000333333333333333 ETH")
    }

    @Test
    func localExchangeRateIsAppliedExactlyOnceInBothDirections() throws {
        let aed = WalletCurrencyContext(code: "AED", ratePerUSD: Decimal(string: "3.6725")!)
        var entry = SendAmountEntryState(draft: SendEntryTestFixtures.draft(amount: "0.01"))
        #expect(SendAmountInputPresentation(entry: entry, asset: asset, currency: aed).counterpart
                == EnglishNumbers.currency(Decimal(string: "110.175")!, currencyCode: "AED"))
        try entry.changeMode(to: .localCurrency, asset: asset, currency: aed)
        let display = SendAmountInputPresentation(entry: entry, asset: asset, currency: aed)
        #expect(entry.input == "110.175")
        #expect(display.currencyPrefix.trimmingCharacters(in: .whitespaces) == "AED")
        #expect(display.counterpart == "0.01 ETH")
    }

    @Test(arguments: ["USD", "EUR", "GBP", "AED", "JPY", "CHF", "INR", "SAR"])
    func localPrefixMatchesCentralCurrencyFormatterAndNeverContainsDigits(code: String) throws {
        let currency = WalletCurrencyContext(code: code, ratePerUSD: 1)
        var entry = SendAmountEntryState(draft: SendEntryTestFixtures.draft())
        try entry.changeMode(to: .localCurrency, asset: asset, currency: currency)
        let display = SendAmountInputPresentation(entry: entry, asset: asset, currency: currency)
        #expect(!display.currencyPrefix.isEmpty)
        #expect(EnglishNumbers.currency(0, currencyCode: code).hasPrefix(display.currencyPrefix + "0"))
        #expect(!display.currencyPrefix.contains { $0.isNumber })
        #expect(display.counterpart == "0 ETH")
        #expect(entry.input.isEmpty)
    }

    @Test
    func missingPriceOrExchangeRateHidesTheCounterpartInsteadOfInventingAValue() {
        let unpriced = SendAssetChoice(
            id: asset.id, name: asset.name, symbol: asset.symbol,
            networkID: asset.networkID, networkName: asset.networkName,
            blockchain: asset.blockchain, contractAddress: asset.contractAddress, decimals: asset.decimals,
            logoSource: asset.logoSource, networkLogoSource: asset.networkLogoSource,
            balance: asset.balance, fiatValue: 0
        )
        var entry = SendAmountEntryState(draft: SendEntryTestFixtures.draft(asset: unpriced, amount: "1.23"))
        entry.applyPreferredMode(.localCurrency, asset: unpriced, currency: usd)
        let display = SendAmountInputPresentation(entry: entry, asset: unpriced, currency: usd)
        #expect(display.counterpart == nil)
        #expect(display.currencyPrefix.isEmpty)
        #expect(display.unit == "ETH")
        #expect(entry.input == "1.23")
        for rate in [Decimal.zero, Decimal(-1)] {
            #expect(SendAmountInputPresentation(
                entry: entry, asset: asset, currency: WalletCurrencyContext(code: "AED", ratePerUSD: rate)
            ).counterpart == nil)
        }
    }

    @Test
    func maxCounterpartKeepsAllTwentyFourNativeDecimalsAndDoesNotRoundThroughFiat() throws {
        let near = SendAssetChoice(
            id: "near:native", name: "NEAR", symbol: "NEAR", networkID: "near", networkName: "NEAR",
            blockchain: .near, contractAddress: nil, decimals: 24,
            logoSource: .nativeCoin(blockchain: .near), networkLogoSource: .nativeCoin(blockchain: .near),
            balance: Decimal(string: "5.515555838897961624934314")!, fiatValue: 10,
            balanceAtomic: "5515555838897961624934314"
        )
        var entry = SendAmountEntryState(draft: SendEntryTestFixtures.draft(asset: near))
        try entry.changeMode(to: .localCurrency, asset: near, currency: usd)
        try entry.applyMaximum(asset: near, currency: usd)
        #expect(entry.input == "10")
        #expect(SendAmountInputPresentation(entry: entry, asset: near, currency: usd).counterpart
                == "5.515555838897961624934314 NEAR")
        #expect(entry.usesMaximumBalance)
    }

    @Test(arguments: [0, 6, 8, 9, 18, 24])
    func pricedTokensRespectTheirAtomicPrecisionInTheDisplayedAndReviewedAmounts(decimals: Int) throws {
        let token = SendAssetChoice(
            id: "ethereum:token", name: "Token", symbol: "TOKEN",
            networkID: asset.networkID, networkName: asset.networkName,
            blockchain: asset.blockchain,
            contractAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            decimals: decimals, logoSource: .unavailable, networkLogoSource: asset.networkLogoSource,
            balance: 100, fiatValue: 200
        )
        let draft = SendEntryTestFixtures.draft(asset: token)
        var entry = SendAmountEntryState(draft: draft)
        try entry.changeMode(to: .localCurrency, asset: token, currency: usd)
        entry.input = "3.12345678"
        let expectedAmount = decimals == 0 ? "1" : decimals == 6 ? "1.561728" : "1.56172839"
        #expect(SendAmountInputPresentation(entry: entry, asset: token, currency: usd).counterpart
                == expectedAmount + " TOKEN")
        #expect(entry.reviewDraft(from: draft, currency: usd)?.amount == expectedAmount)
        #expect(entry.input == "3.12345678")
    }

    @Test(arguments: AssetNetworkSelectorOption.allSupported)
    func nativeAndFiatCounterpartsUseTheSameExactConversionForEverySupportedNetwork(
        network: AssetNetworkSelectorOption
    ) throws {
        let choice = try SendEntryTestFixtures.nativeChoice(for: network)
        let draft = SendEntryTestFixtures.draft(asset: choice, amount: "1")
        var entry = SendAmountEntryState(draft: draft)
        #expect(SendAmountInputPresentation(entry: entry, asset: choice, currency: usd).counterpart == "$2.00")
        try entry.changeMode(to: .localCurrency, asset: choice, currency: usd)
        #expect(entry.input == "2")
        #expect(SendAmountInputPresentation(entry: entry, asset: choice, currency: usd).counterpart
                == "1 " + choice.symbol)
        #expect(entry.reviewDraft(from: draft, currency: usd)?.amount == "1")
    }

    @Test(arguments: ["NaN", "-1", "١٢", String(repeating: "9", count: 200)])
    func invalidOrUnrepresentableConversionNeverShowsNaNOrAnInventedZero(value: String) {
        let entry = SendAmountEntryState(draft: SendEntryTestFixtures.draft(amount: value))
        #expect(SendAmountInputPresentation(entry: entry, asset: asset, currency: usd).counterpart == nil)
        #expect(entry.input == value)
    }
}
