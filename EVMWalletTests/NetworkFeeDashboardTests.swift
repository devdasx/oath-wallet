import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor @Suite(.serialized)
struct NetworkFeeDashboardTests {
    @Test
    func dashboardCoversEverySupportedNetworkWithUsableDefaults() throws {
        let model = NetworkFeeDashboardModel()
        let entries = model.entries()
        #expect(entries.count == ReceiveNetworkCatalog.catalogNetworkIdentifiers.count)
        #expect(Set(entries.map(\.id)) == SendNetworkFeeAPIClient.supportedQuoteNetworkIDs)
        for entry in entries {
            #expect(entry.source == .fallback)
            for preset in [SendNetworkFeePreset.economy, .standard, .fastest] {
                let tier = try #require(entry.quote.tier(for: preset))
                let display = NetworkFeeDashboardValue(network: entry.network, tier: tier)
                #expect(!display.value.isEmpty && !display.unit.isEmpty)
            }
        }
        #expect(model.entries(search: "  BTC ").map(\.id) == ["bitcoin"])
        #expect(model.entries(search: "NoSuchNetwork").isEmpty)
    }

    @Test
    func formattingDoesNotConfuseRatesWithBudgetsOrPriorityWithTotalFees() throws {
        let expected: [(String, String, String)] = [
            ("eth", "Gwei", "network_fees.rate"),
            ("bitcoin", "sat/vB", "network_fees.rate"),
            ("litecoin", "litoshi/vB", "network_fees.rate"),
            ("dogecoin", "koinu/vB", "network_fees.rate"),
            ("solana", "µ-lamports/CU", "network_fees.priority"),
            ("tron", "sun/energy", "network_fees.rate"),
            ("sui", "SUI", "network_fees.budget"),
            ("near", "NEAR", "network_fees.budget"),
            ("aptos", "APT", "network_fees.budget"),
            ("xrp", "XRP", "network_fees.estimate"),
            ("stellar", "XLM", "network_fees.estimate")
        ]
        for (id, unit, kind) in expected {
            let network = try #require(ReceiveNetworkCatalog.catalogNetwork(for: id))
            let quote = try SendNetworkFeeAPIClient.defaultQuote(for: id)
            let tier = try #require(quote.tier(for: .standard))
            let display = NetworkFeeDashboardValue(network: network, tier: tier)
            #expect(display.unit == unit)
            #expect(display.kindKey == kind)
        }
    }

    @Test
    func cacheClassificationUsesTheSampleTimeAndDistinguishesFailedRefreshes() throws {
        let now = Date()
        let network = try #require(ReceiveNetworkCatalog.catalogNetwork(for: "bitcoin"))
        let quote = try SendNetworkFeePrefetchTests.quote("bitcoin", now: now)
        var record = WalletNetworkFeeRecord(networkID: network.id,
            payload: String(decoding: try JSONEncoder().encode(quote), as: UTF8.self),
            lastAttemptAt: now.timeIntervalSince1970, lastAttemptSucceeded: true)
        #expect(try NetworkFeeDashboardEntry.make(network: network, record: record, now: now).source == .updated)
        #expect(try NetworkFeeDashboardEntry.make(network: network, record: record, now: now.addingTimeInterval(31)).source == .cached)
        record.lastAttemptSucceeded = false
        #expect(try NetworkFeeDashboardEntry.make(network: network, record: record, now: now).source == .cached)
        #expect(try NetworkFeeDashboardEntry.make(network: network, record: record, now: now.addingTimeInterval(901)).source == .fallback)
    }

