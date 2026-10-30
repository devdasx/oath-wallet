import XCTest
import OathDatabase
import OathDiagnostics
@testable import OathExchangeRates

private actor FixtureTransport: ExchangeRateTransport {
    var requests = 0
    let payload: Data
    let failFirst: Bool
    let failAll: Bool
    init(_ payload: Data, failFirst: Bool = false, failAll: Bool = false) {
        self.payload = payload; self.failFirst = failFirst; self.failAll = failAll
    }
    func data(from url: URL) async throws -> Data {
        requests += 1
        try await Task.sleep(for: .milliseconds(10))
        if failAll || (failFirst && requests == 1) { throw URLError(.notConnectedToInternet) }
        return payload
    }
}

@MainActor final class ExchangeRateServiceTests: XCTestCase {
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z")! }
    private func payload(date: String = "2026-10-10", changes: [String: Any] = [:]) throws -> Data {
        // Use provider-style decimal JSON literals. Serializing a Swift Double
        // fixture would already lose precision before the parser is exercised.
        var rates = Dictionary(uniqueKeysWithValues: CurrencyCatalog.codes.map { ($0.lowercased(), "1") })
        rates["jod"] = "0.709"
        rates["eur"] = "0.89271638"
        rates["btc"] = "0.00001234"
        for (key, value) in changes {
            rates[key] = String(decoding: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), as: UTF8.self)
        }
        let fields = rates.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        return Data("{\"date\":\"\(date)\",\"usd\":{\(fields)}}".utf8)
    }
    private func database() async throws -> OathDatabase {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathFXService-" + UUID().uuidString).appendingPathComponent("test.sqlite")
        return try await OathDatabase.open(at: url)
    }

    func testRealFormatPreservesDecimalsAndFiltersCrypto() throws {
        let result = try ExchangeRateFeed.decode(payload(), fetchedAt: now)
        XCTAssertEqual(result.rates["JOD"], "0.709")
        XCTAssertEqual(result.rates["EUR"], "0.89271638")
        XCTAssertEqual(result.rates["USD"], "1")
        XCTAssertNil(result.rates["BTC"])
        XCTAssertTrue(result.rates.count >= 150)
    }

    func testMalformedFutureStaleAndWrongBaseResponsesRejected() throws {
        for changes: [String: Any] in [["usd": 2], ["jod": 0], ["jod": -1], ["jod": "broken"], ["USD": 1]] {
            XCTAssertThrowsError(try ExchangeRateFeed.decode(payload(changes: changes), fetchedAt: now))
        }
        for date in ["2026-02-31", "2026-10-12", "2026-09-01", "26-10-10"] {
            XCTAssertThrowsError(try ExchangeRateFeed.decode(payload(date: date), fetchedAt: now))
        }
        XCTAssertThrowsError(try ExchangeRateFeed.decode(Data("{\"date\":\"2026-10-10\",\"usd\":{\"usd\":1}}".utf8), fetchedAt: now))
        XCTAssertThrowsError(try ExchangeRateFeed.decode(Data(repeating: 0, count: 131_073), fetchedAt: now))
    }

    func testConcurrentRefreshAndSelectionMakeOneRequest() async throws {
        let db = try await database(), transport = FixtureTransport(try payload()), date = now
        let service = ExchangeRateService(database: db, transport: transport, now: { date })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await service.refreshIfNeeded() } }
            try await group.waitForAll()
        }
        for code in ["USD", "JOD", "EUR", "JPY", "USD"] { try await db.selectDisplayCurrency(code) }
        _ = try await service.refreshIfNeeded()
        let count = await transport.requests
        XCTAssertEqual(count, 1)
        // A new process/service uses the same persisted cache without fetching.
        let reopenedService = ExchangeRateService(database: db, transport: transport, now: { date })
        _ = try await reopenedService.refreshIfNeeded()
        let reopenedCount = await transport.requests
        XCTAssertEqual(reopenedCount, 1)
    }

    func testPrimaryFailureUsesFallback() async throws {
        let db = try await database(), transport = FixtureTransport(try payload(), failFirst: true), date = now
        let service = ExchangeRateService(database: db, transport: transport, now: { date })
        let rates = try await service.refreshIfNeeded()
        let count = await transport.requests
        XCTAssertEqual(count, 2)
        XCTAssertEqual(rates.rates["JOD"], "0.709")
    }

    func testOfflineKeepsOldCacheAndBacksOffUntilExplicitRetry() async throws {
        let db = try await database(), transport = FixtureTransport(try payload(), failAll: true), date = now
        let yesterday = date.addingTimeInterval(-86_400)
        let cached = try ExchangeRateFeed.decode(payload(date: "2026-10-09"), fetchedAt: yesterday)
        try await db.saveExchangeRates(cached)
        let service = ExchangeRateService(database: db, transport: transport, now: { date })
        for _ in 0..<10 {
            do { _ = try await service.refreshIfNeeded(); XCTFail("Unexpected success") }
            catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests, 2)
        let saved = try await db.exchangeRates()
        XCTAssertEqual(saved, cached)
        try await db.selectDisplayCurrency("JOD") // Works while offline.
        do { _ = try await service.refreshIfNeeded(retryNow: true); XCTFail("Unexpected success") } catch { }
        let afterRetry = await transport.requests
        XCTAssertEqual(afterRetry, 4)
    }

    func testFallbackExhaustionAndBackoffPreserveMalformedFailure() async throws {
        let db = try await database(), date = now
        let transport = FixtureTransport(Data("<html>invalid feed</html>".utf8))
        let service = ExchangeRateService(database: db, transport: transport, now: { date })
        for _ in 0..<3 {
            do { _ = try await service.refreshIfNeeded(); XCTFail("Accepted invalid rates") }
            catch { XCTAssertTrue(error is DecodingError, "Lost the original parsing failure") }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests, 2, "Backoff must not create more provider traffic")
        let saved = try await db.exchangeRates()
        XCTAssertNil(saved)
    }

    func testRateTransportPreservesHTTPStatusAndRejectsOversizedSuccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionRateTransport(session: session)
        for status in [400, 403, 429, 503] {
            do {
                _ = try await transport.data(from: URL(string: "https://fixture.invalid/\(status)")!)
                XCTFail("Accepted HTTP failure")
            } catch {
                XCTAssertEqual((error as NSError).domain, "Oath.HTTP")
                XCTAssertEqual((error as NSError).code, status)
            }
        }
        do {
            _ = try await transport.data(from: URL(string: "https://fixture.invalid/200")!)
            XCTFail("Accepted oversized response")
        } catch { XCTAssertEqual(error as? ExchangeRateError, .invalidResponse) }
    }

    func testOfflineRefreshDoesNotReappearAsGenericAppError() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FX_DIAGNOSTICS_TEST"] == "1" else {
            throw XCTSkip("Run alone to isolate the process-wide diagnostics outbox")
        }
        let reports = RateDiagnosticReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let db = try await database(), transport = FixtureTransport(try payload(), failAll: true), date = now
        let service = ExchangeRateService(database: db, transport: transport, now: { date })
        for _ in 0..<3 {
            do { _ = try await service.refreshIfNeeded(); XCTFail("Unexpected success") }
            catch { OathDiagnostics.record(error, component: "prices", operation: "exchange_rates") }
        }
        // A retained failure proves the uploader is working; do not hide malformed data.
        OathDiagnostics.record(ExchangeRateError.invalidResponse, component: "prices", operation: "fixture_validation")
        for _ in 0..<200 {
            if await reports.events.contains(where: { $0.operation == "fixture_validation" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await reports.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.map(\.error.message), ["invalidResponse"])
    }

    func testCurrencySearchMatchesCodeAndLocalizedOrEnglishName() {
        XCTAssertEqual(CurrencyCatalog.matching(["USD", "JOD", "EUR"], query: "jod", locale: Locale(identifier: "ar")), ["JOD"])
        XCTAssertEqual(CurrencyCatalog.matching(["USD", "JOD", "EUR"], query: "jordanian", locale: Locale(identifier: "ar")), ["JOD"])
        XCTAssertEqual(CurrencyCatalog.matching(["USD", "JOD", "EUR"], query: "أردني", locale: Locale(identifier: "ar")), ["JOD"])
        XCTAssertTrue(CurrencyCatalog.matching(["USD"], query: "invalid", locale: Locale(identifier: "en")).isEmpty)
    }

    func testCurrencySectionsPinSelectionAndUseDeviceRegionInsteadOfAppLanguage() {
        for language in ["en", "ar", "he", "ja"] {
            let sections = CurrencyCatalog.sections(availableCodes: ["ILS", "JOD", "USD", "EUR"],
                selectedCode: "ILS", deviceLocale: Locale(identifier: "en_JO"),
                query: "", displayLocale: Locale(identifier: language))
            XCTAssertEqual(Array(sections.mostUsed.prefix(3)), ["ILS", "JOD", "USD"])
            XCTAssertTrue(sections.others.isEmpty)
            XCTAssertEqual(Set(sections.mostUsed).count, sections.mostUsed.count)
        }
    }

    func testCurrencySectionsKeepRegionalSuggestionWithoutCachedRatesAndNeverInventOne() {
        for (region, currency) in [("en_JO", "JOD"), ("ar_US", "USD"), ("en_JP", "JPY"),
                                   ("en_DE", "EUR"), ("en_IN", "INR"), ("en_BR", "BRL")] {
            let sections = CurrencyCatalog.sections(availableCodes: [], selectedCode: "EUR",
                deviceLocale: Locale(identifier: region), query: "", displayLocale: Locale(identifier: "ar"))
            XCTAssertEqual(sections.mostUsed.first, "EUR")
            XCTAssertTrue(sections.mostUsed.contains(currency), region)
            XCTAssertEqual(sections.mostUsed.filter { $0 == currency }.count, 1)
        }
        let unknown = CurrencyCatalog.sections(availableCodes: [], selectedCode: "USD",
            deviceLocale: Locale(identifier: "und"), query: "", displayLocale: Locale(identifier: "ar"))
        XCTAssertEqual(unknown.mostUsed, CurrencyCatalog.mostUsedCodes)
    }

    func testCurrencySectionsReorderNewSelectionWithoutDuplicateRows() {
        let available = ["USD", "EUR", "JOD", "NZD", "INR", "NZD", "BTC", "INVALID"]
        for selected in ["USD", "JOD", "NZD"] {
            let sections = CurrencyCatalog.sections(availableCodes: available, selectedCode: selected,
                deviceLocale: Locale(identifier: "en_JO"), query: "", displayLocale: Locale(identifier: "en"))
            let all = sections.mostUsed + sections.others
            XCTAssertEqual(all.first, selected)
            XCTAssertEqual(all.count, Set(all).count)
            XCTAssertTrue(Set(["USD", "EUR", "JOD", "NZD", "INR"]).isSubset(of: Set(all)))
            XCTAssertFalse(all.contains("BTC"))
            XCTAssertFalse(all.contains("INVALID"))
            XCTAssertFalse(sections.others.contains(selected))
            XCTAssertFalse(sections.others.contains("JOD"))
        }
    }

    func testCurrencySectionSearchFiltersBothGroupsInEnglishAndArabic() {
        for query in ["jod", "jordanian", "أردني", "  Jordanian  dinar "] {
            let sections = CurrencyCatalog.sections(availableCodes: ["JOD", "NZD"], selectedCode: "USD",
                deviceLocale: Locale(identifier: "en_JO"), query: query, displayLocale: Locale(identifier: "ar"))
            XCTAssertEqual(sections.mostUsed, ["JOD"])
            XCTAssertTrue(sections.others.isEmpty)
        }
        let other = CurrencyCatalog.sections(availableCodes: ["NZD"], selectedCode: "USD",
            deviceLocale: Locale(identifier: "en_JO"), query: "nzd", displayLocale: Locale(identifier: "ar"))
        XCTAssertTrue(other.mostUsed.isEmpty)
        XCTAssertEqual(other.others, ["NZD"])
        let noMatch = CurrencyCatalog.sections(availableCodes: ["NZD"], selectedCode: "USD",
            deviceLocale: Locale(identifier: "en_JO"), query: "no-such-currency", displayLocale: Locale(identifier: "en"))
        XCTAssertTrue(noMatch.isEmpty)
    }

    func testLiveRateFeedWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TEST_LIVE_RATES"] == "1" else {
            throw XCTSkip("Opt-in public API smoke check; regular tests are deterministic and offline")
        }
        let db = try await database()
        let service = ExchangeRateService(database: db)
        let live = try await service.refreshIfNeeded()
        let persisted = try await db.exchangeRates()
        XCTAssertEqual(live, persisted)
        XCTAssertEqual(live.rate(for: "USD"), 1)
        for code in ["EUR", "JOD", "ILS", "JPY", "KWD"] {
            XCTAssertNotNil(live.rate(for: code))
            try await db.selectDisplayCurrency(code)
        }
        print("Verified live USD feed and SQL cache: \(live.rates.count) fiat currencies.")
    }
}

private actor RateDiagnosticReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private final class RateHTTPFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Int(request.url!.lastPathComponent)!
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: status == 200 ? Data(repeating: 32, count: 131_073) : Data("<html>HTTP failure</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
