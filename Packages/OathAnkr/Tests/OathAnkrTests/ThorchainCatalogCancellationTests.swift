import Foundation
import XCTest
@testable import OathAnkr

private actor HeldThorchainCatalog {
    var started = false
    private var continuation: CheckedContinuation<ThorchainCatalog, Never>?
    func load() async -> ThorchainCatalog {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        var value = ThorchainCatalog(); value.prices["native"] = "1"
        continuation?.resume(returning: value); continuation = nil
    }
}

final class ThorchainCatalogCancellationTests: XCTestCase, @unchecked Sendable {
    func testCancelledRefreshDoesNotWaitForOtherWalletsMarketRequest() async throws {
        let cache = ThorchainCatalogRequests(), held = HeldThorchainCatalog()
        let cancelled = expectation(description: "Cancelled refresh finishes before the public request")
        let first = Task {
            do { _ = try await cache.value { await held.load() }; XCTFail("Cancelled refresh returned a catalog") }
            catch { XCTAssertTrue(error is CancellationError) }
            cancelled.fulfill()
        }
        while !(await held.started) { await Task.yield() }
        let second = Task {
            try await cache.value { XCTFail("Concurrent wallets must share a catalog read"); return ThorchainCatalog() }
        }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        await held.finish()
        await first.value
        let value = try await second.value
        XCTAssertEqual(value.prices["native"], "1")
        let cached = try await cache.value { XCTFail("Successful shared result must remain cached"); return ThorchainCatalog() }
        XCTAssertEqual(cached.prices["native"], "1")
    }

    func testCancelledJoinerReturnsWhileOriginalConsumerContinues() async throws {
        let cache = ThorchainCatalogRequests(), held = HeldThorchainCatalog()
        let first = Task { try await cache.value { await held.load() } }
        while !(await held.started) { await Task.yield() }
        let cancelled = expectation(description: "Joining consumer cancels independently")
        let second = Task {
            do { _ = try await cache.value { XCTFail("Duplicated read"); return ThorchainCatalog() }; XCTFail() }
            catch { XCTAssertTrue(error is CancellationError) }
            cancelled.fulfill()
        }
        try await Task.sleep(for: .milliseconds(20))
        second.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        await held.finish()
        await second.value
        let value = try await first.value
        XCTAssertEqual(value.prices["native"], "1")
    }

    func testLateCancelledReadCannotReplaceNewCatalog() async throws {
        let cache = ThorchainCatalogRequests(), held = HeldThorchainCatalog()
        let cancelled = expectation(description: "Last consumer does not wait for an uncooperative transport")
        let old = Task {
            do { _ = try await cache.value { await held.load() }; XCTFail() }
            catch { XCTAssertTrue(error is CancellationError) }
            cancelled.fulfill()
        }
        while !(await held.started) { await Task.yield() }
        old.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        var replacement = ThorchainCatalog(); replacement.prices["native"] = "9"
        let expected = replacement
        let fresh = try await cache.value { expected }
        XCTAssertEqual(fresh.prices["native"], "9")
        await held.finish()
        await old.value
        // Let the cancelled producer's completion reach the catalog actor.
        try await Task.sleep(for: .milliseconds(20))
        let cached = try await cache.value { XCTFail("Late completion removed the new cache"); return ThorchainCatalog() }
        XCTAssertEqual(cached.prices["native"], "9")
    }

    func testLastConsumerCancellationStopsProducerWork() async throws {
        let cache = ThorchainCatalogRequests()
        let started = expectation(description: "Producer started"), stopped = expectation(description: "Producer cancelled")
        let job = Task {
            do {
                _ = try await cache.value {
                    started.fulfill()
                    do { try await Task.sleep(for: .seconds(60)); XCTFail("Unneeded network work continued") }
                    catch { XCTAssertTrue(error is CancellationError); stopped.fulfill(); throw error }
                    return ThorchainCatalog()
                }
                XCTFail()
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await fulfillment(of: [started], timeout: 1)
        job.cancel()
        await fulfillment(of: [stopped], timeout: 1)
        await job.value
    }
}