    @Test
    func currencyConversionPreservesTheQuotedUnitForEveryFeeModel() throws {
        let cases: [(String, SendNetworkFeeQuoteModel, String, String, String)] = [
            ("eth", .evmEIP1559, "10000000000", "3000", "$0.00003/gas"),
            ("bsc", .evmLegacy, "1000000000", "600", "<$0.000001/gas"),
            ("arc", .evmEIP1559, "60000000000", "0.99", "<$0.000001/gas"),
            ("bitcoin", .utxoPerVByte, "25", "60000", "$0.015/vB"),
            (BitcoinFamilyChain.bitcoinCash.networkID, .utxoPerVByte, "2", "300", "$0.000006/vB"),
            ("litecoin", .utxoPerVByte, "1", "100", "$0.000001/vB"),
            ("dogecoin", .utxoPerVByte, "100000", "0.1", "$0.0001/vB"),
            ("solana", .solanaPriority, "10000000", "200", "$0.000002/CU"),
            ("tron", .tronProtocol, "100", "0.25", "$0.000025/energy"),
            ("ton", .tonProtocol, "50000000", "3.5", "$0.175"),
            ("sui", .suiProtocol, "1500000", "3", "$0.0045"),
            ("aptos", .aptosProtocol, "3000000", "8", "$0.24"),
            ("near", .nearProtocol, "10000000000000000000000", "3", "$0.03"),
            ("xrp", .xrpProtocol, "12", "0.5", "$0.000006"),
            ("stellar", .stellarProtocol, "100", "0.1", "$0.000001")
        ]
        for (id, model, atomic, price, expected) in cases {
            let network = try #require(ReceiveNetworkCatalog.catalogNetwork(for: id))
            let tier = SendNetworkFeeTier(preset: .standard, model: model, primaryValue: atomic, secondaryValue: nil)
            let value = NetworkFeeDashboardValue(network: network, tier: tier)
            #expect(value.localCurrencyValue(nativeUnitUSDPrice: Decimal(string: price),
                                            using: WalletCurrencyContext(code: "USD", ratePerUSD: 1)) == expected)
            let asset = NetworkFeeDashboardModel.nativePriceAsset(for: network)
            #expect(asset.id == "\(id):native")
            #expect(asset.decimals == SendNetworkFeeEstimator.nativeDecimals(for: model))
            #expect(AssetPriceClient.coinGeckoMarketID(for: asset) != nil)
        }
    }

    @Test
    func currencyFormattingUsesUpToSixPlacesAndNeverRoundsPositiveDustToZero() throws {
        let usd = WalletCurrencyContext(code: "USD", ratePerUSD: 1)
        let cases = [
            ("0", "$0.00"), ("0.12", "$0.12"), ("4.5678918", "$4.567892"),
            ("0.000001", "$0.000001"), ("0.000000999999", "<$0.000001"),
            ("0.00000000001", "<$0.000001"), ("1234567.8", "$1,234,567.80")
        ]
        for (input, expected) in cases {
            #expect(EnglishNumbers.networkFeeDashboardCurrency(try #require(Decimal(string: input)), using: usd) == expected)
        }
        let jod = WalletCurrencyContext(code: "JOD", ratePerUSD: try #require(Decimal(string: "0.709")))
        #expect(EnglishNumbers.networkFeeDashboardCurrency(3, using: jod)
                == EnglishNumbers.notificationCurrency("2.127", currencyCode: "JOD"))
        let jpy = WalletCurrencyContext(code: "JPY", ratePerUSD: 150)
        #expect(EnglishNumbers.networkFeeDashboardCurrency(try #require(Decimal(string: "0.0000001")), using: jpy)
                == EnglishNumbers.notificationCurrency("0.000015", currencyCode: "JPY"))
        #expect(EnglishNumbers.networkFeeDashboardCurrency(-1, using: usd) == nil)
        #expect(EnglishNumbers.networkFeeDashboardCurrency(.nan, using: usd) == nil)
        #expect(EnglishNumbers.networkFeeDashboardCurrency(1, using: .init(code: "USD", ratePerUSD: 0)) == nil)
        #expect(EnglishNumbers.networkFeeDashboardCurrency(1, using: .init(code: "USD", ratePerUSD: .nan)) == nil)
        #expect(EnglishNumbers.networkFeeDashboardCurrency(1, using: .init(code: "INVALID", ratePerUSD: 1)) == nil)
    }

    @Test
    func missingOrInvalidNativePricesDoNotBecomeZeroCurrencyFees() throws {
        let network = try #require(ReceiveNetworkCatalog.catalogNetwork(for: "bitcoin"))
        let tier = try #require(SendNetworkFeeAPIClient.defaultQuote(for: "bitcoin").tier(for: .standard))
        let value = NetworkFeeDashboardValue(network: network, tier: tier)
        let prices: [Decimal?] = [nil, 0, -1, .nan]
        for price in prices {
            #expect(value.localCurrencyValue(nativeUnitUSDPrice: price,
                                            using: .init(code: "USD", ratePerUSD: 1)) == nil)
        }
    }

    @Test
    func completedNetworksReachDatabaseSendAndDashboardWhileAnotherProviderIsStillWaiting() async throws {
        let database = try WalletDatabase.temporary()
        let saved = try SendNetworkFeePrefetchTests.quote("aptos", now: Date().addingTimeInterval(-90))
        try await SendNetworkFeePrefetchTests.save(saved, in: database)
        let gate = DashboardProviderGate()
        let repository = SendNetworkFeeQuoteRepository { id in
            if id == "aptos" { await gate.pause() }
            return try SendNetworkFeePrefetchTests.quote(id)
        }
        let model = NetworkFeeDashboardModel(repository: repository) { asset in
            if asset.id == "aptos:native" { await gate.pause() }
            return Self.fixturePrice(asset)
        }
        let observation = Task { await model.observe(database: database) }
        let refresh = Task { await model.refresh(database: database, force: true) }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            await gate.release()
        }
        defer {
            observation.cancel()
            timeout.cancel()
            Task { await gate.release(); await refresh.value }
        }
        for _ in 0..<150 {
            if model.records["arc"]?.lastAttemptSucceeded == true && model.nativeUSDPrices["eth"] == 100 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.isRefreshing)
        let durable = try #require(try await database.networkFeeRecord(for: "arc"))
        #expect(durable.lastAttemptSucceeded)
        #expect(model.records["arc"] == durable)
        #expect(try await repository.quote(for: "arc", database: database) == durable.quote)
        #expect(try await database.networkFeeRecord(for: "aptos")?.quote == saved)
        #expect(model.nativeUSDPrices["aptos"] == nil)
        #expect(model.nativeUSDPrices["eth"] == 100)
        await gate.release()
        await refresh.value
        #expect(!model.isRefreshing)
        #expect(try await database.networkFeeRecord(for: "aptos")?.quote?.fetchedAt != saved.fetchedAt)
        #expect(model.nativeUSDPrices["aptos"] == 100)
    }

    @Test
    func savedNativePricesSurviveARefreshFailureWithoutUsingAnotherAssetsQuote() async throws {
        let database = try WalletDatabase.temporary()
        let repository = SendNetworkFeeQuoteRepository { try SendNetworkFeePrefetchTests.quote($0) }
        // First load establishes public native-coin metadata, even without any wallets.
        let first = NetworkFeeDashboardModel(repository: repository, priceLoader: { Self.fixturePrice($0) })
        await first.refresh(database: database)
        let asset = try #require(ReceiveNetworkCatalog.catalogNetwork(for: "bitcoin"))
        let price = Self.fixturePrice(NetworkFeeDashboardModel.nativePriceAsset(for: asset))
        try await database.saveAssetUSDPrice(price)
        let next = NetworkFeeDashboardModel(repository: repository) { _ in
            // A well-formed positive price belonging to the wrong asset must be ignored.
            AssetUSDPrice(assetID: "unrelated:native", price: 99, provider: "fixture", observedAt: Date())
        }
        await next.refresh(database: database, force: true)
        #expect(next.nativeUSDPrices["bitcoin"] == 100)
        #expect(next.nativeUSDPrices["eth"] == nil)
        #expect(try await database.pool.read { try DBAccountAssetRecord.fetchCount($0) } == 0)
    }

    nonisolated private static func fixturePrice(_ asset: WalletAsset) -> AssetUSDPrice {
        AssetUSDPrice(assetID: asset.id, price: 100, provider: "fixture-price", observedAt: Date())
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func nativeDashboardRowsAndDetailNavigation(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let repository = SendNetworkFeeQuoteRepository { try SendNetworkFeePrefetchTests.quote($0) }
        await repository.refresh(database: database)
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                NetworkFeeDashboardView(database: database, repository: repository, priceLoader: { Self.fixturePrice($0) })
                    .navigationDestination(for: WalletSettingsSearchRoute.self) { route in
                        if case let .networkFeeDetails(id) = route {
                            NetworkFeeDetailsView(database: database, networkID: id, repository: repository,
                                                  priceLoader: { Self.fixturePrice($0) })
                        }
                    }
            }
            .environment(\.walletCurrencyContext, WalletCurrencyContext(
                code: layout.direction == .rightToLeft ? "JOD" : "USD", ratePerUSD: layout.direction == .rightToLeft ? 0.709 : 1
            ))
        }
        defer { host.close() }
        let list = try await host.list {
            $0.numberOfSections == 2 && $0.numberOfItems(inSection: 1) == ReceiveNetworkCatalog.catalogNetworkIdentifiers.count
        }
        let first = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        #expect(first.bounds.height >= 44)
        #expect(first.bounds.width <= host.rootView.bounds.width)
        if layout.textSize.isAccessibilitySize { #expect(first.bounds.height > 90) }
        let last = try await host.cell(at: IndexPath(item: ReceiveNetworkCatalog.catalogNetworkIdentifiers.count - 1, section: 1), in: list)
        #expect(last.bounds.height >= 44)
        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        host.rootView.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        try capture(host, name: "dashboard-\(layout)")
        try await host.selectNavigationRow(IndexPath(item: 0, section: 1), in: list)
        for _ in 0..<50 {
            host.rootView.layoutIfNeeded()
            if host.navigationController?.viewControllers.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let navigation = try #require(host.navigationController)
        #expect(navigation.viewControllers.count == 2)
        try await Task.sleep(for: .milliseconds(800))
        let details = try #require(navigation.topViewController?.view)
        let detailLists = SendEntryUIProbe.views(UICollectionView.self, in: details)
        let detailList = try #require(detailLists.first)
        #expect(detailList.numberOfSections == 2)
        #expect(detailList.numberOfItems(inSection: 1) == 3)
        try capture(host, name: "details-\(layout)")
    }

    private func capture(_ host: NativeListTestHost, name: String) throws {
        let renderer = UIGraphicsImageRenderer(bounds: host.rootView.bounds)
        let data = renderer.pngData { _ in host.rootView.drawHierarchy(in: host.rootView.bounds, afterScreenUpdates: true) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oath-network-fees-\(name).png")
        try data.write(to: url)
        print("Network fee layout capture: \(url.path)")
    }
}

private actor DashboardProviderGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

#if LIVE_MAINNET_TESTS
@Suite(.serialized)
struct LiveNetworkFeeCacheTests {
    @MainActor @Test
    func publicNativePriceRefreshPersistsUsableCurrencyEstimates() async throws {
        let database = try WalletDatabase.temporary()
        let repository = SendNetworkFeeQuoteRepository { try SendNetworkFeePrefetchTests.quote($0) }
        let model = NetworkFeeDashboardModel(repository: repository)
        await model.refresh(database: database, force: true)
        var priced: [String] = []
        var unavailable: [String] = []
        for id in ReceiveNetworkCatalog.catalogNetworkIdentifiers {
            guard let price = model.nativeUSDPrices[id] else { unavailable.append(id); continue }
            let cached = try #require(try await database.cachedAssetUSDPrice(assetID: "\(id):native"))
            #expect(cached.price == price)
            let network = try #require(ReceiveNetworkCatalog.catalogNetwork(for: id))
            let tier = try #require(SendNetworkFeeAPIClient.defaultQuote(for: id).tier(for: .standard))
            let value = NetworkFeeDashboardValue(network: network, tier: tier)
            #expect(value.localCurrencyValue(nativeUnitUSDPrice: price, using: .init(code: "JOD", ratePerUSD: 0.709)) != nil)
            priced.append(id)
        }
        #expect(priced.contains("bitcoin") && priced.contains("eth") && priced.contains("arc"))
        print("Live native fee currencies: priced=\(priced.joined(separator: ",")); unavailable=\(unavailable.joined(separator: ","))")
    }

    @Test
    func actualReadOnlyProviderRefreshPersistsAllNetworksForSending() async throws {
        let database = try WalletDatabase.temporary()
        let repository = SendNetworkFeeQuoteRepository()
        await repository.refresh(database: database, force: true)
        var liveNetworks: [String] = []
        var fallbackNetworks: [String] = []
        for networkID in ReceiveNetworkCatalog.catalogNetworkIdentifiers {
            let row = try #require(try await database.networkFeeRecord(for: networkID))
            let quote = try await repository.quote(for: networkID, database: database)
            #expect(SendNetworkFeeAPIClient.isValidForSessionReuse(quote, expectedNetworkID: networkID))
            if row.lastAttemptSucceeded { liveNetworks.append(networkID) }
            else { fallbackNetworks.append(networkID) }
        }
        #expect(!liveNetworks.isEmpty, "At least one real provider must respond to validate the live path")
        print("Mainnet fee cache: live=\(liveNetworks.sorted().joined(separator: ",")); defaults=\(fallbackNetworks.sorted().joined(separator: ","))")
    }
}
#endif
