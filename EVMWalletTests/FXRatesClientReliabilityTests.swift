import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct FXRatesClientReliabilityTests {
    @Test
    func firstRunPrewarmFetchesAndPersistsRates() async throws {
        FXRatesFixtureURLProtocol.install(primaryStatus: 200)
        let databaseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let database = try WalletDatabase.applicationDatabase(
            at: databaseDirectory
        )
        let client = FXRatesClient(
            session: Self.fixtureSession(),
            database: database,
            router: AdaptiveProviderRouter(),
            serviceID: "fx_test_prewarm_\(UUID().uuidString)",
            timeoutSeconds: 1,
            frankfurterURL: URL(
                string: "https://frankfurter.fixture.test/rates"
            ),
            openExchangeURL: URL(
                string: "https://open-exchange.fixture.test/latest"
            )
        )

        let warmedSnapshot = await client.prewarm()
        let warmed = try #require(warmedSnapshot)
        let durableSnapshot = try await database.cachedFXRates()
        let durable = try #require(durableSnapshot)

        #expect(warmed.currency(for: "EUR")?.ratePerUSD == 0.91)
        #expect(durable.currency(for: "EUR")?.ratePerUSD == 0.91)
        #expect(FXRatesFixtureURLProtocol.requestedHosts() == [
            "frankfurter.fixture.test"
        ])
    }

    @Test
    func transientPrimaryFailureFallsBackToOpenExchangeRates()
        async throws
    {
        FXRatesFixtureURLProtocol.install(primaryStatus: 503)
        let databaseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let client = FXRatesClient(
            session: Self.fixtureSession(),
            database: try WalletDatabase.applicationDatabase(
                at: databaseDirectory
            ),
            router: AdaptiveProviderRouter(),
            serviceID: "fx_test_fallback_\(UUID().uuidString)",
            timeoutSeconds: 1,
            frankfurterURL: URL(
                string: "https://frankfurter.fixture.test/rates"
            ),
            openExchangeURL: URL(
                string: "https://open-exchange.fixture.test/latest"
            )
        )

        let snapshot = try await client.refresh()

        #expect(snapshot.currency(for: "USD")?.ratePerUSD == 1)
        #expect(snapshot.currency(for: "EUR")?.ratePerUSD == 0.91)
        #expect(snapshot.currency(for: "JPY")?.ratePerUSD == 151.25)
        #expect(FXRatesFixtureURLProtocol.requestedHosts() == [
            "frankfurter.fixture.test",
            "open-exchange.fixture.test"
        ])
    }

    @Test
    func deterministicClientFailureDoesNotQueryFallback() async throws {
        FXRatesFixtureURLProtocol.install(primaryStatus: 400)
        let databaseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let client = FXRatesClient(
            session: Self.fixtureSession(),
            database: try WalletDatabase.applicationDatabase(
                at: databaseDirectory
            ),
            router: AdaptiveProviderRouter(),
            serviceID: "fx_test_final_\(UUID().uuidString)",
            timeoutSeconds: 1,
            frankfurterURL: URL(
                string: "https://frankfurter.fixture.test/rates"
            ),
            openExchangeURL: URL(
                string: "https://open-exchange.fixture.test/latest"
            )
        )

        do {
            _ = try await client.refresh()
            Issue.record("Expected the definitive HTTP failure")
        } catch let error as FXRatesError {
            #expect(error == .httpFailure(400))
        }

        #expect(FXRatesFixtureURLProtocol.requestedHosts() == [
            "frankfurter.fixture.test"
        ])
    }

    private static func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FXRatesFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

struct FXRatesBaseCurrencyTests {
    @Test
    func presentationFallbackIsImmediatelyUsableWithoutRemoteData() {
        let snapshot = FXRatesSnapshot.baseCurrencyFallback

        #expect(snapshot.currencies.count == 1)
        #expect(snapshot.currency(for: "USD")?.ratePerUSD == 1)
    }

