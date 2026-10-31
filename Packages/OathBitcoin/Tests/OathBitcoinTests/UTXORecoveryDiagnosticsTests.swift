import Foundation
import XCTest
import OathDiagnostics
@testable import OathBitcoin

private actor RecoveryDiagnosticsCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
final class UTXORecoveryDiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testDeadlineIsExcludedButInvalidTransactionRetainsSafeContext() async throws {
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
        let recovered = await outage.submit(bytes, txid: hash, network: .bitcoin, reconcileFirst: true)
        XCTAssertTrue(recovered, "A reconciliation timeout must not prevent a successful broadcast")
        // Positive control through the production validation path. It also gives
        // the diagnostic worker a retained event to drain before checking exclusions.
        let rejected = await outage.submit(bytes, txid: String(repeating: "0", count: 64), network: .bitcoin)
        XCTAssertFalse(rejected, "A transaction-id mismatch must never be accepted")
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.events.contains(where: { $0.operation == "broadcast_validation" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events
        XCTAssertFalse(events.contains { $0.operation == "reconcile_deadline" }, "Availability failures are intentionally excluded")
        let validation = events.filter { $0.operation == "broadcast_validation" }
        XCTAssertEqual(validation.count, 1)
        let event = try XCTUnwrap(validation.first)
        XCTAssertEqual(event.context["chain"], "bitcoin")
        XCTAssertNotNil(event.operationID)
        let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(text.contains(bytes.hex)); XCTAssertFalse(text.contains(hash))
    }
}
