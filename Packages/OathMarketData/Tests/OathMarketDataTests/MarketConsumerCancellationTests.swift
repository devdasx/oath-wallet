import Foundation
import XCTest
import OathDatabase
@testable import OathMarketData

private actor HeldMarketInformation: MarketTransport {
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private(set) var calls = 0
    let started: [XCTestExpectation]

    init(started: XCTestExpectation...) { self.started = started }

    func data(from url: URL) async throws -> Data {
        calls += 1
        let id = calls
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if id <= started.count { started[id - 1].fulfill() }
        }
    }

    func finish(_ id: Int, description: String = "Shared information", failure: (any Error)? = nil) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let failure { continuation.resume(throwing: failure) }
        else {
            let data = Data("{\"id\":\"ethereum\",\"name\":\"Ethereum\",\"symbol\":\"eth\",\"description\":{\"en\":\"\(description)\"},\"links\":{\"homepage\":[\"https://ethereum.org\"]},\"image\":{}}".utf8)
            continuation.resume(returning: data)
        }
    }
}

private struct CancellableMarketInformation: MarketTransport {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    func data(from url: URL) async throws -> Data {
        started.fulfill()
        do { try await Task.sleep(for: .seconds(5)); XCTFail("Unused provider was not cancelled") }
        catch { XCTAssertTrue(error is CancellationError); cancelled.fulfill(); throw error }
        return Data()
    }
}

@MainActor final class MarketConsumerCancellationTests: XCTestCase {
    private let asset = MarketAsset(id: "ethereum:native", networkID: "ethereum", reference: "native", decimals: 18)

    func testClosedScreenReturnsBeforeUncooperativeProviderFinishes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let started = expectation(description: "Public request started")
        let stopped = expectation(description: "Closed screen returned before provider completion")
        let feed = HeldMarketInformation(started: started)
        let service = MarketDataService(database: db, transport: feed), asset = asset
        let screen = Task {
            do { _ = try await service.information(for: asset); XCTFail("Closed screen returned data") }
            catch { XCTAssertTrue(error is CancellationError) }
            stopped.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        screen.cancel()
        await fulfillment(of: [stopped], timeout: 1)
        await feed.finish(1)
        await screen.value
    }

    func testCancellingEitherConsumerPreservesOneRequestForTheOtherScreen() async throws {
        for cancelOriginal in [true, false] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
            let started = expectation(description: "Shared request started")
            let stopped = expectation(description: "One screen cancelled independently")
            let feed = HeldMarketInformation(started: started)
            let service = MarketDataService(database: db, transport: feed), asset = asset
            let first = Task { try await service.information(for: asset) }
            await fulfillment(of: [started], timeout: 2)
            let second = Task { try await service.information(for: asset) }
            // Allow the second public caller to join the still-held request.
            try await Task.sleep(for: .milliseconds(30))
            let closed = cancelOriginal ? first : second
            let survivor = cancelOriginal ? second : first
            let observed = Task {
                do { _ = try await closed.value; XCTFail("Cancelled screen received data") }
                catch { XCTAssertTrue(error is CancellationError) }
                stopped.fulfill()
            }
            closed.cancel()
            await fulfillment(of: [stopped], timeout: 1)
            await feed.finish(1)
            await observed.value
            let value = try await survivor.value
            XCTAssertEqual(value.value.description, "Shared information")
            let cached = try await service.information(for: asset)
            XCTAssertEqual(cached.value, value.value)
            let calls = await feed.calls
            XCTAssertEqual(calls, 1, "A remaining consumer keeps the original public request and cache")
        }
    }

    func testLastConsumerCancellationStopsCancellableTransport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let started = expectation(description: "Provider started"), stopped = expectation(description: "Provider cancelled")
        let service = MarketDataService(database: db, transport: CancellableMarketInformation(started: started, cancelled: stopped)), asset = asset
        let screen = Task { try await service.information(for: asset) }
        await fulfillment(of: [started], timeout: 2)
        screen.cancel()
        await fulfillment(of: [stopped], timeout: 1)
        do { _ = try await screen.value; XCTFail("Cancelled request succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let stored = try await service.cachedInformation(for: asset)
        XCTAssertNil(stored, "Cancelled transport cannot create a cache entry")
    }

    func testLateCancelledFailureCannotPoisonReplacementFlightOrBackoff() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let firstStarted = expectation(description: "Old request started"), newStarted = expectation(description: "Replacement started")
        let stopped = expectation(description: "Old consumer returned")
        let feed = HeldMarketInformation(started: firstStarted, newStarted)
        let service = MarketDataService(database: db, transport: feed), asset = asset
        let first = Task {
            do { _ = try await service.information(for: asset); XCTFail("Cancelled request succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            stopped.fulfill()
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.cancel()
        await fulfillment(of: [stopped], timeout: 1)
        let replacement = Task { try await service.information(for: asset) }
        await fulfillment(of: [newStarted], timeout: 2)
        await feed.finish(1, failure: MarketDataError.rateLimited)
        await first.value
        try await Task.sleep(for: .milliseconds(30))
        let joiner = Task { try await service.information(for: asset) }
        try await Task.sleep(for: .milliseconds(30))
        await feed.finish(2, description: "Replacement information")
        let values = try await (replacement.value, joiner.value)
        XCTAssertEqual(values.0.value.description, "Replacement information")
        XCTAssertEqual(values.0.value, values.1.value)
        let calls = await feed.calls
        XCTAssertEqual(calls, 2, "Late cancellation must not erase the replacement flight")
    }

    func testLateCancelledSuccessCannotOverwriteNewerPublicCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: url)
        let firstStarted = expectation(description: "Old request started"), newStarted = expectation(description: "New request started")
        let stopped = expectation(description: "Old consumer returned")
        let feed = HeldMarketInformation(started: firstStarted, newStarted)
        let service = MarketDataService(database: db, transport: feed), asset = asset
        let first = Task {
            do { _ = try await service.information(for: asset); XCTFail("Cancelled request succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            stopped.fulfill()
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.cancel()
        await fulfillment(of: [stopped], timeout: 1)
        let replacement = Task { try await service.information(for: asset) }
        await fulfillment(of: [newStarted], timeout: 2)
        await feed.finish(2, description: "Replacement information")
        let value = try await replacement.value
        await feed.finish(1, description: "Obsolete information")
        await first.value
        try await Task.sleep(for: .milliseconds(30))
        let reopened = try await OathDatabase.open(at: url)
        let stored = try await MarketDataService(database: reopened, transport: feed).cachedInformation(for: asset)
        XCTAssertEqual(stored?.value.description, "Replacement information")
        XCTAssertEqual(stored?.fetchedAt, value.fetchedAt)
    }
}