    @Test
    func baseUSDCurrencyIsAlwaysPresentAndSearchable() throws {
        let snapshot = FXRatesSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 1_786_579_351),
            currencies: [
                FXCurrencyRate(
                    code: "EUR",
                    englishName: "Euro",
                    symbol: "€",
                    ratePerUSD: 0.91,
                    rateDate: "2026-08-13"
                )
            ]
        )
        let usdRate = try #require(snapshot.currency(for: "USD"))
        let locale = Locale(identifier: "en_US")
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        let currency = SettingsCurrency(
            rate: usdRate,
            locale: locale,
            formatter: formatter
        )

        #expect(usdRate.ratePerUSD == 1)
        #expect(usdRate.rateDate == "2026-08-13")
        #expect(currency.matchesSearch("Usd"))
        #expect(currency.matchesSearch("US Dollar"))
    }
}

struct CurrencySettingsPresentationTests {
    @Test
    func mostUsedCurrenciesIncludeRegionalCurrencyWithoutDuplicates() {
        let currencies = [
            Self.makeCurrency("AUD"),
            Self.makeCurrency("CAD"),
            Self.makeCurrency("EUR"),
            Self.makeCurrency("ILS"),
            Self.makeCurrency("JPY"),
            Self.makeCurrency("USD")
        ]

        let israel = CurrencySettingsSections(
            currencies: currencies,
            regionalCurrencyCode: "ILS",
            selectedCurrencyCode: "AUD"
        )
        #expect(israel.mostUsed.map(\.id) == [
            "USD", "EUR", "CAD", "JPY", "ILS"
        ])
        #expect(israel.allCurrencies.map(\.id) == ["AUD"])

        let canada = CurrencySettingsSections(
            currencies: currencies,
            regionalCurrencyCode: "CAD",
            selectedCurrencyCode: "ILS"
        )
        #expect(canada.mostUsed.map(\.id) == [
            "USD", "EUR", "CAD", "JPY"
        ])
        #expect(canada.allCurrencies.map(\.id) == ["ILS", "AUD"])
    }

    @Test
    func providerCurrencyCatalogHasFlags() {
        for code in Self.providerCurrencyCodes {
            #expect(
                !CurrencyFlagResolver.flag(for: code).isEmpty,
                "Missing representative flag for \(code)"
            )
        }
    }

    @Test
    func currencyPresentationUsesLocalizedNameSymbolAndCode() {
        let locale = Locale(identifier: "en_US")
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        let rate = FXCurrencyRate(
            code: "EUR",
            englishName: "Euro",
            symbol: "€",
            ratePerUSD: 0.91,
            rateDate: "2026-08-17"
        )

        let currency = SettingsCurrency(
            rate: rate,
            locale: locale,
            formatter: formatter
        )

        #expect(currency.flag == "🇪🇺")
        #expect(currency.localizedName == "Euro")
        #expect(currency.localizedShortNameAndCode == "€ · EUR")
    }

    private static func makeCurrency(_ code: String) -> SettingsCurrency {
        let locale = Locale(identifier: "en_US")
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        return SettingsCurrency(
            rate: FXCurrencyRate(
                code: code,
                englishName: code,
                symbol: code,
                ratePerUSD: 1,
                rateDate: "2026-08-28"
            ),
            locale: locale,
            formatter: formatter
        )
    }

    private static let providerCurrencyCodes = """
    AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD
    BND BOB BRL BSD BTN BWP BYN BZD CAD CDF CHF CLF CLP CNH CNY COP CRC
    CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP FOK GBP GEL GGP
    GHS GIP GMD GNF GTQ GYD HKD HNL HRK HTG HUF IDR ILS IMP INR IQD IRR
    ISK JEP JMD JOD JPY KES KGS KHR KID KMF KRW KWD KYD KZT LAK LBP LKR
    LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MYR MZN
    NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD
    RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP STN SYP SZL
    THB TJS TMT TND TOP TRY TTD TVD TWD TZS UAH UGX UYU UZS VES VND VUV
    WST XAF XCD XCG XDR XOF XPF YER ZAR ZMW ZWG ZWL
    """
    .split(whereSeparator: \Character.isWhitespace)
    .map(String.init)
}

