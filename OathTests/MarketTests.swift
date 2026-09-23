import Foundation
import Testing
import SwiftUI
import UIKit
@testable import Aperture

@Suite struct MarketTests {
    private var bitcoin: MarketCoin { MarketCoin.all.first { $0.id == "bitcoin" }! }
    private func quote(_ price: Double, at date: Date = Date()) -> MarketQuote {
        MarketQuote(price: price, change24h: 2, marketCap: 1000, volume: 30, high24h: 110, low24h: 90, supply: 10, rank: 1, image: nil, updatedAt: date, source: "Fixture")
    }
    @Test func priceOnlyRefreshPreservesChangeWithoutRefreshingItsAge() throws {
        let now = Date().addingTimeInterval(-1200)
        let rich = quote(100, at: now)
        func priceOnly(at date: Date) -> MarketQuote {
            MarketQuote(price: 101, change24h: nil, marketCap: nil, volume: nil,
                high24h: nil, low24h: nil, supply: nil, rank: nil, image: nil,
                updatedAt: date, source: "Price only")
        }
        var record = MarketRecord(quote: rich)
        record.merge(MarketRecord(quote: priceOnly(at: now.addingTimeInterval(60))))
        #expect(record.quote?.price == 101)
        #expect(record.quote?.change24h == 2)
        #expect(record.quote?.changeUpdatedAt == now)
        #expect(record.statistics?.marketCap == 1000)
        let restored = try JSONDecoder().decode(MarketRecord.self, from: JSONEncoder().encode(record))
        #expect(restored.quote?.changeUpdatedAt == now)
        // An older rich provider response must also enrich a newer price-only quote.
        var reverse = MarketRecord(quote: priceOnly(at: now.addingTimeInterval(60)))
        reverse.merge(MarketRecord(quote: rich))
        #expect(reverse.quote?.change24h == 2)
        #expect(reverse.quote?.price == 101)
        record.merge(MarketRecord(quote: priceOnly(at: now.addingTimeInterval(1000))))
        #expect(record.quote?.change24h == nil)
    }
    @Test(arguments: [MarketFixtureTransport.Mode.llamaChange, .priceOnlyThenCoinbase, .coinlore])
    fileprivate func priceSuccessDoesNotStopChangeFallback(mode: MarketFixtureTransport.Mode) async {
        let transport = MarketFixtureTransport(mode: mode)
        let quotes = await MarketProvider(transport: transport).quotes(for: [bitcoin])
        #expect(abs((quotes[bitcoin.id]?.change24h ?? -999) - 10) < 0.00001)
        #expect(quotes[bitcoin.id]?.isValid == true)
    }
    @Test func catalogCoversEveryNativeNetworkWithoutDuplicateCoins() {
        #expect(Set(MarketCoin.all.map(\.id)).count == MarketCoin.all.count)
        let mapped = Set(MarketCoin.all.flatMap(\.networks))
        for network in ReceiveNetworkCatalog.all { #expect(mapped.contains(network.blockchain), "Missing \(network.id)") }
    }
    @Test func tokenActionsRequireExactContractAndNetwork() {
        let coin = MarketCoin.all.first { $0.id == "tether" }!
        let wrong = WalletAsset(id: "fake", name: "Tether", symbol: "USDT", logoSource: .token(blockchain: .ethereum, checksummedContractAddress: "0xdead", logoURL: nil, origin: .catalog), network: .ethereum, balance: 0, fiatValue: 0)
        #expect(coin.asset(in: [wrong]) == nil)
        let correct = WalletAsset(id: "real", name: "Tether", symbol: "USDT", logoSource: .token(blockchain: .ethereum, checksummedContractAddress: coin.ethereumContract!, logoURL: nil, origin: .catalog), network: .ethereum, balance: 0, fiatValue: 0)
        #expect(coin.asset(in: [wrong, correct])?.id == "real")
        #expect(MarketCoin.all.first { $0.id == "cardano" }!.asset(in: [correct]) == nil)
    }
    @Test func nativeActionsRespectAvailableWalletNetworks() {
        let eth = MarketCoin.all.first { $0.id == "ethereum" }!
        let base = WalletAsset(id: "base:native", name: "Ethereum", symbol: "ETH", logoSource: .nativeCoin(blockchain: .base), network: .base, balance: 0, fiatValue: 0)
        #expect(eth.asset(in: [base])?.network == .base)
        #expect(bitcoin.asset(in: [base]) == nil)
    }
    @Test func oldCloudDataAndInvalidQuotesCannotReplaceNewerCache() {
        let now = Date()
        var record = MarketRecord(quote: quote(100, at: now))
        record.merge(MarketRecord(quote: quote(90, at: now.addingTimeInterval(-60))))
        record.merge(MarketRecord(quote: quote(-1, at: now)))
        record.merge(MarketRecord(quote: quote(.infinity, at: now)))
        #expect(record.quote?.price == 100)
    }
    @Test func chartNormalizationRejectsInvalidFutureAndDuplicateSamples() {
        let now = Date()
        let points = MarketPoint.normalized([
            .init(date: now, price: 2), .init(date: now.addingTimeInterval(-60), price: 1),
            .init(date: now, price: 3), .init(date: now, price: -1),
            .init(date: now.addingTimeInterval(1000), price: 4),
            .init(date: now.addingTimeInterval(-1000), price: 5)
        ], since: now.addingTimeInterval(-100))
        #expect(points.map(\.price) == [1, 3])
    }
    @Test func realDatabaseRoundTripsQuotesInformationAndAllRanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        var record = MarketRecord(quote: quote(123, at: now), info: .init(description: "Real cached description", website: "https://bitcoin.org", source: "fixture", updatedAt: now))
        for range in MarketRange.allCases { record.histories[range.rawValue] = .init(points: [.init(date: now, price: 123)], source: "fixture", updatedAt: now) }
        try await MarketDatabase(directory: directory).save([bitcoin.id: record])
        let restored = try await MarketDatabase(directory: directory).load()
        #expect(restored[bitcoin.id]?.quote == record.quote)
        #expect(restored[bitcoin.id]?.info?.description == record.info?.description)
        #expect(restored[bitcoin.id]?.histories.count == 4)
    }
    @Test func priceFallsBackToCoinbaseAfterBothAggregatorsFail() async {
        let transport = MarketFixtureTransport(mode: .coinbase)
        let values = await MarketProvider(transport: transport).quotes(for: [bitcoin])
        #expect(values[bitcoin.id]?.source == "Coinbase")
        #expect(values[bitcoin.id]?.price == 110)
        #expect(abs((values[bitcoin.id]?.change24h ?? 0) - 10) < 0.00001)
        let paths = await transport.paths
        #expect(paths.contains { $0.contains("coinpaprika") })
    }
    @Test @MainActor func totalProviderFailureKeepsPersistedPriceVisible() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = MarketDatabase(directory: directory)
        defer { Task { await database.close(); try? FileManager.default.removeItem(at: directory) } }
        try await database.save([bitcoin.id: MarketRecord(quote: quote(123))])
        let store = MarketStore(database: database, provider: MarketProvider(transport: MarketFixtureTransport(mode: .failure)), cloudEnabled: false)
        await store.refresh(coins: [bitcoin])
        #expect(store.records[bitcoin.id]?.quote?.price == 123)
        #expect(try await database.load()[bitcoin.id]?.quote?.price == 123)
    }
    @Test func annualCoinbaseHistoryUsesTwoBoundedPages() async throws {
        let transport = MarketFixtureTransport(mode: .candles)
        let result = await MarketProvider(transport: transport).history(for: bitcoin, range: .year)
        #expect(result?.source == "Coinbase")
        let urls = await transport.paths.compactMap(URL.init(string:)).filter { $0.path.hasSuffix("candles") }
        #expect(urls.count == 2)
        for url in urls {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let start = ISO8601DateFormatter().date(from: items.first { $0.name == "start" }!.value!)!
            let end = ISO8601DateFormatter().date(from: items.first { $0.name == "end" }!.value!)!
            #expect(end.timeIntervalSince(start) <= 299 * 86400)
        }
        #expect((result?.points.count ?? 0) >= 2)
    }
    @Test func historyFallsBackToKrakenAfterCoinbaseFailure() async {
        let result = await MarketProvider(transport: MarketFixtureTransport(mode: .kraken)).history(for: bitcoin, range: .day)
        #expect(result?.source == "Kraken")
        #expect(result?.points.map(\.price) == [100, 110])
    }
    @Test func descriptionFallsBackToCoinPaprika() async {
        let result = await MarketProvider(transport: MarketFixtureTransport(mode: .info)).info(for: bitcoin)
        #expect(result?.description == "Bitcoin description")
        #expect(result?.website == "https://bitcoin.org")
    }
}

