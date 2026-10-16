import Foundation
import XCTest
import OathDiagnostics
@testable import OathBitcoin

private actor RecoveryDiagnosticsCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
final class UTXORecoveryDiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testHealthyReadIsQuietAndRealDeadlineRetainsSafeContext() async throws {
        let capture = RecoveryDiagnosticsCapture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        OathDiagnostics.configure(file: directory.appendingPathComponent("events.json"), transport: capture)
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(10000)) + BitcoinWire.vector(Data([0x51])) + BitcoinWire.little(UInt32(0))
        let bytes = raw, hash = try BitcoinTransactions.txid(raw)
        let healthy = UTXOBroadcastProvider(sources: { _ in [
            .init(name: "healthy", delay: .milliseconds(600), submit: { _ in XCTFail("Unnecessary broadcast"); return hash }, lookup: { _ in
                try await Task.sleep(for: .milliseconds(450)); return bytes
            })
        ] })
        let accepted = await healthy.submit(bytes, txid: hash, network: .bitcoin, reconcileFirst: true)
        XCTAssertTrue(accepted)
        try await Task.sleep(for: .milliseconds(100))
        let early = await capture.events
        XCTAssertTrue(early.isEmpty, "Healthy lookup must not produce a false deadline failure")
        let outage = UTXOBroadcastProvider(reconciliationDeadline: .milliseconds(50), sources: { _ in [
            .init(name: "outage", delay: .zero, submit: { _ in hash }, lookup: { _ in
                try await Task.sleep(for: .seconds(10)); return bytes
            })
        ] })
        _ = await outage.submit(bytes, txid: hash, network: .bitcoin, reconcileFirst: true)
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.operation == "reconcile_deadline" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events.filter { $0.operation == "reconcile_deadline" }
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.context["chain"], "bitcoin")
        XCTAssertEqual(event.context["stage"], "reconcile")
        XCTAssertNotNil(event.operationID)
        let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(text.contains(bytes.hex)); XCTAssertFalse(text.contains(hash))
    }
}