struct CurrencyConverterEngineTests {
    @Test
    func defaultsUseLocalCurrencyAndUSDWithEURForUSDUsers() throws {
        let units = [
            Self.unit("USD", priceUSD: 1),
            Self.unit("EUR", priceUSD: 1.25),
            Self.unit("JPY", priceUSD: 0.01)
        ]

        let euroDefault = try #require(
            CurrencyConverterSelectionResolver.resolve(
                stored: nil,
                localCurrencyCode: "EUR",
                units: units
            )
        )
        #expect(euroDefault.sourceID == "fiat:EUR")
        #expect(euroDefault.targetID == "fiat:USD")

        let usdDefault = try #require(
            CurrencyConverterSelectionResolver.resolve(
                stored: nil,
                localCurrencyCode: "USD",
                units: units
            )
        )
        #expect(usdDefault.sourceID == "fiat:USD")
        #expect(usdDefault.targetID == "fiat:EUR")
    }

    @Test
    func storedValidBoardTakesPriorityOverDefaults() throws {
        let units = [
            Self.unit("USD", priceUSD: 1),
            Self.unit("EUR", priceUSD: 1.25),
            Self.unit("JPY", priceUSD: 0.01)
        ]
        let stored = CurrencyConverterSelection(
            unitIDs: [
                "fiat:JPY",
                "fiat:EUR",
                "fiat:USD"
            ]
        )

        let resolved = try #require(
            CurrencyConverterSelectionResolver.resolve(
                stored: stored,
                localCurrencyCode: "USD",
                units: units
            )
        )
        #expect(resolved == stored)
        #expect(
            resolved.unitIDs == [
                "fiat:JPY",
                "fiat:EUR",
                "fiat:USD"
            ]
        )
    }

    @Test
    func lastUsedCurrencySurvivesResolutionWithoutReorderingRows() throws {
        let stored = CurrencyConverterSelection(
            unitIDs: ["fiat:USD", "fiat:EUR", "fiat:JPY"],
            lastUsedUnitID: "fiat:JPY"
        )
        let units = [
            Self.unit("USD", priceUSD: 1),
            Self.unit("EUR", priceUSD: 1.25),
            Self.unit("JPY", priceUSD: 0.01)
        ]
        let resolved = try #require(CurrencyConverterSelectionResolver.resolve(
            stored: stored, localCurrencyCode: "EUR", units: units
        ))
        #expect(resolved == stored)
        #expect(resolved.sourceID == "fiat:USD")
        #expect(resolved.lastUsedUnitID == "fiat:JPY")

        let unavailable = try #require(CurrencyConverterSelectionResolver.resolve(
            stored: stored, localCurrencyCode: "EUR", units: Array(units.prefix(2))
        ))
        #expect(unavailable.lastUsedUnitID == "fiat:USD")
        #expect(unavailable.unitIDs == ["fiat:USD", "fiat:EUR"])
    }

    @Test
    func missingOrRemovedLastUsedCurrencyFallsBackToFirstRow() {
        let ids = ["fiat:EUR", "fiat:USD"]
        #expect(CurrencyConverterSelection(unitIDs: ids).lastUsedUnitID == "fiat:EUR")
        #expect(CurrencyConverterSelection(
            unitIDs: ids, lastUsedUnitID: "fiat:JPY"
        ).lastUsedUnitID == "fiat:EUR")
        #expect(CurrencyConverterSelection(unitIDs: []).lastUsedUnitID.isEmpty)
    }

    @Test
    func conversionUsesExactCrossRateArithmetic() throws {
        let usd = Self.unit("USD", priceUSD: 1)
        let eur = Self.unit("EUR", priceUSD: 1.25)
        let converted = try #require(
            CurrencyConverterEngine.convert(
                amountText: "10",
                from: usd,
                to: eur
            )
        )

        #expect(converted == 8)
        #expect(
            CurrencyConverterEngine.formatted(
                converted,
                for: .fiat
            ) == "8"
        )

        #expect(
            CurrencyConverterEngine.convertedAmountText(
                amountText: "8",
                from: eur,
                to: usd
            ) == "10"
        )
        #expect(
            CurrencyConverterEngine.convertedAmountText(
                amountText: "10000",
                from: usd,
                to: eur
            ) == "8000"
        )
    }

    @Test
    func oneAmountConvertsAcrossEverySelectedTarget() throws {
        let usd = Self.unit("USD", priceUSD: 1)
        let eur = Self.unit("EUR", priceUSD: 1.25)
        let jpy = Self.unit("JPY", priceUSD: 0.01)
        let conversions = CurrencyConverterEngine.convertedAmountTexts(
            amountText: "10",
            from: usd,
            to: [eur, jpy]
        )

        #expect(conversions[eur.id] == "8")
        #expect(conversions[jpy.id] == "1000")
    }

    @Test
    func amountInputAcceptsOnlyASCIIDigitsAndNormalizesDecimalSeparators() {
        #expect(
            CurrencyConverterEngine.sanitizedAmount(
                "٠١2a.3.4"
            ) == "2.34"
        )
        #expect(
            CurrencyConverterEngine.sanitizedAmount(".125") == "0.125"
        )
        #expect(
            CurrencyConverterEngine.sanitizedAmount("12,5") == "12.5"
        )
        #expect(
            CurrencyConverterEngine.sanitizedAmount("12٫5") == "12.5"
        )
    }

    private static func unit(
        _ code: String,
        priceUSD: Decimal?
    ) -> CurrencyConverterUnit {
        CurrencyConverterUnit(
            id: "fiat:\(code)",
            code: code,
            englishName: code,
            symbol: code,
            kind: .fiat,
            usdPricePerUnit: priceUSD,
            flag: "",
            network: nil,
            walletAssetID: nil,
            logoSource: nil,
            sortOrder: 0
        )
    }
}

