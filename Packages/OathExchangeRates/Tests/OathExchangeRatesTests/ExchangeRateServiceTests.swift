import XCTest
import SQLite3
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

    func testUnknownNonFiatValueCannotDiscardValidFiatRates() throws {
        let baseline = try ExchangeRateFeed.decode(payload(), fetchedAt: now)
        for value: Any in [NSNull(), "not a quote", ["provider": "unsupported"]] {
            let mixed = try ExchangeRateFeed.decode(payload(changes: ["btc": value]), fetchedAt: now)
            XCTAssertEqual(mixed, baseline)
        }
        XCTAssertThrowsError(try ExchangeRateFeed.decode(payload(changes: ["jod": NSNull()]), fetchedAt: now))
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

    func testSQLiteWriteFailureIsNotRetriedAgainstAnotherFeed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rates.sqlite")
        let db = try await OathDatabase.open(at: url)
        let date = now, transport = FixtureTransport(try payload())
        let old = try ExchangeRateFeed.decode(payload(date: "2026-10-09"), fetchedAt: date.addingTimeInterval(-86400))
        try await db.saveExchangeRates(old)
        var sql: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &sql), SQLITE_OK)
        defer { sqlite3_close(sql) }
        XCTAssertEqual(sqlite3_exec(sql, "CREATE TRIGGER fail_rate_write BEFORE INSERT ON exchangeRates BEGIN SELECT RAISE(ABORT,'fixture write failure'); END", nil, nil, nil), SQLITE_OK)
        let service = ExchangeRateService(database: db, transport: transport, now: { date })
        for _ in 0..<2 {
            do { _ = try await service.refreshIfNeeded(); XCTFail("Failed local write accepted") }
            catch { XCTAssertEqual((error as NSError).domain, "GRDB.DatabaseError") }
        }
        let count = await transport.requests, cached = try await db.exchangeRates()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(cached, old)
        XCTAssertEqual(sqlite3_exec(sql, "DROP TRIGGER fail_rate_write", nil, nil, nil), SQLITE_OK)
        let recovered = try await service.refreshIfNeeded(retryNow: true)
        XCTAssertEqual(recovered.observedAt, try ExchangeRateFeed.decode(payload(), fetchedAt: date).observedAt)
        let saved = try await db.exchangeRates()
        XCTAssertEqual(saved, recovered)
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

    func testCancelledFeedDoesNotFetchMirrorOrBackOffNextRefresh() async throws {
        actor CancelFirst: ExchangeRateTransport {
            let cancellation: any Error
            let payload: Data
            var calls = 0
            init(_ cancellation: any Error, data: Data) { self.cancellation = cancellation; payload = data }
            func data(from url: URL) async throws -> Data {
                calls += 1
                if calls == 1 { throw cancellation }
                return payload
            }
        }
        for cancellation: any Error in [CancellationError(), URLError(.cancelled)] {
            let db = try await database(), date = now
            let feed = try CancelFirst(cancellation, data: payload())
            let service = ExchangeRateService(database: db, transport: feed, now: { date })
            do { _ = try await service.refreshIfNeeded(); XCTFail("Cancellation fetched a mirror") }
            catch { XCTAssertTrue(OathDiagnostics.isExpectedCancellation(error)) }
            let initial = await feed.calls
            XCTAssertEqual(initial, 1)
            let recovered = try await service.refreshIfNeeded()
            XCTAssertEqual(recovered.rate(for: "USD"), 1)
            let total = await feed.calls
            XCTAssertEqual(total, 2)
        }
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
            catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let network = URLSessionRateTransport(session: session)
        for status in [403, 429, 503] {
            do {
                _ = try await network.data(from: URL(string: "https://cdn.jsdelivr.net/\(status)")!)
                XCTFail("Failed status was accepted")
            } catch { XCTAssertEqual((error as NSError).code, status) }
        }
        do {
            _ = try await network.data(from: URL(string: "https://cdn.jsdelivr.net/untrusted-certificate")!)
            XCTFail("A certificate failure must reach the caller")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .serverCertificateUntrusted)
        }
        // Access denial reaches the local recorder. Its existing policy filters certificate transport errors.
        for error in [NSError(domain: "Oath.HTTP", code: 403), NSError(domain: NSURLErrorDomain, code: -1202)] {
            OathDiagnostics.record(error, component: "prices", operation: "exchange_rates",
                                   context: ["stage": "feed_request", "host": "cdn.jsdelivr.net"],
                                   file: "OathExchangeRates/ExchangeRateService.swift")
        }
        OathDiagnostics.record(ExchangeRateError.invalidResponse, component: "prices", operation: "fixture_validation")
        for _ in 0..<200 {
            await OathDiagnostics.flush()
            let received = await reports.events
            if received.contains(where: { $0.operation == "fixture_validation" }),
               received.contains(where: { $0.component == "network" && $0.error.code == 403 }),
               received.contains(where: { $0.operation == "exchange_rates" && $0.error.code == 403 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await reports.events
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.filter { $0.component == "network" }.map(\.error.code), [403])
        XCTAssertEqual(Set(events.filter { $0.operation == "exchange_rates" }.map(\.error.code)), [403])
        XCTAssertEqual(events.filter { $0.operation == "fixture_validation" }.map(\.error.message), ["invalidResponse"])
    }

    func testSharedFailureReportsEachFeedOnceAcrossWaitersAndBackoff() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FX_SHARED_FAILURE_TEST"] == "1" else {
            throw XCTSkip("Run alone to isolate the diagnostics outbox")
        }
        let reports = RateDiagnosticReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let db = try await database(), transport = FixtureTransport(Data("{}".utf8)), date = now
        let service = ExchangeRateService(database: db, transport: transport, now: { date })
        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do { _ = try await service.refreshIfNeeded(); return false }
                    catch { return error is DecodingError }
                }
            }
            var results = [Bool]()
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(failures, Array(repeating: true, count: 8))
        do { _ = try await service.refreshIfNeeded(); XCTFail("Expected failure during backoff") }
        catch { XCTAssertTrue(error is DecodingError) }
        let requests = await transport.requests
        XCTAssertEqual(requests, 2)
        for _ in 0..<200 {
            if await reports.events.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await reports.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.compactMap { $0.context["host"] }), Set(ExchangeRateFeed.endpoints.compactMap(\.host)))
        XCTAssertEqual(Set(events.compactMap { $0.context["stage"] }), ["feed_decode"])
        XCTAssertEqual(Set(events.map(\.operationID)).count, 1)
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
    override class func canInit(with request: URLRequest) -> Bool { ["fixture.invalid", "cdn.jsdelivr.net"].contains(request.url?.host) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.lastPathComponent == "untrusted-certificate" {
            client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted))
            return
        }
        let status = Int(request.url!.lastPathComponent)!
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: status == 200 ? Data(repeating: 32, count: 131_073) : Data("<html>HTTP failure</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
