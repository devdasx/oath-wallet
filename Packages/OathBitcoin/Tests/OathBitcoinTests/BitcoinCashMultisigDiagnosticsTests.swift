import XCTest
import OathDiagnostics
@testable import OathBitcoin

private actor BitcoinCashMultisigDiagnosticCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
final class BitcoinCashMultisigDiagnosticsTests: XCTestCase, @unchecked Sendable {
    // Run in its own process: OathDiagnostics configures its outbox once.
    func testSigningFailureReportsOnlySafeCodeAndOperationContext() async throws {
        let capture = BitcoinCashMultisigDiagnosticCapture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        OathDiagnostics.configure(file: directory.appendingPathComponent("events.json"), transport: capture)
        let keys = try (1...3).map { try BitcoinCashKeys.wif(bytes: Data(repeating: 0, count: 31) + Data([UInt8($0)]), compressed: true) }
        let policy = try BitcoinMultisig.wallet(required: 2, keys: keys.map(BitcoinMultisigKey.wif), network: .bitcoincash)
        let address = try BitcoinKeys.addresses(branch: policy.branches[0], range: 0..<1)[0]
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(100_000)) + BitcoinWire.vector(Data(hex: address.script)!) + BitcoinWire.little(UInt32(0))
        let coin = BitcoinSendCoin(accountID: "private-fixture-identifier", txid: try BitcoinTransactions.txid(raw, network: .bitcoincash), vout: 0,
            value: 100_000, address: address, previousTransaction: raw)
        let plan = try BitcoinSendPlan.make(coins: [coin], recipient: address.address, amount: 50_000, change: address, ratePerKVByte: 2000, chain: .bitcoincash)
        let operation = UUID()
        XCTAssertThrowsError(try OathDiagnostics.$operationID.withValue(operation) {
            try BitcoinMultisig.sign(plan, required: 3, keys: keys.map(BitcoinMultisigKey.wif), network: .bitcoincash)
        })
        // Malformed key input must return a stable domain error, never the original key.
        XCTAssertThrowsError(try BitcoinMultisig.validateWIF("T" + String(repeating: "1", count: 51), network: .bitcoincash)) {
            XCTAssertEqual($0 as? BitcoinMultisigError, .invalidKey)
        }
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.operationID == operation }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events.filter { $0.operationID == operation }
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.operation, "multisig_sign")
        XCTAssertEqual(event.context["chain"], "bitcoincash")
        XCTAssertTrue(event.privacyFiltered)
        let serialized = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        for secret in keys + [address.address, raw.hex, coin.accountID] { XCTAssertFalse(serialized.contains(secret)) }
    }
}