@Suite(.serialized)
struct CurrencyConverterPersistenceTests {
    @Test
    func selectionAndExactMetalPricesSurviveDatabaseReload()
        async throws {
        let databaseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let database = try WalletDatabase.applicationDatabase(
            at: databaseDirectory
        )
        let selection = CurrencyConverterSelection(
            unitIDs: [
                "metal:XAU",
                "asset:bitcoin:native",
                "fiat:EUR",
                "fiat:USD"
            ],
            lastUsedUnitID: "fiat:EUR"
        )
        let exactPrice = try #require(
            Decimal(
                string: "4456.399902",
                locale: Locale(identifier: "en_US_POSIX")
            )
        )

        try await database.saveCurrencyConverterSelection(selection)
        try await database.saveCurrencyConverterMarketPrices([
            CurrencyConverterMarketPrice(
                unitID: "metal:XAU",
                priceUSD: exactPrice,
                provider: "fixture",
                observedAt: Date(),
                expiresAt: Date().addingTimeInterval(300)
            )
        ])

        let reopened = try WalletDatabase.applicationDatabase(at: databaseDirectory)
        #expect(try await reopened.currencyConverterSelection() == selection)
        let cached = try await database
            .cachedCurrencyConverterMarketPrices()
        #expect(cached["metal:XAU"]?.priceUSD == exactPrice)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

@Suite(.serialized)
struct MetalPriceClientTests {
    @Test
    func fetchesBothMetalsConcurrentlyAndCachesExactPrices()
        async throws {
        MetalPriceFixtureURLProtocol.install()
        let databaseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let database = try WalletDatabase.applicationDatabase(
            at: databaseDirectory
        )
        let client = MetalPriceClient(
            session: Self.fixtureSession(),
            database: database,
            baseURL: URL(string: "https://gold.fixture.test")
        )

        let prices = try await client.latestPrices()

        #expect(
            prices["metal:XAU"]?.priceUSD
                == Decimal(string: "4456.399902")
        )
        #expect(
            prices["metal:XAG"]?.priceUSD
                == Decimal(string: "80.802269")
        )
        #expect(
            Set(MetalPriceFixtureURLProtocol.requestedPaths())
                == Set(["/price/XAU", "/price/XAG"])
        )

        _ = try await client.latestPrices()
        #expect(MetalPriceFixtureURLProtocol.requestedPaths().count == 2)

        let cached = try await database
            .cachedCurrencyConverterMarketPrices()
        #expect(cached["metal:XAU"]?.provider == "gold-api")
        #expect(cached["metal:XAG"]?.provider == "gold-api")
    }

