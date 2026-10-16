import Foundation
import XCTest
@testable import OathBitcoin

final class UTXORecoveryPreflightTests: XCTestCase, @unchecked Sendable {
    private func raw() -> Data {
        var data = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        data += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        data += BitcoinWire.little(UInt64(10000)) + BitcoinWire.vector(Data([0x51])) + BitcoinWire.little(UInt32(0))
        return data
    }
    func testRecoveryAlreadyPresentOnAnyProviderDoesNotRebroadcast() async throws {
        for chain in UTXONetwork.allCases {
            let raw = raw(), hash = try BitcoinTransactions.txid(raw, network: chain), calls = RecoveryCalls()
            let client = UTXOBroadcastProvider(preferred: { _ in
                .init(name: "primary", delay: .zero, submit: { _ in await calls.submitted(); return hash }, lookup: { _ in nil })
            }, sources: { _ in [
                .init(name: "fallback", delay: .zero, submit: { _ in await calls.submitted(); return hash }, lookup: { id in
                    XCTAssertEqual(id, hash); return raw
                })
            ] })
            let accepted = await client.submit(raw, txid: hash, network: chain, reconcileFirst: true)
            XCTAssertTrue(accepted)
            let count = await calls.count; XCTAssertEqual(count, 0)
        }
    }
    func testNormalReadLatencyDoesNotCauseRecoveryRebroadcastOnAnyChain() async throws {
        for chain in UTXONetwork.allCases {
            let raw = raw(), hash = try BitcoinTransactions.txid(raw, network: chain), calls = RecoveryCalls()
            let client = UTXOBroadcastProvider(sources: { _ in [
                .init(name: "healthy-read", delay: .zero, submit: { _ in await calls.submitted(); return hash }, lookup: { _ in
                    try await Task.sleep(for: .milliseconds(450)); return raw
                })
            ] })
            let accepted = await client.submit(raw, txid: hash, network: chain, reconcileFirst: true)
            XCTAssertTrue(accepted)
            let count = await calls.count
            XCTAssertEqual(count, 0, "A normal read must finish before deciding to rebroadcast")
        }
    }
    func testLastFallbackReadIsNotDelayedByItsBroadcastStagger() async throws {
        let raw = raw(), hash = try BitcoinTransactions.txid(raw), calls = RecoveryCalls()
        let client = UTXOBroadcastProvider(preferredDeadline: .milliseconds(20), sources: { _ in [
            .init(name: "absent", delay: .zero, submit: { _ in await calls.submitted(); return hash }, lookup: { _ in nil }),
            .init(name: "last-fallback", delay: .milliseconds(600), submit: { _ in await calls.submitted(); return hash }, lookup: { _ in
                try await Task.sleep(for: .milliseconds(100)); return raw
            })
        ] })
        let start = ContinuousClock.now
        let accepted = await client.submit(raw, txid: hash, network: .bitcoin, reconcileFirst: true)
        XCTAssertTrue(accepted)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        let count = await calls.count; XCTAssertEqual(count, 0)
    }
    func testMissingOrDifferentBytesStillSubmitOnlyThePersistedTransaction() async throws {
        for found in [Data?.none, Data([0])] {
            let raw = raw(), hash = try BitcoinTransactions.txid(raw), calls = RecoveryCalls()
            let client = UTXOBroadcastProvider(lookupDelay: .zero, sources: { _ in [
                .init(name: "fixture", delay: .zero, submit: { hex in
                    XCTAssertEqual(hex, raw.hex); await calls.submitted(); return hash
                }, lookup: { _ in found })
            ] })
            let accepted = await client.submit(raw, txid: hash, network: .bitcoin, reconcileFirst: true)
            XCTAssertTrue(accepted)
            let count = await calls.count; XCTAssertEqual(count, 1)
        }
    }
    func testKnownErrorWithoutMatchingBytesIsStillUnknown() async throws {
        let raw = raw(), hash = try BitcoinTransactions.txid(raw)
        let client = UTXOBroadcastProvider(lookupDelay: .zero, sources: { _ in [
            .init(name: "fixture", delay: .zero, submit: { _ in
                throw NSError(domain: "fixture", code: -27, userInfo: [NSLocalizedDescriptionKey: "Transaction outputs already in utxo set"])
            }, lookup: { _ in nil })
        ] })
        let accepted = await client.submit(raw, txid: hash, network: .bitcoin, reconcileFirst: true)
        XCTAssertFalse(accepted)
    }
    func testCancelledRecoveryDoesNotReadOrPost() async throws {
        let raw = raw(), hash = try BitcoinTransactions.txid(raw), calls = RecoveryCalls()
        let client = UTXOBroadcastProvider(sources: { _ in [
            .init(name: "fixture", delay: .zero, submit: { _ in await calls.submitted(); return hash }, lookup: { _ in await calls.submitted(); return raw })
        ] })
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return await client.submit(raw, txid: hash, network: .bitcoin, reconcileFirst: true) }
        let accepted = await task.value; XCTAssertFalse(accepted)
        let count = await calls.count; XCTAssertEqual(count, 0)
    }
    func testExpiredReadWindowStillAttemptsOnlyPersistedBytes() async throws {
        let raw = raw(), hash = try BitcoinTransactions.txid(raw), calls = RecoveryCalls()
        let client = UTXOBroadcastProvider(reconciliationDeadline: .milliseconds(60), sources: { _ in [
            .init(name: "stalled-read", delay: .zero, submit: { hex in
                XCTAssertEqual(hex, raw.hex); await calls.submitted(); return hash
            }, lookup: { _ in try await Task.sleep(for: .seconds(10)); return raw })
        ] })
        let start = ContinuousClock.now
        let accepted = await client.submit(raw, txid: hash, network: .bitcoin, reconcileFirst: true)
        XCTAssertTrue(accepted); XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let count = await calls.count; XCTAssertEqual(count, 1)
    }
    func testCancelDuringRecoveryNeverBroadcasts() async throws {
        let raw = raw(), hash = try BitcoinTransactions.txid(raw), calls = RecoveryCalls()
        let client = UTXOBroadcastProvider(sources: { _ in [
            .init(name: "slow-read", delay: .zero, submit: { _ in await calls.submitted(); return hash }, lookup: { _ in
                await calls.readStarted(); try await Task.sleep(for: .seconds(10)); return raw
            })
        ] })
        let task = Task { await client.submit(raw, txid: hash, network: .bitcoin, reconcileFirst: true) }
        for _ in 0..<100 {
            if await calls.reads > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let reads = await calls.reads; XCTAssertEqual(reads, 1)
        task.cancel()
        let accepted = await task.value; XCTAssertFalse(accepted)
        let count = await calls.count; XCTAssertEqual(count, 0)
    }
}
private actor RecoveryCalls {
    var count = 0
    var reads = 0
    func submitted() { count += 1 }
    func readStarted() { reads += 1 }
}
