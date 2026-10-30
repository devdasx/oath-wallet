import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor InterruptedStellarMarketFeed: AnkrTransport {
    var failure: (any Error)?
    var requests = 0
    init(_ failure: (any Error)? = nil) { self.failure = failure }
    func resume() { failure = nil }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests += 1
        if let failure { throw failure }
        if request.url!.path.contains("/coins/list") {
            return (try Data(contentsOf: Bundle.module.url(forResource: "catalog", withExtension: "json", subdirectory: "Fixtures/Stellar")!), 200)
        }
        if request.url!.host == "api.coinbase.com" {
            return (Data(#"{"data":{"base":"XLM","currency":"USD","amount":"0.2"}}"#.utf8), 200)
        }
        return (Data("{\"stellar\":{\"usd\":0.2,\"last_updated_at\":\(Int(Date().timeIntervalSince1970))}}".utf8), 200)
    }
}

private actor HeldStellarMarketFeed: AnkrTransport {
    var pending: CheckedContinuation<Void, Never>?
    var hold = true
    var requests = 0
    func release() { hold = false; pending?.resume(); pending = nil }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests += 1
        if hold {
            await withCheckedContinuation { pending = $0 }
            return (Data(), 429)
        }
        return (Data("{\"stellar\":{\"usd\":0.2,\"last_updated_at\":\(Int(Date().timeIntervalSince1970))}}".utf8), 200)
    }
}

private actor HeldStellarAlternative {
    var pending: CheckedContinuation<Void, Never>?
    func release() { pending?.resume(); pending = nil }
    func price() async -> StellarPrice {
        await withCheckedContinuation { pending = $0 }
        return .init(reference: "native", usd: "0.2", source: "fixture", fetchedAt: .now)
    }
}

@MainActor final class StellarMarketCancellationTests: XCTestCase {
    private let catalog = StellarCatalog(ids: ["native": "stellar"])

    func testIndependentCancellationDoesNotCreateCatalogBackoffOrPublishFallback() async throws {
        for error in [CancellationError() as any Error, URLError(.cancelled)] {
            let feed = InterruptedStellarMarketFeed(error), markets = StellarMarkets(transport: feed)
            do { _ = try await markets.catalog(fallback: catalog); XCTFail("Cancelled catalogue became success") }
            catch { XCTAssertTrue(error is CancellationError) }
            let updated = await markets.catalogUpdatedAt
            XCTAssertNil(updated)
            await feed.resume()
            let recovered = try await markets.catalog()
            XCTAssertGreaterThan(recovered.ids.count, 40, "A cancelled read cannot impose five minutes of failure backoff")
            _ = try await markets.catalog()
            let count = await feed.requests
            XCTAssertEqual(count, 2, "Successful retry should still be cached")
        }
    }

    func testIndependentNativeAndTokenCancellationRetainCancellationIdentity() async throws {
        for error in [CancellationError() as any Error, URLError(.cancelled)] {
            let feed = InterruptedStellarMarketFeed(error), markets = StellarMarkets(transport: feed)
            do {
                _ = try await markets.nativePrice { XCTFail("Cancelled native request started a fallback"); return nil }
                XCTFail("Cancelled native request returned a quote")
            } catch { XCTAssertTrue(error is CancellationError) }
            do { _ = try await markets.prices(references: ["native"], catalog: catalog); XCTFail("Cancelled token read returned success") }
            catch { XCTAssertTrue(error is CancellationError) }
            let count = await feed.requests
            XCTAssertEqual(count, 2)
        }
    }

    func testIndependentAlternativeCancellationStopsBeforeCoinGecko() async throws {
        let feed = InterruptedStellarMarketFeed(URLError(.timedOut)), markets = StellarMarkets(transport: feed)
        do { _ = try await markets.nativePrice { throw URLError(.cancelled) }; XCTFail("Cancelled alternative returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await feed.requests
        XCTAssertEqual(count, 1)
    }

    func testLateCancelledRateLimitCannotPoisonNextPriceRead() async throws {
        let feed = HeldStellarMarketFeed(), markets = StellarMarkets(transport: feed)
        let catalog = catalog
        let work = Task { try await markets.prices(references: ["native"], catalog: catalog) }
        for _ in 0..<200 {
            if await feed.pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = await feed.pending != nil
        XCTAssertTrue(pending)
        work.cancel(); await feed.release()
        do { _ = try await work.value; XCTFail("Cancelled response returned prices") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = try await markets.prices(references: ["native"], catalog: catalog)
        XCTAssertEqual(next.first?.usd, "0.2")
        let count = await feed.requests
        XCTAssertEqual(count, 2, "Cancelled response must not set the five-minute CoinGecko cooldown")
    }

    func testLateAlternativeDoesNotPublishAfterCallerCancellation() async throws {
        let feed = InterruptedStellarMarketFeed(URLError(.timedOut)), markets = StellarMarkets(transport: feed)
        let alternative = HeldStellarAlternative()
        let work = Task { try await markets.nativePrice { await alternative.price() } }
        for _ in 0..<200 {
            if await alternative.pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = await alternative.pending != nil
        XCTAssertTrue(pending)
        work.cancel(); await alternative.release()
        do { _ = try await work.value; XCTFail("Cancelled caller received a late quote") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await feed.requests
        XCTAssertEqual(count, 1)
    }
}

private actor StellarCancellationReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

@MainActor final class StellarMarketCancellationDiagnosticsTests: XCTestCase {
    func testCancellationStaysQuietWhileRealOutageRetainsOriginalAndBoundaryReports() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = StellarCancellationReports()
        OathDiagnostics.configure(file: folder.appendingPathComponent("events.json"), transport: reports)
        for error in [CancellationError() as any Error, URLError(.cancelled)] {
            let markets = StellarMarkets(transport: InterruptedStellarMarketFeed(error))
            do { _ = try await markets.catalog(); XCTFail("Cancelled catalogue returned success") }
            catch { XCTAssertTrue(error is CancellationError) }
            do { _ = try await markets.nativePrice(); XCTFail("Cancelled quote returned success") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        let markets = StellarMarkets(transport: InterruptedStellarMarketFeed(URLError(.timedOut)))
        let value = try await OathDiagnostics.withChain("stellar") {
            try await markets.nativePrice { .init(reference: "native", usd: "0.2", source: "fixture", fetchedAt: .now) }
        }
        XCTAssertEqual(value.usd, "0.2")
        for _ in 0..<100 {
            if await reports.events.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.filter { $0.error.domain == NSURLErrorDomain && $0.error.code == URLError.timedOut.rawValue }.count, 1)
        XCTAssertEqual(events.filter { $0.error.domain == "OathAnkr.StellarError" && $0.error.code == (StellarError.transport as NSError).code }.count, 1)
        let operation = try XCTUnwrap(events.first?.operationID)
        XCTAssertTrue(events.allSatisfy { $0.operationID == operation && $0.context["chain"] == "stellar" && $0.privacyFiltered })
    }
}