private actor MarketFixtureTransport: MarketTransport {
    enum Mode { case failure, coinbase, candles, kraken, info, throttled, llamaChange, priceOnlyThenCoinbase, coinlore }
    let mode: Mode
    var paths: [String] = []
    init(mode: Mode) { self.mode = mode }
    func data(from url: URL) async throws -> Data {
        paths.append(url.absoluteString)
        let now = Date().timeIntervalSince1970
        let object: Any
        switch mode {
        case .throttled where url.host == "api.coingecko.com":
            throw MarketHTTPFailure(status: 429, retryAfter: 120)
        case .llamaChange where url.path.contains("/prices/current/"), .priceOnlyThenCoinbase where url.path.contains("/prices/current/"):
            object = ["coins": ["coingecko:bitcoin": ["price": 110, "timestamp": now]]] as [String: Any]
        case .llamaChange where url.path.contains("/percentage/"):
            object = ["coins": ["coingecko:bitcoin": 10]]
        case .coinlore where url.host == "api.coinlore.net":
            object = [["id": "90", "price_usd": "110", "percent_change_24h": "10"]]
        case .coinbase where url.path.hasSuffix("stats"), .priceOnlyThenCoinbase where url.path.hasSuffix("stats"):
            object = ["open": "100", "last": "110", "high": "120", "low": "95"]
        case .candles where url.path.hasSuffix("candles"):
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let start = ISO8601DateFormatter().date(from: items.first { $0.name == "start" }!.value!)!.timeIntervalSince1970
            object = [[start + 86400, 90, 120, 100, 110, 30], [start + 172800, 95, 125, 110, 115, 40]]
        case .kraken where url.host == "api.kraken.com":
            object = ["error": [], "result": ["XXBTZUSD": [[now - 3600, "90", "110", "95", "100"], [now - 600, "100", "115", "100", "110"]], "last": now]] as [String: Any]
        case .info where url.host == "api.coinpaprika.com":
            object = ["description": "Bitcoin description", "links": ["website": ["https://bitcoin.org"]]] as [String: Any]
        default: throw URLError(.notConnectedToInternet)
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

@Suite(.serialized) @MainActor
struct MarketKeyboardLayoutTests {
    @Test(arguments: [false, true], [LayoutDirection.leftToRight, .rightToLeft])
    func backgroundContinuesBehindKeyboard(dark: Bool, direction: LayoutDirection) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = MarketDatabase(directory: directory)
        defer { Task { await database.close(); try? FileManager.default.removeItem(at: directory) } }
        let coin = try #require(MarketCoin.all.first { $0.id == "bitcoin" })
        let now = Date()
        let quote = MarketQuote(price: 81380, change24h: 2.4, marketCap: 1_600_000_000_000,
            volume: 30_000_000_000, high24h: 82000, low24h: 79800, supply: 20_000_000,
            rank: 1, image: nil, updatedAt: now, source: "Fixture")
        try await database.save([coin.id: MarketRecord(quote: quote)])
        let store = MarketStore(database: database,
            provider: MarketProvider(transport: MarketFixtureTransport(mode: .failure)), cloudEnabled: false)
        await store.loadCache()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = try NativeListTestHost(size: scene.coordinateSpace.bounds.size) {
            NavigationStack { MarketDetailView(coin: coin, store: store) }
                .walletTextInputConfiguration(direction)
                .environment(\.layoutDirection, direction)
                .environment(\.colorScheme, dark ? .dark : .light)
        }
        defer { host.close() }
        host.rootView.window?.overrideUserInterfaceStyle = dark ? .dark : .light
        try await SendEntryUIProbe.wait(in: host.rootView) {
            !SendEntryUIProbe.views(UITextField.self, in: host.rootView).isEmpty
        }
        let field = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first)
        #expect(field.becomeFirstResponder())
        try await SendEntryUIProbe.wait(in: host.rootView) {
            field.isFirstResponder && host.rootView.keyboardLayoutGuide.layoutFrame.height > 150
        }
        // Wait for the real software keyboard's transition, then sample the app
        // surface underneath it. The keyboard is in a separate system window.
        try await Task.sleep(for: .milliseconds(600))
        host.rootView.layoutIfNeeded()
        let keyboard = host.rootView.keyboardLayoutGuide.layoutFrame
        let accessory = try #require(field.inputAccessoryView as? WalletKeyboardAccessoryView,
            "Accessory: \(String(describing: field.inputAccessoryView)); input: \(String(describing: field.inputView))")
        // The hosted app has its own root policy; the fixture explicitly sets
        // the requested direction after all global editing observers settle.
        WalletKeyboardAccessory.install(on: field, layoutDirection: direction)
        accessory.layoutIfNeeded()
        #expect(accessory.window != nil)
        #expect(accessory.bounds.height >= 64)
        #expect(abs(accessory.bounds.maxY - accessory.confirmButton.frame.maxY - 12) < 1)
        #expect(accessory.confirmButton.bounds.width >= 44)
        #expect(accessory.confirmButton.configuration?.image != nil)
        #expect(accessory.confirmButton.configuration?.title == nil)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: host.rootView.bounds, format: format).image { _ in
            host.rootView.drawHierarchy(in: host.rootView.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "market-keyboard-\(dark ? "dark" : "light")-\(direction == .rightToLeft ? "rtl" : "ltr").png")
        try image.pngData()?.write(to: url)
        print("MARKET_KEYBOARD_PREVIEW=\(url.path)")
        // Briefly keep the real keyboard open for an external simulator
        // screenshot; drawHierarchy above validates the app canvas separately.
        try await Task.sleep(for: .seconds(2))
        let point = CGPoint(x: 3, y: min(keyboard.minY + 24, host.rootView.bounds.maxY - 40))
        let pixel = try #require(image.cgImage?.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let expected = UIColor(WalletTheme.groupedBackground).resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #expect(expected.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        for (index, value) in [red, green, blue, alpha].enumerated() {
            #expect(abs(CGFloat(bytes[index]) / 255 - value) < 0.025,
                "Unpainted keyboard region at \(point), channel \(index): \(bytes[index]) vs \(value * 255)")
        }
        #expect(field.keyboardType == .decimalPad)
        field.insertText("123")
        #expect(field.text?.contains("123") == true)
        accessory.confirmButton.sendActions(for: .touchUpInside)
        try await SendEntryUIProbe.wait(in: host.rootView) { !field.isFirstResponder }
        #expect(field.text?.contains("123") == true)
    }
}

