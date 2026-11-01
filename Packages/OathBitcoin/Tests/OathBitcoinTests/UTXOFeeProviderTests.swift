import Foundation
import XCTest
import OathDiagnostics
@testable import OathBitcoin

private actor FeeCounter {
    var count = 0
    func increment() { count += 1 }
}
private actor FeeReports: DiagnosticTransport {
    let invalidQuoteID: UUID
    let invalidSource = XCTestExpectation(description: "Invalid fee source reported")
    let invalidFallback = XCTestExpectation(description: "Invalid fee fallback reported")
    let unexpected = XCTestExpectation(description: "A timeout was reported as an invalid fee")

    init(invalidQuoteID: UUID) {
        self.invalidQuoteID = invalidQuoteID
        unexpected.isInverted = true
    }

    func upload(_ events: [DiagnosticEvent]) async throws {
        for event in events {
            if event.operationID != invalidQuoteID { unexpected.fulfill(); continue }
            if event.operation == "fee_source" { invalidSource.fulfill() }
            if event.operation == "fee_primary_fallback" { invalidFallback.fulfill() }
        }
    }
}
final class UTXOFeeProviderTests: XCTestCase, @unchecked Sendable {
    func testPreferredFailoverPreservesAvailabilityAndInvalidQuoteDiagnostics() async throws {
        let invalidQuoteID = UUID()
        let reports = FeeReports(invalidQuoteID: invalidQuoteID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Diagnostics configuration is process-lifetime: use one sink for all
        // cases, with this test selected in a fresh host-test process.
        OathDiagnostics.configure(file: directory.appendingPathComponent("events.json"), transport: reports)
        for fault in 0..<3 {
            // Only the intentionally hung source races a short timer. The invalid
            // quote must reach fee validation even on a busy test runner.
            let provider = UTXOFeeProvider(deadline: .seconds(30),
                preferredDeadline: fault == 1 ? .milliseconds(20) : .seconds(30), preferred: { _ in
                .init(name: "preferred.test", delay: .zero) {
                    if fault == 1 { try await Task.sleep(for: .seconds(10)) }
                    if fault == 2 { return Int64.max }
                    throw URLError(.timedOut)
                }
            }) { _ in [.init(name: "fallback.test", delay: .zero) { 2000 }] }
            let quote = try await OathDiagnostics.$operationID.withValue(fault == 2 ? invalidQuoteID : UUID()) {
                try await provider.rate(for: .bitcoin)
            }
            XCTAssertEqual(quote, 2000)
        }
        await fulfillment(of: [reports.invalidSource, reports.invalidFallback], timeout: 10)
        await fulfillment(of: [reports.unexpected], timeout: 0.2)
    }

    func testPreferredSuccessAvoidsPublicAPIsAndServersAndIsCached() async throws {
        let primary = FeeCounter(), fallback = FeeCounter(), servers = FeeCounter()
        let provider = UTXOFeeProvider(preferred: { _ in
            .init(name: "preferred", delay: .milliseconds(20)) { await primary.increment(); return 1073 }
        }, lastResort: { _ in [
            .init(name: "server", delay: .zero) { await servers.increment(); return 3000 }
        ] }) { _ in [
            .init(name: "public", delay: .zero) { await fallback.increment(); return 2000 }
        ] }
        async let first = provider.rate(for: .bitcoin)
        async let second = provider.rate(for: .bitcoin)
        let rates = try await [first, second]
        XCTAssertEqual(rates, [1073, 1073])
        let cached = try await provider.rate(for: .bitcoin)
        XCTAssertEqual(cached, 1073)
        let counts = await [primary.count, fallback.count, servers.count]
        XCTAssertEqual(counts, [1, 0, 0])
    }

    func testFailedOrInvalidPreferredFallsBackImmediately() async throws {
        for invalid in [false, true] {
            let provider = UTXOFeeProvider(preferredDeadline: .seconds(2), preferred: { _ in
                .init(name: "preferred", delay: .zero) {
                    if invalid { return Int64.max }
                    throw URLError(.userAuthenticationRequired)
                }
            }) { _ in [.init(name: "public", delay: .zero) { 2000 }] }
            let start = ContinuousClock.now
            let rate = try await provider.rate(for: .bitcoin)
            XCTAssertEqual(rate, 2000)
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        }
    }

    func testHungPreferredIsCanceledAndCannotDelayPublicFallback() async throws {
        let canceled = FeeCounter()
        let provider = UTXOFeeProvider(preferredDeadline: .milliseconds(30), preferred: { _ in
            .init(name: "preferred", delay: .zero) {
                do { try await Task.sleep(for: .seconds(10)); return 1073 }
                catch { await canceled.increment(); throw error }
            }
        }) { _ in [.init(name: "public", delay: .zero) { 2000 }] }
        let start = ContinuousClock.now
        let rate = try await provider.rate(for: .bitcoin)
        XCTAssertEqual(rate, 2000)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let count = await canceled.count
        XCTAssertEqual(count, 1)
    }

    func testServersRunOnlyAfterBothAPIStagesFailForEveryChain() async throws {
        for chain in UTXONetwork.allCases {
            let calls = FeeCounter(), floor = chain.sendFeeRates.lowerBound
            let provider = UTXOFeeProvider(preferred: { _ in
                .init(name: "preferred", delay: .zero) { await calls.increment(); throw URLError(.timedOut) }
            }, lastResort: { _ in [
                .init(name: "server", delay: .zero) {
                    let count = await calls.count
                    XCTAssertEqual(count, 2)
                    return floor
                }
            ] }) { _ in [
                .init(name: "public", delay: .zero) { await calls.increment(); throw URLError(.timedOut) }
            ] }
            let rate = try await provider.rate(for: chain)
            XCTAssertEqual(rate, floor)
        }
    }

    func testSlowFailedAndInvalidSourcesCannotBlockHealthyFee() async throws {
        for network in UTXONetwork.allCases {
            let floor = network.sendFeeRates.lowerBound
            let provider = UTXOFeeProvider { _ in [
                .init(name: "slow", delay: .zero) { try await Task.sleep(for: .seconds(10)); return floor },
                .init(name: "invalid", delay: .zero) { Int64.max },
                .init(name: "failed", delay: .zero) { throw URLError(.cannotConnectToHost) },
                .init(name: "healthy", delay: .milliseconds(20)) { floor + 1 }
            ] }
            let started = ContinuousClock.now
            let rate = try await provider.rate(for: network)
            XCTAssertEqual(rate, floor + 1)
            XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        }
    }
    func testConcurrentRequestsCoalesceCacheExpiresAndChainsStaySeparate() async throws {
        let calls = FeeCounter()
        let provider = UTXOFeeProvider(lifetime: .milliseconds(40)) { network in [
            .init(name: "fixture", delay: .zero) {
                await calls.increment(); try await Task.sleep(for: .milliseconds(20))
                return network.sendFeeRates.lowerBound
            }
        ] }
        try await withThrowingTaskGroup(of: Int64.self) { group in
            for _ in 0..<20 { group.addTask { try await provider.rate(for: .bitcoin) } }
            for try await rate in group { XCTAssertEqual(rate, 1000) }
        }
        _ = try await provider.rate(for: .bitcoin)
        let first = await calls.count; XCTAssertEqual(first, 1)
        let doge = try await provider.rate(for: .dogecoin); XCTAssertEqual(doge, 1_000_000)
        try await Task.sleep(for: .milliseconds(50))
        _ = try await provider.rate(for: .bitcoin)
        let last = await calls.count; XCTAssertEqual(last, 3)
    }
    func testOutageHasDeadlineAndDoesNotCacheFailure() async throws {
        let calls = FeeCounter()
        let provider = UTXOFeeProvider(deadline: .milliseconds(30)) { _ in [
            .init(name: "hung", delay: .zero) {
                await calls.increment(); try await Task.sleep(for: .seconds(10)); return 1000
            }
        ] }
        let started = ContinuousClock.now
        for _ in 0..<2 {
            do { _ = try await provider.rate(for: .bitcoin); XCTFail("Invented a fee") }
            catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        }
        let count = await calls.count; XCTAssertEqual(count, 2)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }
    func testExhaustedProvidersKeepGenuineRejectionInsteadOfAvailability() async throws {
        let calls = FeeCounter()
        let provider = UTXOFeeProvider { _ in [
            .init(name: "rejected.test", delay: .zero) {
                await calls.increment()
                throw NSError(domain: "Oath.HTTP", code: 401)
            }
        ] }
        for _ in 0..<2 {
            do { _ = try await provider.rate(for: .bitcoin); XCTFail("A rejection cannot produce a quote") }
            catch {
                XCTAssertEqual((error as NSError).domain, "Oath.HTTP")
                XCTAssertEqual((error as NSError).code, 401)
            }
        }
        let count = await calls.count
        XCTAssertEqual(count, 2, "Failed quotes must not be cached")
    }
    func testCanceledWaiterDoesNotCancelOtherWalletsFee() async throws {
        let provider = UTXOFeeProvider { _ in [.init(name: "fixture", delay: .milliseconds(40)) { 1000 }] }
        let canceled = Task { try await provider.rate(for: .bitcoin) }
        try await Task.sleep(for: .milliseconds(10)); canceled.cancel()
        let healthy = try await provider.rate(for: .bitcoin); XCTAssertEqual(healthy, 1000)
        do { _ = try await canceled.value; XCTFail() } catch is CancellationError { }
    }
    func testBlockcypherValidatesIdentityFreshnessAndAtomicUnits() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-13T09:00:00Z")!
        func data(_ name: String = "DOGE.main", _ rate: String = "48642975", _ time: String = "2026-10-13T08:59:00.123456789Z") -> Data {
            Data("{\"name\":\"\(name)\",\"medium_fee_per_kb\":\(rate),\"time\":\"\(time)\"}".utf8)
        }
        XCTAssertEqual(try UTXOFeeProvider.decodeBlockcypher(data(), network: .dogecoin, now: now), 48_642_975)
        XCTAssertEqual(try UTXOFeeProvider.decodeBlockcypher(data("LTC.main", "9619"), network: .litecoin, now: now), 9619)
        for invalid in [data("BTC.main"), data("DOGE.main", "-1"), data("DOGE.main", "100000001"), data("DOGE.main", "1.5"),
                        data("DOGE.main", "1000000", "2026-10-12T09:00:00Z"), data("DOGE.main", "1000000", "2026-10-14T09:00:00Z")] {
            XCTAssertThrowsError(try UTXOFeeProvider.decodeBlockcypher(invalid, network: .dogecoin, now: now))
        }
    }
    func testLiveAllChainsRepeatedColdAndCachedQuotes() async throws {
        guard ProcessInfo.processInfo.environment["OATH_UTXO_FEES_LIVE"] == "1" else { throw XCTSkip("Read-only live mainnet fees, no wallet/transaction data") }
        for round in 1...3 {
            let provider = UTXOFeeProvider()
            for chain in UTXONetwork.allCases {
                let started = ContinuousClock.now
                let rate = try await provider.rate(for: chain)
                XCTAssertTrue(chain.sendFeeRates.contains(rate))
                let duration = started.duration(to: .now)
                let cachedStart = ContinuousClock.now
                let cached = try await provider.rate(for: chain)
                XCTAssertEqual(cached, rate)
                XCTAssertLessThan(cachedStart.duration(to: .now), .milliseconds(100))
                print("LIVE FEE round=\(round) chain=\(chain.rawValue) atomic/kVB=\(rate) duration=\(duration)")
            }
        }
    }
}
