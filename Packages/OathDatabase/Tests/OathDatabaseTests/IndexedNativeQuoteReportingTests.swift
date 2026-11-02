import XCTest
import OathAnkr
import OathDiagnostics
@testable import OathDatabase

private actor QuoteCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}

private struct RejectedQuoteFeed: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        switch request.url?.host {
        case "coins.llama.fi": return (Data(#"{"coins":{}}"#.utf8), 200)
        case "api.coingecko.com": return (Data(#"{"wrong":{"usd":1}}"#.utf8), 200)
        case "dev.iotexscan.io": return (Data(#"{"status":"1","result":{"ethusd":"bad","ethusd_timestamp":1}}"#.utf8), 200)
        case "api.coinbase.com": return (Data(#"{"data":{"base":"BTC","currency":"USD","amount":"1"}}"#.utf8), 200)
        default: throw AnkrError.invalidResponse
        }
    }
}

final class IndexedNativeQuoteReportingTests: XCTestCase, @unchecked Sendable {
    func testEachRejectedProviderRetainsItsOwnErrorWithoutAnotherSyncError() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NATIVE_QUOTE_CAPTURE"] == "1" else {
            throw XCTSkip("Dedicated process for shared recorder capture")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = QuoteCapture()
        OathDiagnostics.configure(file: folder.appendingPathComponent("reports.json"), transport: capture)
        // Other host tests can leave the bounded startup queue full before
        // configuration. Wait for a fresh event to reach this capture first.
        let ready = UUID()
        for _ in 0..<100 {
            OathDiagnostics.$operationID.withValue(ready) {
                OathDiagnostics.record(DiagnosticFailure("ready"), component: "fixture", operation: "ready")
            }
            try await Task.sleep(for: .milliseconds(25))
            if await capture.events.contains(where: { $0.operationID == ready }) { break }
        }
        let recorderReady = await capture.events.contains { $0.operationID == ready }
        XCTAssertTrue(recorderReady)
        for (chain, expected) in [(IndexedEVMChain.iotex, ["CoinGecko", "IoTeXScan"]), (.celo, ["native_quote"]), (.zerog, ["CoinGecko"])] {
            let id = UUID(), client = IndexedEVMMarkets(chain: chain, transport: RejectedQuoteFeed())
            let quote = await OathDiagnostics.$chain.withValue(chain.rawValue) {
                await OathDiagnostics.$operationID.withValue(id) { await IndexedEVMSynchronizer.nativePrice(from: client) }
            }
            XCTAssertNil(quote)
            for _ in 0..<100 {
                if await capture.events.filter({ $0.operationID == id }).count >= expected.count { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await OathDiagnostics.flush()
            let events = await capture.events.filter { $0.operationID == id }
            XCTAssertEqual(events.count, expected.count, chain.rawValue)
            XCTAssertEqual(Set(events.compactMap { $0.context["source"] }), Set(expected))
            let terminal = events.filter { $0.operation == (chain == .iotex ? "iotex_native_price_validation" : "native_price") }
            XCTAssertEqual(terminal.count, 1)
            XCTAssertTrue(events.allSatisfy { $0.error.message == "invalidResponse" && $0.context["chain"] == chain.rawValue })
        }
    }
}