@Suite(.serialized) @MainActor
struct MarketScreenTests {
    @Test(arguments: [NativeListTestLayout.phone, .largeTextRTL, .pad])
    func supportedCoinHasNoTransferActions(layout: NativeListTestLayout) async throws {
        try await screen(layout: layout, supported: true)
    }
    @Test func unsupportedCoinHasNoTransferActions() async throws {
        try await screen(layout: .phone, supported: false)
    }
    private func screen(layout: NativeListTestLayout, supported: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = MarketDatabase(directory: directory)
        defer { Task { await database.close(); try? FileManager.default.removeItem(at: directory) } }
        let coin = MarketCoin.all.first { $0.id == (supported ? "bitcoin" : "cardano") }!
        let now = Date()
        let points = (0..<96).map { i in MarketPoint(date: now.addingTimeInterval(Double(i - 95) * 900), price: 81000 + sin(Double(i) / 8) * 300 + Double(i) * 4) }
        let quote = MarketQuote(price: 81380, change24h: 2.4, marketCap: 1_600_000_000_000, volume: 30_000_000_000, high24h: 82000, low24h: 79800, supply: 20_000_000, rank: 1, image: nil, updatedAt: now, source: "Fixture")
        let info = MarketInfo(description: "A decentralized digital currency secured by a public network.", website: "https://bitcoin.org", source: "Fixture", updatedAt: now)
        try await database.save([coin.id: MarketRecord(quote: quote, info: info, histories: [MarketRange.day.rawValue: MarketHistory(points: points, source: "Fixture", updatedAt: now)])])
        let store = MarketStore(database: database, provider: MarketProvider(transport: MarketFixtureTransport(mode: .failure)), cloudEnabled: false)
        await store.loadCache()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                MarketDetailView(coin: coin, store: store)
            }
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("markets.detail.\(coin.id)", in: host.rootView) != nil
        }
        if layout == .phone && supported {
                let image = UIGraphicsImageRenderer(bounds: host.rootView.bounds).image { _ in host.rootView.drawHierarchy(in: host.rootView.bounds, afterScreenUpdates: true) }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("aperture-markets-detail.png")
                try image.pngData()?.write(to: url)
                print("MARKETS_PREVIEW=\(url.path)")
            }
        #expect(SendEntryUIProbe.element("markets.send", in: host.rootView) == nil)
        #expect(SendEntryUIProbe.element("markets.receive", in: host.rootView) == nil)

        if layout == .phone {
            let field = try #require(SendEntryUIProbe.views(UITextField.self, in: host.rootView).first)
            #expect(field.becomeFirstResponder())
            try await SendEntryUIProbe.wait(in: host.rootView) {
                SendEntryUIProbe.element("markets.converter.dismiss-keyboard", in: host.rootView) != nil
            }
            #expect(SendEntryUIProbe.element("markets.send", in: host.rootView) == nil)
            #expect(SendEntryUIProbe.element("markets.receive", in: host.rootView) == nil)
            try SendEntryUIProbe.activate("markets.converter.swap", in: host.rootView)
            try SendEntryUIProbe.activate("markets.converter.dismiss-keyboard", in: host.rootView)
            try await SendEntryUIProbe.wait(in: host.rootView) {
                SendEntryUIProbe.element("markets.converter.dismiss-keyboard", in: host.rootView) == nil
            }
            #expect(!field.isFirstResponder)
            #expect(SendEntryUIProbe.element("markets.send", in: host.rootView) == nil)
            #expect(SendEntryUIProbe.element("markets.receive", in: host.rootView) == nil)
        }
        #expect(SendEntryUIProbe.views(UIActivityIndicatorView.self, in: host.rootView).isEmpty)
    }
}


