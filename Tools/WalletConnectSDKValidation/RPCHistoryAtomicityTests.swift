import XCTest
import Foundation
import JSONRPC
@testable import WalletConnectUtils

// Thread-safe storage that pauses one read after capturing its value. This
// exposes a compound-operation race without changing production history code.
private final class HistoryGateStorage: KeyValueStorage, @unchecked Sendable {
    enum Point { case object, snapshot }
    private let lock = NSLock()
    private var values: [String:Any] = [:]
    private var point: Point?
    private var timedOut = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func arm(_ point: Point) { lock.lock(); self.point = point; lock.unlock() }
    private func pause(_ target: Point) {
        lock.lock(); let shouldPause = point == target
        if shouldPause { point = nil }; lock.unlock()
        if shouldPause {
            entered.signal()
            if release.wait(timeout: .now() + 8) != .success {
                lock.lock(); timedOut = true; lock.unlock()
            }
        }
    }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func set(_ value: Any?, forKey key: String) { lock.lock(); values[key] = value; lock.unlock() }
    func object(forKey key: String) -> Any? {
        lock.lock(); let value = values[key]; lock.unlock(); pause(.object); return value
    }
    func data(forKey key: String) -> Data? { object(forKey:key) as? Data }
    func removeObject(forKey key: String) { lock.lock(); values[key] = nil; lock.unlock() }
    func dictionaryRepresentation() -> [String:Any] {
        lock.lock(); let value = values; lock.unlock(); pause(.snapshot); return value
    }
    func bool(forKey key: String) -> Bool { object(forKey:key) as? Bool ?? false }
}
private final class HistoryOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var successes = 0
    private var errors: [String] = []
    func run(_ action: () throws -> Void) {
        do { try action(); lock.lock(); successes += 1; lock.unlock() }
        catch { lock.lock(); errors.append(String(describing:error)); lock.unlock() }
    }
    var result: (Int,[String]) { lock.lock(); defer { lock.unlock() }; return (successes,errors) }
}
private struct HistoryClock: TimeProvider {
    let read: () -> Date
    var currentDate: Date { read() }
}

