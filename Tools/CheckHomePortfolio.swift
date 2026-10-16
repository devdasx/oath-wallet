import Foundation
import Observation
import OathDatabase

@main struct CheckHomePortfolio {
    static func holding(_ index: Int, amount: String = "123456789", timestamp: Double = 1,
                        network: String = "ethereum", activity: Int = 0) throws -> Holding {
        let json: [String: Any] = ["accountID": "fixture-" + network, "networkID": network,
            "address": "public-fixture", "assetID": "asset-\(index)", "reference": "token-\(index)",
            "name": "Token \(index)", "symbol": "T\(index)", "decimals": 8, "amountAtomic": amount,
            "balanceObservedAt": timestamp, "usdPrice": "12.5", "exchangeRate": "1",
            "priceObservedAt": timestamp, "priceSource": "fixture", "transactionCount": activity]
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
        let builder = OathHomePortfolioBuilder()
        let rows = try (0..<1_000).map { try holding($0) }
        let source = input(rows)
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

        var filter = PortfolioFilter(); filter.sort = .nameDescending
        let filtered = try await builder.build(input(changed, filter: filter, query: "Token 50"))
        precondition(filtered.formattedRowCount == 0, "Filtering should reuse formatted rows")
        precondition(filtered.rows.map(\.id) == filter.applying(to: changed, currency: "USD",
            locale: Locale(identifier: "en_US")).map(\.id))
        precondition(filtered.searchRows.map(\.id) == changed.filter {
            ($0.name + " " + $0.symbol + " " + $0.networkID).localizedStandardContains("Token 50")
        }.map(\.id))
        let localized = try await builder.build(input(changed, currency: "JPY", locale: "ja_JP"))
        precondition(localized.formattedRowCount == rows.count && localized.rows[50].fiat != incremental.rows[50].fiat)
        let switched = try await builder.build(input(changed, wallet: "another-wallet"))
        precondition(switched.formattedRowCount == rows.count)
        _ = try await builder.build(input([rows[0]]))
        let bounded = try await builder.build(input([rows[0], rows[1]]))
        precondition(bounded.formattedRowCount == 1, "Rows removed from the wallet must leave the cache")

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
