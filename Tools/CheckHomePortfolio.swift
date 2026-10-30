import Foundation
import Observation
import OathDatabase

@main struct CheckHomePortfolio {
    static func holding(_ index: Int, amount: String = "123456789", timestamp: Double = 1,
                        network: String = "ethereum", activity: Int = 0, pending: Int = 0,
                        native: Bool = false, account: String? = nil) throws -> Holding {
        let json: [String: Any] = ["accountID": account ?? "fixture-" + network, "networkID": network,
            "address": "public-fixture", "assetID": "asset-\(index)", "reference": native ? "native" : "token-\(index)",
            "name": "Token \(index)", "symbol": "T\(index)", "decimals": 8, "amountAtomic": amount,
            "balanceObservedAt": timestamp, "usdPrice": "12.5", "exchangeRate": "1",
            "priceObservedAt": timestamp, "priceSource": "fixture", "transactionCount": activity, "pendingTransactionCount": pending]
        return try JSONDecoder().decode(Holding.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func input(_ holdings: [Holding], wallet: String = "public-fixture", currency: String = "USD",
                      locale: String = "en_US", filter: PortfolioFilter = .init(), query: String = "") -> OathHomePortfolioInput {
        .init(walletID: wallet, holdings: holdings, currency: currency, total: 25,
              filter: filter, query: query, formattingLocale: locale, sortingLocale: locale)
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            precondition(ContinuousClock.now < deadline, "Presentation did not settle")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor static func main() async throws {
        let treeBuilder = OathHomePortfolioBuilder()
        for network in ["chiliz", "polkadot", "filecoin", "sei", "zerog", "iotex"] {
            let token = try holding(7, network: network)
            for query in [network + " T7", "T7 " + network, "  " + network.uppercased() + "   t7  "] {
                let result = try await treeBuilder.build(input([token], query: query))
                precondition(result.searchRows.map(\.id) == [token.id], "Saved and discovered tokens must match network/symbol words in either order")
            }
            let absent = try await treeBuilder.build(input([token], query: network + " absent"))
            precondition(absent.searchRows.isEmpty)
        }
        print("PASS: six-chain saved-token search preserves discovery word matching")
        let tokenA = try holding(1), coinA = try holding(2, native: true)
        let tokenB = try holding(3, network: "solana"), tokenA2 = try holding(4)
        let anotherAccount = try holding(5, account: "separate-account")
        let treeSource = [tokenA, tokenB, coinA, tokenA2, anotherAccount]
        let flat = try await treeBuilder.build(input(treeSource))
        precondition(flat.treeRows.isEmpty && flat.rows.map(\.id) == treeSource.map(\.id))
        var grouped = PortfolioFilter(); grouped.groupsTokensByChain = true
        let tree = try await treeBuilder.build(input(treeSource, filter: grouped))
        precondition(tree.rows == flat.rows && tree.searchRows == flat.searchRows)
        precondition(tree.formattedRowCount == 0, "Grouping must reuse cached formatting")
        precondition(tree.treeRows.compactMap(\.presentation).map(\.id) == [coinA, tokenA, tokenA2, tokenB, anotherAccount].map(\.id))
        precondition(tree.treeRows[0].hasChildren && !tree.treeRows[0].isChild)
        precondition(tree.treeRows[1].continues && !tree.treeRows[2].continues)
        precondition(tree.treeRows.filter { $0.presentation == nil }.count == 2, "Missing native and separate account get independent headings")
        grouped.kind = .tokens
        let tokensOnly = try await treeBuilder.build(input(treeSource, filter: grouped))
        precondition(tokensOnly.treeRows.compactMap(\.presentation).allSatisfy { $0.holding.reference != "native" })
        var hiddenTreeInput = input(treeSource, filter: grouped)
        hiddenTreeInput.hiddenAssetIDs = [tokenA.assetID, tokenA2.assetID]
        let hiddenTree = try await treeBuilder.build(hiddenTreeInput)
        precondition(hiddenTree.treeRows.compactMap(\.presentation).map(\.id) == [tokenB, anotherAccount].map(\.id))
        let emptyTree = try await treeBuilder.build(input([], filter: grouped))
        precondition(emptyTree.treeRows.isEmpty)
        let restoredFlat = try await treeBuilder.build(input(treeSource))
        precondition(restoredFlat.treeRows.isEmpty && restoredFlat.rows == flat.rows)
        print("PASS: opt-in chain tree, native-first, stable children, missing parents, account isolation, filters and flat restoration")
        let visibilityBuilder = OathHomePortfolioBuilder()
        let rows = try (0..<1_000).map { try holding($0) }
        let source = input(rows)
        var hidden = source
        hidden.hiddenAssetIDs = [rows[0].assetID, rows[1].assetID]
        precondition(hidden != source, "Visibility invalidates the presentation input")
        let hiddenResult = try await visibilityBuilder.build(hidden)
        precondition(hiddenResult.rows.count == rows.count - 2)
        precondition(!hiddenResult.rows.contains { hidden.hiddenAssetIDs.contains($0.holding.assetID) })
        precondition(hiddenResult.searchRows.count == rows.count, "Search can still find hidden assets")
        let shownResult = try await visibilityBuilder.build(source)
        precondition(shownResult.rows.count == rows.count && shownResult.total == hiddenResult.total)
        let visibilityModel = OathHomePortfolioModel()
        try visibilityModel.publish(try await visibilityModel.prepare(hidden))
        precondition(visibilityModel.rows.count == rows.count - 2, "Cold launch respects hidden assets")
        visibilityModel.update(source)
        try await waitUntil { visibilityModel.rows.count == rows.count }
        visibilityModel.update(hidden)
        try await waitUntil { visibilityModel.rows.count == rows.count - 2 }
        visibilityModel.update(input(rows, wallet: "another-wallet"))
        try await waitUntil { visibilityModel.rows.count == rows.count }
        visibilityModel.cancel()
        print("PASS: hide/restore, cold launch, search, valuation and wallet isolation")
        let builder = OathHomePortfolioBuilder()
        let first = try await builder.build(source)
        precondition(first.rows.map(\.id) == rows.map(\.id), "Keep the database's recommended order")
        precondition(first.formattedRowCount == rows.count)
        let format = OathAssetAmountFormat(locale: Locale(identifier: "en_US"), selectedCurrencyCode: "USD")
        for row in first.rows {
            let h = row.holding
            precondition(row.nativeSummary == format.nativeSummary(h.nativeDisplayValue, ticker: h.symbol))
            precondition(row.nativeFull == format.native(h.nativeDisplayValue, ticker: h.symbol))
            precondition(row.fiat == String(format.fiat(.init(native: h.nativeDisplayValue,
                fiat: h.fiatDisplayValue, currencyCode: "USD")).characters))
        }
        let freshness = input(try (0..<1_000).map { try holding($0, timestamp: 2) })
        precondition(source == freshness, "Checkpoints must not invalidate visible content")
        let warm = try await builder.build(freshness)
        precondition(warm.formattedRowCount == 0 && warm.rows == first.rows)
        var changed = rows
        changed[50] = try holding(50, amount: "999999999", timestamp: 3)
        let incremental = try await builder.build(input(changed))
        precondition(incremental.formattedRowCount == 1 && incremental.rows[50].fiat != first.rows[50].fiat)
        precondition(incremental.rows[49] == first.rows[49] && incremental.rows[51] == first.rows[51])

        let pendingBuilder = OathHomePortfolioBuilder()
        _ = try await pendingBuilder.build(input(changed))
        var pendingRows = changed
        pendingRows[50] = try holding(50, amount: "999999999", timestamp: 3, pending: 2)
        precondition(input(pendingRows) != input(changed), "Pending count alone invalidates Home")
        let pendingResult = try await pendingBuilder.build(input(pendingRows))
        precondition(pendingResult.formattedRowCount == 1 && pendingResult.rows[50].holding.pendingTransactionCount == 2)
        precondition(pendingResult.rows[49] == incremental.rows[49])
        let confirmedResult = try await pendingBuilder.build(input(changed))
        precondition(confirmedResult.formattedRowCount == 1 && confirmedResult.rows[50].holding.pendingTransactionCount == 0)
        let pendingModel = OathHomePortfolioModel()
        try pendingModel.publish(try await pendingModel.prepare(input(pendingRows)))
        pendingModel.update(input(changed))
        try await waitUntil { pendingModel.rows[50].holding.pendingTransactionCount == 0 }
        pendingModel.cancel()
        print("PASS: pending badge updates and clears without balance or total activity changes")

        var filter = PortfolioFilter(); filter.sort = .nameDescending
        let filtered = try await builder.build(input(changed, filter: filter, query: "Token 50"))
        precondition(filtered.formattedRowCount == 0, "Filtering should reuse formatted rows")
        precondition(filtered.rows.map(\.id) == filter.applying(to: changed, currency: "USD",
            locale: Locale(identifier: "en_US")).map(\.id))
        precondition(filtered.searchRows.map(\.id) == changed.filter {
            $0.name.contains("50")
        }.map(\.id))
        let localized = try await builder.build(input(changed, currency: "JPY", locale: "ja_JP"))
        precondition(localized.formattedRowCount == rows.count && localized.rows[50].fiat != incremental.rows[50].fiat)
        let switched = try await builder.build(input(changed, wallet: "another-wallet"))
        precondition(switched.formattedRowCount == rows.count)
        _ = try await builder.build(input([rows[0]]))
        let bounded = try await builder.build(input([rows[0], rows[1]]))
        precondition(bounded.formattedRowCount == 1, "Rows removed from the wallet must leave the cache")

        // Match Asset detail's selected-language formatter even when the device
        // language differs. Cover prepared startup, live language switches,
        // cached rows and the empty-wallet zero in every supported language.
        let localizedModel = OathHomePortfolioModel()
        precondition(OathLanguage.allCases.count == 57)
        for currency in ["JOD", "USD", "EUR", "JPY"] {
            for language in OathLanguage.allCases {
                let preference = OathLanguagePreference(rawValue: language.rawValue)!
                let locale = preference.resolve(preferredLanguages: ["en-US"]).locale
                precondition(locale == language.locale, "Explicit app language overrides device language")
                let source = input([rows[0]], currency: currency, locale: locale.identifier)
                let detailFormat = OathAssetAmountFormat(locale: locale, selectedCurrencyCode: currency)
                let expectedTotal = String(detailFormat.fiat(.init(native: nil, fiat: 25, currencyCode: currency)).characters)
                let expectedRow = String(detailFormat.fiat(.init(native: rows[0].nativeDisplayValue,
                    fiat: rows[0].fiatDisplayValue, currencyCode: currency)).characters)
                try localizedModel.publish(try await localizedModel.prepare(source))
                precondition(localizedModel.total == expectedTotal && localizedModel.rows[0].fiat == expectedRow,
                             "Startup must match Asset detail for \(language.rawValue)/\(currency)")
                localizedModel.update(input([rows[0]], currency: currency, locale: "en_US"))
                let deviceTotal = String(OathAssetAmountFormat(locale: Locale(identifier: "en_US"),
                    selectedCurrencyCode: currency).fiat(.init(native: nil, fiat: 25, currencyCode: currency)).characters)
                try await waitUntil { localizedModel.total == deviceTotal }
                localizedModel.update(source)
                try await waitUntil { localizedModel.total == expectedTotal && localizedModel.rows[0].fiat == expectedRow }
                let zero = try await builder.build(.init(walletID: source.walletID, holdings: [], currency: currency,
                    total: .zero, filter: .init(), query: "", formattingLocale: locale.identifier,
                    sortingLocale: locale.identifier))
                precondition(zero.total == String(detailFormat.fiat(.unavailable).characters),
                             "Empty Home and fallback must share selected-language zero formatting")
            }
        }
        localizedModel.cancel()
        let arabic = OathAssetAmountFormat(locale: OathLanguage.arabic.locale, selectedCurrencyCode: "JOD")
        precondition(String(arabic.fiat(.init(native: nil, fiat: 25, currencyCode: "JOD")).characters).contains("د.أ."))
        print("PASS: startup, language changes, Home rows/totals and zero fallback match Asset detail across 57 languages and four currencies")

        // Exercise the actual observation/publication path. A single chain's
        // result is visible before any other chain has updated its balance.
        let model = OathHomePortfolioModel()
        let btc = try holding(0, network: "bitcoin"), eth = try holding(1)
        try model.publish(try await model.prepare(input([btc, eth])))
        precondition(model.hasPrepared && model.rows.count == 2, "Local rows must be ready before revealing Home")
        model.cancel() // Lock/Face ID's inactive transition must retain saved rows.
        precondition(model.hasPrepared && model.rows.count == 2, "A lock cannot erase display metadata")
        model.update(input([btc, eth]))
        try await waitUntil { model.rows.count == 2 }
        let updatedBTC = try holding(0, amount: "200000000", network: "bitcoin")
        model.update(input([updatedBTC, eth]))
        try await waitUntil { model.rows.first?.holding.amountAtomic == "200000000" }
        precondition(model.rows[1].holding == eth, "Do not wait for other chains to finish")

        // Thousands of real formatter/Decimal operations while MainActor keeps
        // servicing another task. This catches accidentally moving the builder
        // back onto MainActor without launching the app or a simulator.
        let large = try (0..<5_000).map { try holding($0) }
        let started = ContinuousClock.now
        model.update(input(large, wallet: "large-wallet"))
        var heartbeats = 0
        while model.rows.count != large.count {
            precondition(ContinuousClock.now - started < .seconds(30))
            heartbeats += 1
            try await Task.sleep(for: .milliseconds(2))
        }
        precondition(heartbeats > 1, "MainActor must stay available during presentation work")
        print("Background preparation: 5,000 rows in \(ContinuousClock.now - started); MainActor serviced \(heartbeats) heartbeats")

        // A burst is replaced by its latest state, including wallet, currency,
        // query and filter. No stale output may publish after cancellation.
        model.update(input(large, currency: "EUR", locale: "de_DE"))
        for _ in 0..<100 { model.update(input([btc], wallet: "obsolete-wallet")) }
        model.update(input([eth], wallet: "final-wallet", currency: "JPY", locale: "ja_JP"))
        precondition(model.rows.isEmpty, "Never expose another wallet while switching")
        try await waitUntil { model.rows.count == 1 && model.rows.first?.id == eth.id }
        precondition(model.walletID == "final-wallet" && model.rows.first?.fiat.contains("$") == false)
        let finalRows = model.rows
        model.update(input(large, wallet: "final-wallet"))
        model.cancel()
        try await Task.sleep(for: .milliseconds(50))
        precondition(model.rows == finalRows, "Cancelled work must not publish")
        model.update(input([updatedBTC], wallet: "resumed-wallet"))
        try await waitUntil { model.rows.first?.id == updatedBTC.id }
        model.cancel()
        let obsolete = try await model.prepare(input([eth], wallet: "obsolete-wallet"))
        precondition(model.walletID == "resumed-wallet", "Preparation must not replace the displayed wallet before commit")
        model.cancel()
        do { try model.publish(obsolete); preconditionFailure("Cancelled preparation published") }
        catch is CancellationError { }
        model.reset()
        precondition(!model.hasPrepared && model.rows.isEmpty && model.walletID == nil, "Reset removes retained presentation data")
        print("PASS: exact formatting, cached updates, timestamp-only suppression, filtering, locale/currency changes, cache eviction, progressive chain updates, responsive MainActor, burst coalescing, wallet switches and cancellation")
    }
}
