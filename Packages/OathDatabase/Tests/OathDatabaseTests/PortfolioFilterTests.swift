import XCTest
@testable import OathDatabase

final class PortfolioFilterTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    private func holding(_ id: String, network: String = "ethereum", token: Bool = false,
                         name: String? = nil, amount: String? = "100", decimals: Int = 2,
                         price: String? = "10", rate: String? = "1", activity: Int = 0,
                         account: String = "public-test") -> Holding {
        Holding(accountID: account, networkID: network, address: "public-fixture", assetID: id,
            reference: token ? "contract-" + id : "native", name: name ?? id, symbol: id,
            decimals: decimals, logo: nil, amountAtomic: amount,
            balanceObservedAt: amount == nil ? nil : 1, usdPrice: price, exchangeRate: rate,
            priceObservedAt: price == nil ? nil : 1, priceSource: "fixture", transactionCount: activity)
    }

    private func result(_ selection: PortfolioFilter, _ rows: [Holding], currency: String = "USD") -> [String] {
        selection.applying(to: rows, currency: currency, locale: locale).map(\.assetID)
    }

    func testDefaultPreservesPortfolioPolicyAndDoesNotMutateHoldings() {
        let rows = [holding("low", price: "1", activity: 20), holding("high", price: "100"),
                    holding("unknown", amount: nil), holding("active", price: "1", activity: 30)]
        let original = rows
        XCTAssertEqual(PortfolioFilter().applying(to: rows, currency: "USD"), AssetOrdering.sorted(rows, by: \.sortKey))
        XCTAssertEqual(rows, original)
        XCTAssertEqual(PortfolioFilter().activeCount, 0)
    }

    func testCategoriesCombineAndNetworksAreAnInclusiveUnion() {
        let rows = [holding("ETH"), holding("USDC", token: true, activity: 1),
                    holding("SUI", network: "sui", activity: 2),
                    holding("token", network: "sui", token: true, activity: 1),
                    holding("empty", token: true, amount: "0", activity: 3),
                    holding("quiet", token: true), holding("other", network: "solana", token: true, activity: 1)]
        var filter = PortfolioFilter()
        filter.kind = .tokens; filter.networkIDs = ["ethereum", "sui"]
        filter.hidesZeroBalances = true; filter.onlyWithActivity = true
        XCTAssertEqual(Set(result(filter, rows)), ["USDC", "token"])
        filter.networkIDs = ["ethereum"]
        XCTAssertEqual(result(filter, rows), ["USDC"])
        filter.kind = .coins; filter.onlyWithActivity = false
        XCTAssertEqual(result(filter, rows), ["ETH"])
        XCTAssertEqual(filter.activeCount, 3)
    }

    func testPresortedSnapshotIsFilteredWithoutReordering() {
        let rows = [holding("low", price: "1"), holding("zero", amount: "0"), holding("high", price: "100")]
        var filter = PortfolioFilter(); filter.hidesZeroBalances = true
        XCTAssertEqual(filter.applying(to: rows, currency: "USD", preservingRecommendedOrder: true).map(\.assetID), ["low", "high"])
        XCTAssertEqual(filter.applying(to: rows, currency: "USD").map(\.assetID), ["high", "low"])
        filter.sort = .highestValue
        XCTAssertEqual(filter.applying(to: rows, currency: "USD", preservingRecommendedOrder: true).map(\.assetID), ["high", "low"])
    }

    func testHideZeroKeepsDustLargeAtomicValuesAndUnknownBalances() {
        let rows = [holding("zero", amount: "0"), holding("leadingZero", amount: "000"),
                    holding("dust", amount: "1", decimals: 18), holding("unknown", amount: nil),
                    holding("huge", amount: String(repeating: "9", count: 70), decimals: 18)]
        var filter = PortfolioFilter(); filter.hidesZeroBalances = true
        XCTAssertEqual(Set(result(filter, rows)), ["dust", "unknown", "huge"])
    }

    func testValueSortUsesComparableMoneyAndKeepsUnknownLastBothWays() {
        let rows = [holding("manyCheap", amount: "1000000", price: "0.001"),
                    holding("oneValuable", amount: "100", price: "100"),
                    holding("zero", amount: "0", price: nil), holding("unpriced", price: nil),
                    holding("notLoaded", amount: nil)]
        var filter = PortfolioFilter(); filter.sort = .highestValue
        XCTAssertEqual(Array(result(filter, rows).prefix(3)), ["oneValuable", "manyCheap", "zero"])
        filter.sort = .lowestValue
        XCTAssertEqual(Array(result(filter, rows).prefix(3)), ["zero", "manyCheap", "oneValuable"])
        XCTAssertEqual(Set(result(filter, rows).suffix(2)), ["notLoaded", "unpriced"])
        let missingFX = rows.map { holding($0.assetID, amount: $0.amountAtomic, price: $0.usdPrice, rate: nil) }
        XCTAssertEqual(result(filter, missingFX), result(filter, rows))
    }

    func testNamesSortNaturallyAndDuplicateNamesHaveStableAccountIdentity() {
        let rows = [holding("ten", name: "Token 10"), holding("two", name: "Token 2"),
                    holding("alpha", name: "Álpha"), holding("z", name: "same", account: "b"),
                    holding("a", name: "same", account: "a")]
        var filter = PortfolioFilter(); filter.sort = .nameAscending
        XCTAssertEqual(result(filter, rows), ["alpha", "a", "z", "two", "ten"])
        filter.sort = .nameDescending
        XCTAssertEqual(result(filter, rows), ["ten", "two", "a", "z", "alpha"])
    }

    func testActivitySortDoesNotUseBalanceAsActivity() {
        let rows = [holding("rich", price: "1000", activity: 0),
                    holding("active", amount: "0", activity: 20), holding("some", activity: 2)]
        var filter = PortfolioFilter(); filter.sort = .mostActive
        XCTAssertEqual(result(filter, rows), ["active", "some", "rich"])
        filter.onlyWithActivity = true
        XCTAssertEqual(result(filter, rows), ["active", "some"])
    }

    func testLocalCurrencyRangeIsInclusiveAndUnknownValuesAreNotZero() {
        let rows = [holding("under", price: "1", rate: "2"), holding("min", price: "5", rate: "2"),
                    holding("max", price: "10", rate: "2"), holding("over", price: "11", rate: "2"),
                    holding("unknown", price: nil), holding("noFX", rate: nil)]
        var filter = PortfolioFilter(); filter.minimumValue = 10; filter.maximumValue = 20; filter.rangeCurrency = "EUR"
        XCTAssertEqual(Set(result(filter, rows, currency: "EUR")), ["min", "max"])
        filter.minimumValue = nil; filter.maximumValue = 0
        XCTAssertEqual(result(filter, rows, currency: "EUR"), [])
        XCTAssertEqual(result(filter, [holding("zero", amount: "0", price: nil)], currency: "EUR"), ["zero"])
    }

    func testCurrencyChangeClearsOnlyRangeAndResetRestoresAll() {
        var filter = PortfolioFilter(); filter.kind = .tokens; filter.sort = .lowestValue
        filter.minimumValue = 100; filter.maximumValue = 200; filter.rangeCurrency = "USD"
        let euro = filter.adjusted(for: "EUR")
        XCTAssertNil(euro.minimumValue); XCTAssertNil(euro.maximumValue); XCTAssertNil(euro.rangeCurrency)
        XCTAssertEqual(euro.kind, .tokens); XCTAssertEqual(euro.sort, .lowestValue)
        XCTAssertEqual(filter.adjusted(for: "USD"), filter)
        let rows = [holding("token", token: true), holding("coin")]
        XCTAssertEqual(result(filter, rows, currency: "EUR"), ["token"])
        filter = .init()
        XCTAssertEqual(Set(result(filter, rows)), ["coin", "token"])
    }

    func testLocalizedRangeParsingRejectsMalformedAndExtremeInput() {
        XCTAssertEqual(PortfolioFilter.value("١٢٫٥", locale: Locale(identifier: "ar")), Decimal(string: "12.5"))
        XCTAssertEqual(PortfolioFilter.value("12,5", locale: Locale(identifier: "de_DE")), Decimal(string: "12.5"))
        for value in ["", "-1", "NaN", "Infinity", "1e6", "1..2", "10 USD", String(repeating: "9", count: 39)] {
            XCTAssertNil(PortfolioFilter.value(value, locale: locale), value)
        }
        var filter = PortfolioFilter(); filter.rangeCurrency = "USD"
        filter.minimumValue = 20; filter.maximumValue = 10
        XCTAssertFalse(filter.isValid)
        filter.minimumValue = -1; XCTAssertFalse(filter.isValid)
        filter.minimumValue = .nan; XCTAssertFalse(filter.isValid)
        filter.minimumValue = 0; filter.maximumValue = 0; XCTAssertTrue(filter.isValid)
        filter.rangeCurrency = nil; XCTAssertFalse(filter.isValid)
    }

    func testFilterDraftIsIndependentAndEmptySelectionIncludesNewNetworks() {
        let applied = PortfolioFilter()
        var draft = applied; draft.networkIDs = ["ethereum"]; draft.kind = .tokens
        XCTAssertEqual(applied.activeCount, 0)
        let refreshed = [holding("ETH"), holding("SUI", network: "sui")]
        XCTAssertEqual(Set(result(applied, refreshed)), ["ETH", "SUI"])
        XCTAssertTrue(result(draft, refreshed).isEmpty)
        XCTAssertEqual(refreshed.count, 2)
    }
}