final class RPCHistoryAtomicityTests: XCTestCase {
    private enum FixtureError: Error { case gateDidNotStart }
    private func request(_ id: Int64 = 42) -> RPCRequest {
        RPCRequest(method:"wc_sessionPing",params:[String:String](),id:id)
    }
    private func histories(_ sharedInstances: Bool) -> (HistoryGateStorage,RPCHistory,RPCHistory) {
        let storage = HistoryGateStorage()
        let first = RPCHistoryFactory.createForNetwork(keyValueStorage:storage)
        let second = sharedInstances ? RPCHistoryFactory.createForNetwork(keyValueStorage:storage) : first
        return (storage,first,second)
    }
    private func interleave(_ storage: HistoryGateStorage, point: HistoryGateStorage.Point,
                            first: @escaping () -> Void, second: @escaping () -> Void) throws {
        storage.arm(point)
        let group = DispatchGroup(), started = DispatchSemaphore(value:0), secondDone = DispatchSemaphore(value:0)
        group.enter(); DispatchQueue.global().async { first(); group.leave() }
        guard storage.entered.wait(timeout:.now()+3) == .success else {
            storage.release.signal(); throw FixtureError.gateDidNotStart
        }
        group.enter(); DispatchQueue.global().async { started.signal(); second(); secondDone.signal(); group.leave() }
        XCTAssertEqual(started.wait(timeout:.now()+3),.success)
        // The unfixed second operation completes while the first retains a stale
        // read. With serialization it waits; release the first in either case.
        _ = secondDone.wait(timeout:.now()+0.25)
        storage.release.signal()
        XCTAssertEqual(group.wait(timeout:.now()+5),.success,"History operations must not deadlock")
        XCTAssertFalse(storage.didTimeOut,"Storage gate must be explicitly released")
    }
    private func insertion(shared: Bool) throws {
        let (storage,a,b) = histories(shared), outcomes = HistoryOutcomes(), r = request()
        try interleave(storage,point:.object,first: {
            outcomes.run { try a.set(r,forTopic:"first",emmitedBy:.local,transportType:.relay) }
        },second: {
            outcomes.run { try b.set(r,forTopic:"second",emmitedBy:.local,transportType:.relay) }
        })
        XCTAssertEqual(outcomes.result.0,1,"Exactly one duplicate insert may succeed")
        XCTAssertEqual(outcomes.result.1,["requestDuplicateNotAllowed"],"The other insert must reject the existing ID")
        XCTAssertEqual(a.get(recordId:r.id!)?.topic,"first")
    }
    private func resolution(shared: Bool) throws {
        let (storage,a,b) = histories(shared), outcomes = HistoryOutcomes(), r = request()
        try a.set(r,forTopic:"first",emmitedBy:.local,transportType:.relay)
        let response = RPCResponse(id:r.id!,result:true)
        try interleave(storage,point:.object,first: {
            outcomes.run { _ = try a.resolve(response,forResponseTopic:"first") }
        },second: {
            outcomes.run { _ = try b.resolve(response,forResponseTopic:"first") }
        })
        XCTAssertEqual(outcomes.result.0,1,"Exactly one resolution may consume a pending response")
        XCTAssertEqual(outcomes.result.1,["requestMatchingResponseNotFound"],"Duplicate resolution must be rejected")
        XCTAssertNil(a.get(recordId:r.id!))
    }
    private func cleanup(expired: Bool) throws {
        let (storage,a,b) = histories(true), outcomes = HistoryOutcomes(), r = request()
        let clock = HistoryClock { expired ? Date(timeIntervalSince1970:1) : Date() }
        try a.set(r,forTopic:"old-topic",emmitedBy:.local,time:clock,transportType:.relay)
        try interleave(storage,point:.snapshot,first: {
            if expired { a.removeOutdated() } else { a.deleteAll(forTopic:"old-topic") }
        },second: {
            outcomes.run { b.delete(id:r.id!); try b.set(r,forTopic:"new-topic",emmitedBy:.local,transportType:.relay) }
        })
        XCTAssertEqual(outcomes.result.0,1); XCTAssertTrue(outcomes.result.1.isEmpty)
        XCTAssertEqual(a.get(recordId:r.id!)?.topic,"new-topic","Cleanup must not erase a replacement outside its snapshot")
    }
    func testDuplicateInsertSingleHistory() throws { try insertion(shared:false) }
    func testDuplicateInsertSharedStore() throws { try insertion(shared:true) }
    func testDuplicateResolutionSingleHistory() throws { try resolution(shared:false) }
    func testDuplicateResolutionSharedStore() throws { try resolution(shared:true) }
    func testTopicCleanupPreservesReplacement() throws { try cleanup(expired:false) }
    func testExpiryCleanupPreservesReplacement() throws { try cleanup(expired:true) }
    func testSequentialDuplicateStillRejects() throws {
        let (_,a,b) = histories(true), r = request()
        try a.set(r,forTopic:"first",emmitedBy:.local,transportType:.relay)
        XCTAssertThrowsError(try b.set(r,forTopic:"second",emmitedBy:.local,transportType:.relay))
        XCTAssertEqual(a.get(recordId:r.id!)?.topic,"first")
    }
    func testDifferentIDsRemainIndependent() {
        let (_,a,b) = histories(true), results = HistoryOutcomes()
        DispatchQueue.concurrentPerform(iterations:32) { i in
            results.run { try (i % 2 == 0 ? a : b).set(self.request(Int64(i)),forTopic:"topic-\(i)",emmitedBy:.local,transportType:.relay) }
        }
        XCTAssertEqual(results.result.0,32); XCTAssertTrue(results.result.1.isEmpty)
        XCTAssertEqual(a.getPending().count,32)
    }
    func testRejectedTopicDoesNotConsumeRequest() throws {
        let (_,a,b) = histories(true), r = request()
        try a.set(r,forTopic:"first",emmitedBy:.local,transportType:.relay)
        XCTAssertThrowsError(try b.resolve(RPCResponse(id:r.id!,result:true),forResponseTopic:"other"))
        XCTAssertNotNil(a.get(recordId:r.id!))
        _ = try b.resolve(RPCResponse(id:r.id!,result:true),forResponseTopic:"first")
        XCTAssertNil(a.get(recordId:r.id!))
    }
    func testRelayAndNetworkNamespacesRemainIndependent() throws {
        let storage = HistoryGateStorage(), r = request()
        let a = RPCHistoryFactory.createForNetwork(keyValueStorage:storage)
        let b = RPCHistoryFactory.createForRelay(keyValueStorage:storage)
        try a.set(r,forTopic:"network",emmitedBy:.local,transportType:.relay)
        try b.set(r,forTopic:"relay",emmitedBy:.local,transportType:.relay)
        _ = try a.resolve(RPCResponse(id:r.id!,result:true),forResponseTopic:"network")
        XCTAssertNil(a.get(recordId:r.id!)); XCTAssertEqual(b.get(recordId:r.id!)?.topic,"relay")
    }
    func testSynchronousClockReadCanReenterHistory() throws {
        let (_,a,b) = histories(true), r = request()
        let clock = HistoryClock { XCTAssertNil(b.get(recordId:r.id!)); return Date() }
        try a.set(r,forTopic:"first",emmitedBy:.local,time:clock,transportType:.relay)
        XCTAssertEqual(b.get(recordId:r.id!)?.topic,"first")
    }
}
