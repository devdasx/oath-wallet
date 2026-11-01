import XCTest
import Combine
@testable import Schemas
import WalletConnectNetworking

final class SessionCleanupLifetimeTests: XCTestCase {
    private func history() -> RPCHistory {
        RPCHistoryFactory.createForNetwork(keyValueStorage: RuntimeKeyValueStorage())
    }
    private func service(_ history: RPCHistory, queue: DispatchQueue) -> HistoryService {
        HistoryService(history: history,
            verifyContextStore: CodableStore(defaults: RuntimeKeyValueStorage(), identifier: "synthetic-context"),
            cleanupQueue: queue)
    }
    private func add(_ id: Int64, topic: String, to history: RPCHistory, expired: Bool = false) throws {
        let request = SessionType.RequestParams(request: .init(method: "synthetic",
            params: AnyCodable([String]()), expiryTimestamp: expired ? 1 : UInt64(Date().timeIntervalSince1970) + 3600),
            chainId: Blockchain("eip155:1")!)
        try history.set(RPCRequest(method: "wc_sessionRequest", params: request, rpcid: RPCID(id)),
            forTopic: topic, emmitedBy: .remote, transportType: .relay)
    }

    func testQueuedCleanupOutlivesReleasedService() throws {
        let rpc = history(); try add(41, topic: "synthetic-a", to: rpc); try add(42, topic: "synthetic-b", to: rpc)
        let queue = DispatchQueue(label: "synthetic.cleanup.released")
        queue.suspend(); var resumed = false
        defer { if !resumed { queue.resume() } }
        var owner: HistoryService? = service(rpc, queue: queue)
        weak var released = owner
        owner?.removePendingRequest(topic: "synthetic-a")
        // Work must be scheduled, not awaited, and remain pending while the queue is held.
        XCTAssertNotNil(rpc.get(recordId: RPCID(41)))
        owner = nil; XCTAssertNil(released, "Cleanup must not retain its service owner")
        resumed = true; queue.resume(); queue.sync { }
        XCTAssertNil(rpc.get(recordId: RPCID(41)), "Committed cleanup must survive owner release")
        XCTAssertNotNil(rpc.get(recordId: RPCID(42)), "Cleanup must preserve other topics")
    }
    func testLiveQueuedCleanupIsScopedAndNonblocking() throws {
        let rpc = history(); try add(41, topic: "synthetic-a", to: rpc); try add(42, topic: "synthetic-b", to: rpc)
        let queue = DispatchQueue(label: "synthetic.cleanup.live"); let owner = service(rpc, queue: queue)
        queue.suspend(); owner.removePendingRequest(topic: "synthetic-a")
        XCTAssertNotNil(rpc.get(recordId: RPCID(41)))
        queue.resume(); queue.sync { }
        XCTAssertNil(rpc.get(recordId: RPCID(41))); XCTAssertNotNil(rpc.get(recordId: RPCID(42)))
        withExtendedLifetime(owner) { }
    }
    func testRepeatedAndAbsentCleanupPreservesOtherTopics() throws {
        let rpc = history(); try add(41, topic: "synthetic-a", to: rpc); try add(42, topic: "synthetic-b", to: rpc)
        let queue = DispatchQueue(label: "synthetic.cleanup.repeated"); let owner = service(rpc, queue: queue)
        owner.removePendingRequest(topic: "absent"); owner.removePendingRequest(topic: "synthetic-a")
        owner.removePendingRequest(topic: "synthetic-a"); queue.sync { }
        XCTAssertNil(rpc.get(recordId: RPCID(41))); XCTAssertNotNil(rpc.get(recordId: RPCID(42)))
        withExtendedLifetime(owner) { }
    }
    func testMultipleQueuedTopicsPreserveUnselectedTopic() throws {
        let rpc = history()
        for (id, topic) in [(Int64(41), "synthetic-a"), (42, "synthetic-b"), (43, "synthetic-c")] {
            try add(id, topic: topic, to: rpc)
        }
        let queue = DispatchQueue(label: "synthetic.cleanup.multiple"); let owner = service(rpc, queue: queue)
        owner.removePendingRequest(topic: "synthetic-a"); owner.removePendingRequest(topic: "synthetic-b"); queue.sync { }
        XCTAssertNil(rpc.get(recordId: RPCID(41))); XCTAssertNil(rpc.get(recordId: RPCID(42)))
        XCTAssertNotNil(rpc.get(recordId: RPCID(43)))
        withExtendedLifetime(owner) { }
    }
    func testHistoryReadFiltersExpiredAndMalformedRequests() throws {
        let rpc = history(); try add(41, topic: "synthetic-a", to: rpc, expired: true)
        try add(42, topic: "synthetic-b", to: rpc)
        try rpc.set(RPCRequest(method: "wc_sessionRequest", params: AnyCodable("invalid"), rpcid: RPCID(43)),
                    forTopic: "synthetic-c", emmitedBy: .remote, transportType: .relay)
        let owner = service(rpc, queue: DispatchQueue(label: "synthetic.cleanup.read"))
        XCTAssertEqual(owner.getPendingRequests().map { $0.request.id }, [RPCID(42)])
        XCTAssertEqual(owner.getPendingExpirableRequestsWithId().map { $0.1 }.sorted { $0.string < $1.string }, [RPCID(41), RPCID(42)])
        XCTAssertNotNil(rpc.get(recordId: RPCID(41)), "Read must not delete expired history")
        XCTAssertNotNil(rpc.get(recordId: RPCID(43)), "Read must not silently erase malformed history")
    }