extension MarketTests {
    @Test func rateLimitSuppressesFurtherCallsToThatHost() async {
        let transport = MarketFixtureTransport(mode: .throttled)
        let provider = MarketProvider(transport: transport)
        _ = await provider.quotes(for: [bitcoin])
        _ = await provider.quotes(for: [bitcoin])
        let paths = await transport.paths
        #expect(paths.filter { $0.contains("api.coingecko.com") }.count == 1)
        #expect(paths.filter { $0.contains("api.coinpaprika.com") }.count == 2)
    }
    @Test func aSpotOnlyFallbackPreservesCachedStatistics() {
        let now = Date()
        var record = MarketRecord(quote: quote(100, at: now.addingTimeInterval(-60)))
        let fallback = MarketQuote(price: 110, change24h: nil, marketCap: nil, volume: nil, high24h: nil, low24h: nil, supply: nil, rank: nil, image: nil, updatedAt: now, source: "Coinbase")
        record.merge(MarketRecord(quote: fallback))
        #expect(record.quote?.price == 110)
        #expect(record.statistics?.marketCap == 1000)
        #expect(record.statistics?.source == "Fixture")
    }
    @Test func appResetDoesNotEraseIndependentMarketDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let market = MarketDatabase(directory: directory)
        defer { Task { await market.close(); try? FileManager.default.removeItem(at: directory) } }
        try await market.save([bitcoin.id: MarketRecord(quote: quote(321))])
        let wallet = try WalletDatabase.temporary()
        try await wallet.eraseAllData()
        #expect(try await market.load()[bitcoin.id]?.quote?.price == 321)
    }
}

@Suite(.serialized) @MainActor
struct WalletAssetMarketNavigationTests {
    @Test(arguments: NativeListTestLayout.allCases)
    func assetPriceRowOpensItsMarketAndReturnsToAsset(layout: NativeListTestLayout) async throws {
        let walletDatabase = try WalletDatabase.temporary()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = MarketDatabase(directory: directory)
        defer { Task { await database.close(); try? FileManager.default.removeItem(at: directory) } }
        let asset = WalletAsset(id: "solana:native", name: "Solana", symbol: "SOL",
            logoSource: .nativeCoin(blockchain: .solana), network: .solana,
            balance: Decimal(string: "0.001467532")!, fiatValue: Decimal(string: "0.172052")!)
        let now = Date()
        let quote = MarketQuote(price: 117.24, change24h: 2, marketCap: nil, volume: nil,
            high24h: nil, low24h: nil, supply: nil, rank: nil, image: nil, updatedAt: now, source: "Fixture")
        // The phone case enters from a wallet before Markets has cached a quote.
        let cachedQuote = layout == .phone ? nil : quote
        try await database.save(["solana": MarketRecord(quote: cachedQuote,
            info: MarketInfo(description: "Fixture market", website: nil, source: "Fixture", updatedAt: now),
            histories: [MarketRange.day.rawValue: MarketHistory(points: [
                MarketPoint(date: now.addingTimeInterval(-60), price: 115),
                MarketPoint(date: now, price: 117.24)
            ], source: "Fixture", updatedAt: now)])])
        let transport = MarketFixtureTransport(mode: .failure)
        let store = MarketStore(database: database, provider: MarketProvider(transport: transport, ownedPrice: { requested in
            #expect(requested.id == asset.id)
            return AssetUSDPrice(assetID: requested.id, price: Decimal(string: "117.24")!,
                provider: "Fixture", observedAt: now)
        }), cloudEnabled: false)
        await store.loadCache()
        let suite = "asset-market-navigation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let discovery = MarketDiscoveryStore(defaults: defaults, transport: transport)
        let transactions = (0..<6).map { index in
            WalletTransaction(id: "asset-market-fixture-\(index)", kind: .received(assetSymbol: "SOL"),
                detail: "", time: "", assetLogoSource: .nativeCoin(blockchain: .solana),
                assetAmount: Decimal(string: "0.45")!, assetSymbol: "SOL", fiatValue: 52,
                status: .confirmed)
        }
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                WalletAssetDetailsView(database: walletDatabase, asset: asset,
                    transactions: transactions, isBalanceHidden: false,
                    onSend: { _ in }, onReceive: {}, onScan: { _ in }, onPaste: { _, _ in },
                    marketStore: store, marketDiscovery: discovery)
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 3 && $0.numberOfItems(inSection: 2) == 5 }
        let navigation = try #require(host.navigationController)
        let assetController = try #require(navigation.topViewController)
        #expect(navigation.viewControllers.count == 1)
        let row = IndexPath(item: 0, section: 1)
        _ = try await host.cell(at: row, in: list)
        let image = UIGraphicsImageRenderer(bounds: host.rootView.bounds).image { _ in
            host.rootView.drawHierarchy(in: host.rootView.bounds, afterScreenUpdates: true)
        }
        let preview = FileManager.default.temporaryDirectory.appendingPathComponent("oath-asset-market-\(layout).png")
        try image.pngData()?.write(to: preview)
        print("ASSET_MARKET_PREVIEW=\(preview.path)")

        try await host.selectNavigationRow(row, in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            navigation.viewControllers.count == 2 && navigation.topViewController?.navigationItem.title == "SOL"
                && abs((store.records["solana"]?.quote?.price ?? 0) - 117.24) < 0.00000001
        }
        #expect(navigation.topViewController !== assetController)
        // Wait for the native push to finish before exercising Back.
        try await SendEntryUIProbe.wait(in: host.rootView) { navigation.transitionCoordinator == nil }
        navigation.popViewController(animated: false)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            navigation.viewControllers.count == 1 && navigation.topViewController === assetController
        }
        #expect(list.numberOfItems(inSection: 2) == 5)
        if cachedQuote != nil { #expect(await transport.paths.isEmpty) }
    }
}

