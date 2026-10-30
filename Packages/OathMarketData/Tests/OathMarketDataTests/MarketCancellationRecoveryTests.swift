import XCTest
import OathDatabase
import OathDiagnostics
@testable import OathMarketData

private actor InterruptedInformationFeed: MarketTransport {
    let firstFailure: any Error
    var calls = 0
    init(_ failure: any Error) { firstFailure = failure }
    func data(from url: URL) async throws -> Data {
        calls += 1
        if calls == 1 { throw firstFailure }
        return Data(#"{"id":"ethereum","name":"Ethereum","symbol":"eth","description":{"en":"Network"},"links":{"homepage":["https://ethereum.org"]},"image":{}}"#.utf8)
    }
}

private actor InterruptedQuoteFeed: MarketTransport {
    let firstFailure: any Error
    var interrupted = true
    var calls = 0
    init(_ failure: any Error = URLError(.cancelled)) { firstFailure = failure }
    func resume() { interrupted = false }
    func data(from url: URL) async throws -> Data {
        calls += 1
        if interrupted { throw firstFailure }
        if url.host == "api.coinbase.com" {
            return Data(#"{"data":{"base":"ETH","currency":"USD","amount":"2000"}}"#.utf8)
        }
        throw MarketDataError.notListed
    }
}

@MainActor final class MarketCancellationRecoveryTests: XCTestCase {
    private let asset = MarketAsset(id: "ethereum:native", networkID: "ethereum", reference: "native", decimals: 18)

    func testLocalDeferralDoesNotCreateAnotherOutageDeadline() async throws {
        for deferral in [DiagnosticDeferral.publicMarketCooldown, .publicMarketCapacity] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
            let feed = InterruptedInformationFeed(deferral)
            let service = MarketDataService(database: db, transport: feed)
            do { _ = try await service.information(for: asset); XCTFail("Deferred read returned data") }
            catch { XCTAssertEqual(error as? DiagnosticDeferral, deferral) }
            let recovered = try await service.information(for: asset)
            XCTAssertEqual(recovered.value.name, "Ethereum")
            let calls = await feed.calls
            XCTAssertEqual(calls, 2, "Only the scheduler owns the cooldown deadline")
        }
    }

    func testQuoteRacePreservesLocalDeferralAndRealProviderFailure() async throws {
        let deferred = ParallelMarketPrice.Candidate(source: "Deferred") { throw DiagnosticDeferral.publicMarketCooldown }
        let missing = ParallelMarketPrice.Candidate(source: "Optional") { throw MarketDataError.notListed }
        do { _ = try await ParallelMarketPrice.first([deferred, missing], network: "ethereum"); XCTFail() }
        catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
        let failed = ParallelMarketPrice.Candidate(source: "Outage") { throw MarketDataError.unavailable }
        do { _ = try await ParallelMarketPrice.first([deferred, failed], network: "ethereum"); XCTFail() }
        catch { XCTAssertEqual(error as? MarketDataError, .unavailable) }
        let healthy = ParallelMarketPrice.Candidate(source: "Healthy") {
            .init(quote: .init(code: "ETH", usd: "2000"), date: .now, source: "Healthy")
        }
        let recovered = try await ParallelMarketPrice.first([deferred, healthy], network: "ethereum")
        XCTAssertEqual(recovered.quote.usd, "2000")
    }

    func testInterruptedReadCanRetryImmediatelyWithoutSyntheticUnavailable() async throws {
        for failure in [CancellationError() as any Error, URLError(.cancelled)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
            let feed = InterruptedInformationFeed(failure)
            let service = MarketDataService(database: db, transport: feed)
            do { _ = try await service.information(for: asset); XCTFail("Cancellation ignored") }
            catch { XCTAssertTrue(error is CancellationError) }
            let recovered = try await service.information(for: asset)
            XCTAssertEqual(recovered.value.name, "Ethereum")
            let calls = await feed.calls
            XCTAssertEqual(calls, 2, "Cancellation is not a provider outage and must not throttle the next screen")
        }
    }

    func testAlreadyCancelledCallerDoesNotStartProviderWork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let feed = InterruptedInformationFeed(MarketDataError.rateLimited)
        let service = MarketDataService(database: db, transport: feed), asset = asset
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await service.information(for: asset); XCTFail("Cancelled read proceeded") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
        let calls = await feed.calls
        XCTAssertEqual(calls, 0)
    }

    func testRealProviderFailureStillBlocksRepeatedForcedReads() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let feed = InterruptedInformationFeed(MarketDataError.rateLimited)
        let service = MarketDataService(database: db, transport: feed)
        for _ in 0..<5 {
            do { _ = try await service.information(for: asset, force: true); XCTFail("Outage backoff bypassed") }
            catch { XCTAssertEqual(error as? MarketDataError, .rateLimited) }
        }
        let calls = await feed.calls
        XCTAssertEqual(calls, 1)
    }

    func testInterruptedOrDeferredQuoteRaceCanImmediatelyRetryAndPersistRecoveredPrice() async throws {
      for interruption in [URLError(.cancelled) as any Error, DiagnosticDeferral.publicMarketCooldown, DiagnosticDeferral.publicMarketCapacity] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        try await db.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH",
            decimals: 18, derivationPath: "fixture", logo: "", sortOrder: 0)], assets: [
                .init(id: asset.id, networkID: asset.networkID, reference: asset.reference,
                    name: "Ethereum", symbol: "ETH", decimals: 18)
            ])
        let feed = InterruptedQuoteFeed(interruption), service = MarketDataService(database: db, transport: feed)
        do { _ = try await service.quote(for: asset); XCTFail("Interrupted reads returned a price") }
        catch {
            if let deferral = interruption as? DiagnosticDeferral { XCTAssertEqual(error as? DiagnosticDeferral, deferral) }
            else { XCTAssertTrue(error is CancellationError) }
        }
        let failedPrice = try await db.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertNil(failedPrice)
        await feed.resume()
        let result = try await service.quote(for: asset)
        XCTAssertEqual(result.value.usd, "2000")
        let saved = try await db.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertEqual(saved?.value, "2000")
        XCTAssertEqual(saved?.source, "Coinbase")
        let calls = await feed.calls
        _ = try await service.quote(for: asset)
        let cachedCalls = await feed.calls
        XCTAssertEqual(cachedCalls, calls, "The recovered quote must use the ordinary cache")
      }
    }
}