    private struct SyntheticSequence: SequenceObject {
        let expiryDate: Date
        let topic: String
    }
    private func sequences() -> SequenceStore<SyntheticSequence> {
        SequenceStore(store: CodableStore(defaults: RuntimeKeyValueStorage(), identifier: "synthetic-sequences"))
    }
    private func timer(_ store: SequenceStore<SyntheticSequence>) throws -> Timer {
        // Observe the real owned timer; do not substitute a test scheduler or duplicate its behavior.
        let child = try XCTUnwrap(Mirror(reflecting: store).children.first { $0.label == "expiryMonitorTimer" })
        return try XCTUnwrap(child.value as? Timer)
    }
    func testReleasedSequenceStoreInvalidatesTimer() throws {
        var store: SequenceStore<SyntheticSequence>? = sequences()
        let ownedTimer = try timer(try XCTUnwrap(store)); XCTAssertTrue(ownedTimer.isValid)
        weak var released = store; store = nil
        XCTAssertNil(released, "Timer must not retain store")
        XCTAssertFalse(ownedTimer.isValid, "Released store must invalidate its scheduled timer")
        ownedTimer.invalidate()
    }
    func testLiveSequenceTimerExpiresOnlyExpiredItems() throws {
        XCTAssertTrue(Thread.isMainThread)
        let store = sequences(); let ownedTimer = try timer(store)
        defer { ownedTimer.invalidate() }
        var expired: [String] = []; var updates = 0
        store.onSequenceExpiration = { expired.append($0.topic) }; store.onSequenceUpdate = { updates += 1 }
        store.setSequence(.init(expiryDate: .distantPast, topic: "expired"))
        store.setSequence(.init(expiryDate: .distantFuture, topic: "live"))
        XCTAssertEqual(expired, []); XCTAssertEqual(updates, 2)
        let witness = expectation(description: "Run loop passes production timer period")
        let witnessTimer = Timer.scheduledTimer(withTimeInterval: 3.1, repeats: false) { _ in witness.fulfill() }
        defer { witnessTimer.invalidate() }
        wait(for: [witness], timeout: 5)
        XCTAssertEqual(expired, ["expired"]); XCTAssertEqual(updates, 3)
        XCTAssertEqual(store.getAll().map { $0.topic }, ["live"])
        XCTAssertEqual(expired, ["expired"])
    }
    func testExplicitSequenceDeletionDoesNotEmitExpiry() throws {
        let store = sequences(); let ownedTimer = try timer(store)
        defer { ownedTimer.invalidate() }
        var expired: [String] = []; store.onSequenceExpiration = { expired.append($0.topic) }
        store.setSequence(.init(expiryDate: .distantFuture, topic: "live"))
        store.delete(topic: "live"); XCTAssertEqual(expired, []); XCTAssertTrue(store.getAll().isEmpty)
    }
}