extension MarketScreenTests {
    @Test(arguments: [NativeListTestLayout.phone, .largeTextRTL])
    func homeMarketsScrollHorizontallyAndOpenDetails(layout: NativeListTestLayout) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = MarketDatabase(directory: directory)
        defer { Task { await database.close(); try? FileManager.default.removeItem(at: directory) } }
        let store = MarketStore(database: database, provider: MarketProvider(transport: MarketFixtureTransport(mode: .failure)), cloudEnabled: false)
        let suite = "market-carousel-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let discovery = MarketDiscoveryStore(defaults: defaults, transport: MarketFixtureTransport(mode: .failure))
        discovery.category = .favorites
        for coin in MarketCoin.all.prefix(10) {
            discovery.toggleFavorite(MarketDiscoveryCoin(id: coin.id, name: coin.name, symbol: coin.symbol, image: nil))
        }
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                List { WalletMarketsSection(assets: [], store: store, discovery: discovery) }
            }
        }
        defer { host.close() }
        _ = try await host.list()
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UIScrollView.self, in: host.rootView).contains { $0.contentSize.width > $0.bounds.width + 100 && $0.bounds.height < 350 }
        }
        let carousel = try #require(SendEntryUIProbe.views(UIScrollView.self, in: host.rootView).first { $0.contentSize.width > $0.bounds.width + 100 && $0.bounds.height < 350 })
        #expect(abs(carousel.bounds.width - host.rootView.bounds.width) < 2)
        let image = UIGraphicsImageRenderer(bounds: host.rootView.bounds).image { _ in host.rootView.drawHierarchy(in: host.rootView.bounds, afterScreenUpdates: true) }
        let preview = FileManager.default.temporaryDirectory.appendingPathComponent("markets-carousel-\(layout).png")
        try image.pngData()?.write(to: preview)
        print("MARKETS_CAROUSEL=\(preview.path)")
        try SendEntryUIProbe.activate("home.markets", in: host.rootView)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("markets.all.bitcoin", in: host.rootView) != nil
        }
        // Wait for the native navigation transition before inspecting the list.
        try await Task.sleep(for: .milliseconds(500))
        host.rootView.layoutIfNeeded()
        let allImage = UIGraphicsImageRenderer(bounds: host.rootView.bounds).image { _ in host.rootView.drawHierarchy(in: host.rootView.bounds, afterScreenUpdates: true) }
        let allPreview = FileManager.default.temporaryDirectory.appendingPathComponent("markets-all-\(layout).png")
        try allImage.pngData()?.write(to: allPreview)
        print("MARKETS_ALL=\(allPreview.path)")
        try SendEntryUIProbe.activate("markets.all.bitcoin", in: host.rootView)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("markets.detail.bitcoin", in: host.rootView) != nil
        }
    }
}

extension MarketTests {
    @Test @MainActor func slowHistoryDoesNotDelayCoinInformation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = MarketDatabase(directory: directory)
        defer { Task { await database.close(); try? FileManager.default.removeItem(at: directory) } }
        let transport = MarketHistoryGate()
        let store = MarketStore(database: database, provider: MarketProvider(transport: transport), cloudEnabled: false)
        let coin = bitcoin
        let work = Task { await store.detail(coin, range: .day) }
        for _ in 0..<100 {
            if store.records[coin.id]?.info != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.records[coin.id]?.info?.description == "Information arrives independently")
        #expect(store.records[coin.id]?.histories.isEmpty == true)
        await transport.release()
        await work.value
        #expect(store.records[coin.id]?.histories[MarketRange.day.rawValue]?.points.count == 2)
    }
}