#if LIVE_MAINNET_TESTS
    @Test
    func liveGoldAPIProvidesPositiveGoldAndSilverPrices() async throws {
        let databaseDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let client = MetalPriceClient(
            database: try WalletDatabase.applicationDatabase(
                at: databaseDirectory
            )
        )
        let prices = try await client.refresh()
        #expect(prices["metal:XAU"]?.priceUSD ?? 0 > 0)
        #expect(prices["metal:XAG"]?.priceUSD ?? 0 > 0)
    }
#endif

    private static func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            MetalPriceFixtureURLProtocol.self
        ]
        return URLSession(configuration: configuration)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

private final class MetalPriceFixtureURLProtocol: URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []

    static func install() {
        lock.lock()
        paths = []
        lock.unlock()
    }

    static func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.paths.append(url.path)
        Self.lock.unlock()

        let payload: Data
        switch url.lastPathComponent {
        case "XAU":
            payload = Self.payload(
                symbol: "XAU",
                name: "Gold",
                price: "4456.399902"
            )
        case "XAG":
            payload = Self.payload(
                symbol: "XAG",
                name: "Silver",
                price: "80.802269"
            )
        default:
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func payload(
        symbol: String,
        name: String,
        price: String
    ) -> Data {
        Data(
            """
            {"currency":"USD","currencySymbol":"$","exchangeRate":1,"name":"\(name)","price":\(price),"symbol":"\(symbol)","updatedAt":"2026-08-30T17:59:36Z"}
            """.utf8
        )
    }
}

private final class FXRatesFixtureURLProtocol: URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var primaryStatus = 503
    nonisolated(unsafe) private static var hosts: [String] = []

    static func install(primaryStatus: Int) {
        lock.lock()
        self.primaryStatus = primaryStatus
        hosts = []
        lock.unlock()
    }

    static func requestedHosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.hosts.append(host)
        let primaryStatus = Self.primaryStatus
        Self.lock.unlock()

        if host == "frankfurter.fixture.test" {
            respond(
                status: primaryStatus,
                object: primaryStatus == 200
                    ? [[
                        "date": "2026-08-13",
                        "base": "USD",
                        "quote": "EUR",
                        "rate": 0.91
                    ]]
                    : ["error": "unavailable"]
            )
            return
        }
        if host == "open-exchange.fixture.test" {
            respond(
                status: 200,
                object: [
                    "result": "success",
                    "time_last_update_unix": 1_786_579_351,
                    "base_code": "USD",
                    "rates": [
                        "USD": 1,
                        "EUR": 0.91,
                        "JPY": 151.25
                    ]
                ]
            )
            return
        }
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.unsupportedURL)
        )
    }

    override func stopLoading() {}

    private func respond(status: Int, object: Any) {
        guard let url = request.url else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