private actor MarketHistoryGate: MarketTransport {
    private var waiter: CheckedContinuation<Data, Never>?
    private var released = false
    func data(from url: URL) async throws -> Data {
        if url.path.hasSuffix("market_chart") {
            if released { return chartData() }
            return await withCheckedContinuation { waiter = $0 }
        }
        return Data(#"{"description":{"en":"Information arrives independently"},"links":{"homepage":["https://bitcoin.org"]}}"#.utf8)
    }
    func release() {
        released = true
        waiter?.resume(returning: chartData())
        waiter = nil
    }
    private func chartData() -> Data {
        let now = Date().timeIntervalSince1970 * 1000
        return try! JSONSerialization.data(withJSONObject: ["prices": [[now - 60000, 100], [now, 110]]])
    }
}

@Suite struct MarketChartFeedbackTests {
    @Test func scrubStrengthTracksMovementAndSuppressesDuplicateAndRapidTicks() {
        var feedback = MarketScrubFeedback()
        let start = Date(timeIntervalSince1970: 100)
        #expect(feedback.intensity(for: .init(date: start, price: 100), span: 100, endpoint: false, time: 0) == 0.7)
        #expect(feedback.intensity(for: .init(date: start, price: 100), span: 100, endpoint: false, time: 1) == nil)
        #expect(feedback.intensity(for: .init(date: start.addingTimeInterval(1), price: 101), span: 100, endpoint: false, time: 0.01) == nil)
        let small = feedback.intensity(for: .init(date: start.addingTimeInterval(1), price: 101), span: 100, endpoint: false, time: 1)!
        let large = feedback.intensity(for: .init(date: start.addingTimeInterval(2), price: 120), span: 100, endpoint: false, time: 2)!
        #expect(large > small)
        #expect(large <= 1)
        #expect(feedback.intensity(for: .init(date: start.addingTimeInterval(3), price: 120), span: 100, endpoint: true, time: 3) == 1)
        feedback.reset()
        #expect(feedback.intensity(for: .init(date: start, price: 100), span: 0, endpoint: false, time: 4) == 0.7)
    }
    @Test @MainActor func chartHapticsRespectAppPreferenceAndInactiveState() {
        var events: [UniHaptic] = []
        let muted = UniHapticEngine(isEnabled: false, isApplicationActive: { true }, output: { events.append($0) })
        muted.playMarketScrub(intensity: 1)
        let inactive = UniHapticEngine(isEnabled: true, isApplicationActive: { false }, output: { events.append($0) })
        inactive.playMarketScrub(intensity: 1)
        #expect(events.isEmpty)
        let active = UniHapticEngine(isEnabled: true, isApplicationActive: { true }, output: { events.append($0) })
        active.playMarketScrub(intensity: 0.7)
        #expect(events == [.increase])
    }
}

extension MarketTests {
    @Test func converterUsesDecimalLocalRateAndLocalizedInput() {
        #expect(MarketConversion.localValue(amount: "2.5", price: 100, rate: Decimal(string: "0.709")!) == Decimal(string: "177.25"))
        #expect(MarketConversion.localValue(amount: "٢٫٥", price: 100, rate: Decimal(string: "0.709")!) == Decimal(string: "177.25"))
        #expect(MarketConversion.localValue(amount: "0,1", price: 0.2, rate: 1) == Decimal(string: "0.02"))
        #expect(MarketConversion.localValue(amount: "0", price: 100, rate: 1) == 0)
        #expect(MarketConversion.localValue(amount: "", price: 100, rate: 1) == nil)
        #expect(MarketConversion.localValue(amount: "1", price: nil, rate: 1) == nil)
        #expect(MarketConversion.localValue(amount: "1", price: .infinity, rate: 1) == nil)
        #expect(MarketConversion.localValue(amount: "1", price: 100, rate: 0) == nil)
    }
}

extension MarketTests {
    private func unlisted(_ contract: String, network: WalletBlockchain = .ethereum) -> WalletAsset {
        WalletAsset(id: AssetIdentityKey.make(networkID: network.rawValue, contractAddress: contract),
            name: "New token", symbol: "BTC",
            logoSource: .token(blockchain: network, checksummedContractAddress: contract, logoURL: nil, origin: .catalog),
            network: network, balance: 0, fiatValue: 0)
    }

    @Test(arguments: [
        (WalletBlockchain.solana, "solana"), (.base, "ethereum"),
        (.arc, "usd-coin")
    ])
    func assetDetailResolvesItsExistingNativeMarket(
        network: WalletBlockchain, expectedID: String
    ) {
        let asset = WalletAsset(id: "\(network.rawValue):native", name: "Wallet coin", symbol: "COIN",
            logoSource: .nativeCoin(blockchain: network), network: network, balance: 2, fiatValue: 10)
        let coin = MarketCoin.forAsset(asset)
        #expect(coin.id == expectedID)
        #expect(coin.ownedAsset == asset)
        #expect(MarketCoin.catalog(for: [asset]).first == coin)
    }

    @Test func assetDetailMarketCannotResolveByTickerAlone() {
        let token = unlisted("0x1111111111111111111111111111111111111111")
        let otherNetwork = unlisted("0x1111111111111111111111111111111111111111", network: .base)
        let otherToken = unlisted("0x2222222222222222222222222222222222222222")
        let coins = [token, otherNetwork, otherToken].map(MarketCoin.forAsset)
        #expect(Set(coins.map(\.id)).count == 3)
        #expect(coins.allSatisfy { $0.geckoID == nil && $0.id != "bitcoin" })
        #expect(coins[0].ownedAsset == token)
    }

    @Test func expandedMarketsIncludeZeroBalanceAssetsWithoutTickerCollisions() throws {
        let a = unlisted("0x1111111111111111111111111111111111111111")
        let b = unlisted("0x2222222222222222222222222222222222222222")
        let c = unlisted("0x1111111111111111111111111111111111111111", network: .base)
        let coins = MarketCoin.catalog(for: [a, b, c, a])
        #expect(MarketCoin.all.count >= 250)
        #expect(coins.count == MarketCoin.all.count + 3)
        let owned = coins.filter { $0.ownedAsset != nil }
        #expect(owned.count == 3)
        #expect(coins.prefix(3).allSatisfy { $0.ownedAsset != nil })
        #expect(owned.allSatisfy { $0.geckoID == nil })
        #expect(coins.first { $0.id == "bitcoin" }?.ownedAsset == nil)
        #expect(Set(owned.map(\.id)).count == 3)
        #expect(MarketCoin.catalog(for: []).allSatisfy { $0.ownedAsset == nil })
    }

    @Test func visibleNativeCoinMergesWithItsExistingMarket() {
        let asset = WalletAsset(id: "ethereum:native", name: "Ethereum", symbol: "ETH",
            logoSource: .nativeCoin(blockchain: .ethereum), network: .ethereum, balance: 0, fiatValue: 0)
        let coins = MarketCoin.catalog(for: [asset])
        #expect(coins.count == MarketCoin.all.count)
        #expect(coins.first { $0.id == "ethereum" }?.ownedAsset?.id == asset.id)
    }

    @Test func unlistedPriceUsesExactAssetRouterAndNeverSymbolEndpoints() async throws {
        let asset = unlisted("0x1111111111111111111111111111111111111111")
        let coins = MarketCoin.catalog(for: [asset]).filter { $0.ownedAsset != nil }
        let transport = MarketFixtureTransport(mode: .failure)
        let provider = MarketProvider(transport: transport, ownedPrice: { requested in
            #expect(requested.id == asset.id)
            return AssetUSDPrice(assetID: requested.id, price: Decimal(string: "0.000123")!,
                provider: AssetPriceClient.geckoTerminalContractPriceProvider, observedAt: Date())
        })
        let quotes = await provider.quotes(for: coins)
        #expect(quotes[coins[0].id]?.price == 0.000123)
        #expect(await transport.paths.isEmpty)
    }

    @Test func ownedProviderCannotReturnAnotherAssetPrice() async {
        let coins = MarketCoin.catalog(for: [unlisted("0x1111111111111111111111111111111111111111")]).filter { $0.ownedAsset != nil }
        let provider = MarketProvider(transport: MarketFixtureTransport(mode: .failure), ownedPrice: { _ in
            AssetUSDPrice(assetID: "bitcoin:native", price: 99999, provider: "wrong", observedAt: Date())
        })
        #expect(await provider.quotes(for: coins).isEmpty)
    }

    @Test func expandedQuoteRequestsAreBatchedWithoutDroppingCoins() async {
        let transport = MarketFixtureTransport(mode: .failure)
        _ = await MarketProvider(transport: transport).quotes(for: MarketCoin.all)
        let urls = await transport.paths.compactMap(URL.init(string:)).filter { $0.path == "/api/v3/coins/markets" }
        let batches = urls.map { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "ids" }!.value!.split(separator: ",").map(String.init)
        }
        #expect(batches.allSatisfy { $0.count <= 100 })
        #expect(Set(batches.flatMap { $0 }) == Set(MarketCoin.all.map(\.id)))
    }

    @Test @MainActor func ownedQuotesPersistInMarketDatabaseAndSurviveFailures() async throws {
        let asset = unlisted("0x1111111111111111111111111111111111111111")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = MarketDatabase(directory: directory)
        defer { Task { await database.close(); try? FileManager.default.removeItem(at: directory) } }
        let provider = MarketProvider(transport: MarketFixtureTransport(mode: .failure), ownedPrice: { asset in
            AssetUSDPrice(assetID: asset.id, price: 12, provider: AssetPriceClient.dexScreenerContractPriceProvider, observedAt: Date())
        })
        let store = MarketStore(database: database, provider: provider, cloudEnabled: false)
        await store.trackVisibleAssets([asset])
        let coin = try #require(MarketCoin.catalog(for: [asset]).first { $0.ownedAsset != nil })
        #expect(store.records[coin.id]?.quote?.price == 12)
        let failed = MarketProvider(transport: MarketFixtureTransport(mode: .failure), ownedPrice: { _ in throw AssetPriceError.unavailable })
        let restored = MarketStore(database: database, provider: failed, cloudEnabled: false)
        await restored.refresh(coins: [coin])
        #expect(restored.records[coin.id]?.quote?.price == 12)
        #expect(try await database.load()[coin.id]?.quote?.price == 12)
    }
}


extension MarketTests {
    @Test func reverseConverterUsesLocalCurrencyAndRejectsUnavailableRates() {
        #expect(MarketConversion.coinValue(amount: "500", price: 100, rate: 1) == 5)
        #expect(MarketConversion.coinValue(amount: "١٧٧٫٢٥", price: 100, rate: Decimal(string: "0.709")!) == Decimal(string: "2.5")!)
        #expect(MarketConversion.coinValue(amount: "0", price: 100, rate: 1) == 0)
        #expect(MarketConversion.coinValue(amount: "500", price: nil, rate: 1) == nil)
        #expect(MarketConversion.coinValue(amount: "500", price: 0, rate: 1) == nil)
        #expect(MarketConversion.coinValue(amount: "500", price: 100, rate: 0) == nil)
    }
}

@MainActor
struct MarketSentimentTests {
    // Keep expiry-boundary fixtures exact across ISO-8601 millisecond encoding.
    private let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))

    private func payload(value: Any = 71, classification: String = "Greed",
                         date: Date? = nil, status: Any = 0, dateText: String? = nil) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONSerialization.data(withJSONObject: [
            "data": ["value": value, "value_classification": classification,
                     "update_time": dateText ?? formatter.string(from: date ?? now)],
            "status": ["error_code": status]
        ])
    }

    @Test func decodesEveryPublishedClassification() throws {
        for classification in MarketSentiment.Classification.allCases {
            let reading = try MarketSentiment.decode(payload(classification: classification.rawValue), now: now)
            #expect(reading.value == 71)
            #expect(reading.classification == classification)
        }
    }

    @Test func rejectsInvalidScoresDatesAndProviderErrors() throws {
        let invalid = try [
            payload(value: -1), payload(value: 101), payload(value: "NaN"),
            payload(value: 71.5), payload(value: true), payload(dateText: "invalid"),
            payload(status: "bad"), payload(status: true),
            payload(classification: "unknown"), payload(date: now.addingTimeInterval(-6 * 3600)),
            payload(date: now.addingTimeInterval(3600)), payload(status: 429),
            Data("{\"data\":[],\"metadata\":{\"error\":null}}".utf8)
        ]
        for data in invalid {
            #expect(throws: (any Error).self) {
                try MarketSentiment.decode(data, now: now)
            }
        }
    }

    @Test func acceptsDocumentedStatusAndTimestampFormats() throws {
        for status in [0 as Any, "0"] {
            let reading = try MarketSentiment.decode(payload(status: status), now: now)
            #expect(reading.value == 71)
            #expect(reading.refreshAfter == now.addingTimeInterval(900))
        }
        let text = ISO8601DateFormatter().string(from: now)
        #expect(try MarketSentiment.decode(payload(dateText: text), now: now).value == 71)
    }

    @Test func removesBitcoinOnlyCacheBeforeFetchingMarketIndex() async throws {
        let suite = "sentiment-migration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bitcoinReading = MarketSentiment(value: 12, classification: .extremeFear,
            date: now, refreshAfter: now.addingTimeInterval(3600))
        defaults.set(try JSONEncoder().encode(bitcoinReading), forKey: "markets.sentiment.alternative.v1")
        let transport = SentimentTestTransport(data: try payload())
        let store = MarketSentimentStore(transport: transport, defaults: defaults)
        #expect(store.reading == nil)
        #expect(defaults.object(forKey: "markets.sentiment.alternative.v1") == nil)
        await store.refresh(now: now)
        #expect(store.reading?.value == 71)
        #expect(await transport.urls == [MarketSentimentStore.endpoint])
        #expect(defaults.data(forKey: "markets.sentiment.coinmarketcap.v1") != nil)
    }

    @Test func refreshesAtFifteenMinutesAndHonorsRateLimit() async throws {
        let suite = "sentiment-refresh-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = SentimentTestTransport(data: try payload())
        let store = MarketSentimentStore(transport: transport, defaults: defaults)
        await store.refresh(now: now)
        await store.refresh(now: now.addingTimeInterval(899))
        #expect(await transport.calls == 1)
        await transport.rateLimit(seconds: 600)
        await store.refresh(now: now.addingTimeInterval(900))
        #expect(await transport.calls == 2)
        await store.refresh(now: now.addingTimeInterval(1499))
        #expect(await transport.calls == 2)
        #expect(store.reading?.value == 71)
        await store.refresh(now: now.addingTimeInterval(1500))
        #expect(await transport.calls == 3)
    }

    @Test func failedRequestsBackOffExponentially() async throws {
        let suite = "sentiment-backoff-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = SentimentTestTransport(data: try payload())
        await transport.fail()
        let store = MarketSentimentStore(transport: transport, defaults: defaults)
        for elapsed in [0, 59, 60, 179, 180] {
            await store.refresh(now: now.addingTimeInterval(Double(elapsed)))
        }
        #expect(await transport.calls == 3)
        #expect(store.reading == nil)
    }

    @Test func sharesRequestsAndRestoresCacheWithoutRefetching() async throws {
        let suite = "sentiment-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = SentimentTestTransport(data: try payload())
        let store = MarketSentimentStore(transport: transport, defaults: defaults)
        async let first: Void = store.refresh(now: now)
        async let second: Void = store.refresh(now: now)
        _ = await (first, second)
        #expect(await transport.calls == 1)
        #expect(store.reading?.value == 71)
        let restored = MarketSentimentStore(transport: transport, defaults: defaults)
        await restored.refresh(now: now.addingTimeInterval(100))
        #expect(restored.reading?.value == 71)
        #expect(await transport.calls == 1)
    }

    @Test func failedRefreshKeepsRecentReadingButNotExpiredData() async throws {
        let suite = "sentiment-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = SentimentTestTransport(data: try payload())
        let store = MarketSentimentStore(transport: transport, defaults: defaults)
        await store.refresh(now: now)
        await transport.fail()
        await store.refresh(now: now.addingTimeInterval(3601))
        #expect(store.reading?.value == 71)
        await store.refresh(now: now.addingTimeInterval(3610))
        #expect(await transport.calls == 2)
        await store.refresh(now: now.addingTimeInterval(6 * 3600))
        #expect(store.reading == nil)
        #expect(await transport.calls == 3)
    }
}

private actor SentimentTestTransport: MarketTransport {
    let data: Data
    private(set) var calls = 0
    private var failed = false
    private var httpFailure: MarketHTTPFailure?
    private(set) var urls: [URL] = []
    init(data: Data) { self.data = data }
    func fail() { failed = true }
    func rateLimit(seconds: TimeInterval) { httpFailure = MarketHTTPFailure(status: 429, retryAfter: seconds) }
    func data(from url: URL) async throws -> Data {
        calls += 1
        urls.append(url)
        try await Task.sleep(for: .milliseconds(10))
        if let httpFailure { throw httpFailure }
        if failed { throw URLError(.notConnectedToInternet) }
        return data
    }
}

@MainActor
struct MarketDiscoveryTests {
    @Test func categoriesUseCorrectDirectionAndIgnoreMissingInvalidOrFlatChanges() {
        let ids = ["a", "b", "c", "d", "e", "f", "g"]
        let changes: [String: Double] = ["a": 4, "b": -2, "c": 12, "d": -9, "e": 0, "f": .nan]
        #expect(MarketCategory.gainers.orderedIDs(candidates: ids, changes: changes, trending: [], favorites: []) == ["c", "a"])
        #expect(MarketCategory.losers.orderedIDs(candidates: ids, changes: changes, trending: [], favorites: []) == ["d", "b"])
        #expect(MarketCategory.trending.orderedIDs(candidates: ids, changes: changes, trending: ["b", "a", "missing"], favorites: []) == ["b", "a"])
        #expect(MarketCategory.favorites.orderedIDs(candidates: ids, changes: changes, trending: [], favorites: ["g", "b"]) == ["g", "b"])
    }

    @Test func favoriteIdentityAndCategorySurviveRelaunchAndToggleOff() throws {
        let suite = "market-discovery-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MarketDiscoveryCoin(id: "first-token", name: "First", symbol: "SAME", image: nil, price: 3, change24h: 4)
        let second = MarketDiscoveryCoin(id: "second-token", name: "Second", symbol: "SAME", image: nil)
        let store = MarketDiscoveryStore(defaults: defaults)
        store.toggleFavorite(first)
        store.toggleFavorite(second)
        store.category = .favorites
        let restored = MarketDiscoveryStore(defaults: defaults)
        #expect(restored.favorites.map(\.id) == ["first-token", "second-token"])
        #expect(restored.favorites.first?.price == nil)
        #expect(restored.category == .favorites)
        restored.toggleFavorite(first)
        let again = MarketDiscoveryStore(defaults: defaults)
        #expect(!again.isFavorite(first.id))
        #expect(again.isFavorite(second.id))
    }

    @Test func trendingPreservesProviderOrderAndValidatedValues() throws {
        let snapshot = try MarketTrendingSnapshot.decode(Self.payload, now: Date())
        #expect(snapshot.coins.map(\.id) == ["second", "first"])
        #expect(snapshot.coins.first?.change24h == -3)
        #expect(snapshot.coins.last?.price == 2)
        #expect(snapshot.coins.first?.image == nil)
        #expect(throws: (any Error).self) {
            try MarketTrendingSnapshot.decode(Data("{}".utf8), now: Date())
        }
    }

    @Test func trendingRequestsCoalesceCacheAndExpireAfterOutage() async throws {
        let suite = "market-discovery-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let transport = SentimentTestTransport(data: Self.payload)
        let store = MarketDiscoveryStore(defaults: defaults, transport: transport)
        async let first: Void = store.refresh(now: now)
        async let second: Void = store.refresh(now: now)
        _ = await (first, second)
        #expect(await transport.calls == 1)
        let restored = MarketDiscoveryStore(defaults: defaults, transport: transport)
        #expect(restored.trending?.coins.count == 2)
        await restored.refresh(now: now.addingTimeInterval(100))
        #expect(await transport.calls == 1)
        await transport.fail()
        await restored.refresh(now: now.addingTimeInterval(301))
        #expect(restored.trending?.coins.count == 2)
        await restored.refresh(now: now.addingTimeInterval(302))
        #expect(await transport.calls == 2)
        await restored.refresh(now: now.addingTimeInterval(3601))
        #expect(restored.trending == nil)
    }

    private static let payload = Data("""
        {"coins":[
          {"item":{"id":"first","name":"First","symbol":"ONE","score":1,"small":"https://example.com/one.png","data":{"price":2,"price_change_percentage_24h":{"usd":4}}}},
          {"item":{"id":"second","name":"Second","symbol":"TWO","score":0,"small":"http://example.com/two.png","data":{"price":1,"price_change_percentage_24h":{"usd":-3}}}},
          {"item":{"id":"first","name":"Duplicate","symbol":"ONE","score":2}},
          {"item":{"id":"asset:fake","name":"Invalid","symbol":"FAKE","score":3}}
        ]}
        """.utf8)
}
