import Foundation
import XCTest
import OathDiagnostics
@testable import OathBitcoin

private struct OptionalLookupWire: ElectrumTransport {
    let response: Data
    func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        let calls = try JSONDecoder().decode(JSONValue.self, from: data).array!
        if calls.first?["method"]?.string == "server.version" {
            return try await StubTransport(.empty).exchange(data, timeout: timeout)
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["method"]?.string, "blockchain.transaction.get")
        return response
    }
}

final class ElectrumOptionalLookupTests: XCTestCase, @unchecked Sendable {
    private let transactionHash = String(repeating: "a", count: 64)
    private let daemonAbsence = #"daemon error: DaemonError({'code': -5, 'message': 'No such mempool or blockchain transaction. Use gettransaction for wallet transactions.'})"#
    private func daemonReply(_ message: String, code: Int = 2) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [["id": 0, "error": ["code": code, "message": message]]])
        return String(decoding: data, as: UTF8.self)
    }
    private func pool(_ response: String) -> ElectrumPool {
        ElectrumPool(servers: [.init("fixture")], transactionFallback: nil) { _ in
            OptionalLookupWire(response: Data(response.utf8))
        }
    }
    func testOptionalMissingTransactionIsAbsentWithoutPoisoningPeer() async throws {
        let client = pool(#"[{"id":0,"error":{"code":-32603,"message":"missing transaction"}}]"#)
        let value = try await client.transactionIfKnown(transactionHash)
        XCTAssertNil(value)
        let attempts = await client.diagnostics()
        XCTAssertTrue(attempts.allSatisfy { $0.error == nil })
        await client.close()
    }
    func testRequiredHistoryStillFailsForMissingTransaction() async throws {
        let client = pool(#"[{"id":0,"error":{"code":-32603,"message":"missing transaction"}}]"#)
        do { _ = try await client.transactions(txids: [transactionHash]); XCTFail("Required history must not become empty success") }
        catch { XCTAssertEqual(error as? BitcoinError, .server(code: -32603)) }
        await client.close()
    }
    func testExactDaemonAbsenceIsOptionalButRequiredHistoryStillFails() async throws {
        let client = pool(try daemonReply(daemonAbsence))
        let first = try await client.transactionIfKnown(transactionHash)
        XCTAssertNil(first)
        // An absent optional result must not put this healthy peer in cooldown.
        let second = try await client.transactionIfKnown(transactionHash)
        XCTAssertNil(second)
        let attempts = await client.diagnostics()
        XCTAssertTrue(attempts.allSatisfy { $0.error == nil })
        do { _ = try await client.transactions(txids: [transactionHash]); XCTFail("Required history became absence") }
        catch { XCTAssertEqual(error as? BitcoinError, .server(code: 2)) }
        await client.close()
    }
    func testOtherDaemonFailuresNeverBecomeOptionalAbsence() async throws {
        for (code, message) in [
            (2, daemonAbsence.replacingOccurrences(of: "-5", with: "-8")),
            (-5, daemonAbsence),
            (2, "daemon error: DaemonError({'code': -5, 'message': 'No such mempool transaction. Use -txindex or provide a block hash to enable blockchain transaction queries. Use gettransaction for wallet transactions.'})"),
            (2, daemonAbsence + " index unavailable"),
            (2, "daemon error: DaemonError({'code': -5, 'message': 'Database unavailable'})")
        ] {
            let client = pool(try daemonReply(message, code: code))
            do { _ = try await client.transactionIfKnown(transactionHash); XCTFail("Daemon failure became absence") }
            catch { XCTAssertEqual(error as? BitcoinError, .server(code: code)) }
            await client.close()
        }
    }
    func testLivePublicPeersAgreeOnAbsentOptionalTransaction() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_OPTIONAL_ABSENCE"] == "1" else {
            throw XCTSkip("Opt-in TLS reads of a synthetic nonexistent transaction; no wallet or broadcast")
        }
        for server in ElectrumServer.publicMainnet {
            let client = ElectrumPool(servers: [server], maximumConnections: 1, network: .bitcoin,
                transactionFallback: nil, requestTimeout: 5, makeTransport: { ElectrumWire(server: $0) })
            do {
                let absent = try await client.transactionIfKnown(String(repeating: "0", count: 64))
                XCTAssertNil(absent)
                let attempts = await client.diagnostics()
                XCTAssertTrue(attempts.allSatisfy { $0.error == nil })
                await client.close()
            } catch { await client.close(); throw error }
        }
    }
    func testKnownBytesStillRequireMatchingHashAndRecoverWithoutResubmission() async throws {
        let raw = try XCTUnwrap(Data(hex: "0100000001" + String(repeating: "11", count: 32) + "0000000000ffffffff010100000000000000015100000000"))
        let txid = try BitcoinTransactions.txid(raw)
        let client = pool("[{\"id\":0,\"result\":\"\(raw.hex)\"}]")
        let found = try await client.transactionIfKnown(txid)
        XCTAssertEqual(found, raw)
        let provider = UTXOBroadcastProvider(sources: { _ in [
            .init(name: "fixture", delay: .zero, submit: { _ in XCTFail("Already present bytes were resubmitted"); return txid },
                  lookup: { try await client.transactionIfKnown($0) })
        ] })
        let accepted = await provider.submit(raw, txid: txid, network: .bitcoin, reconcileFirst: true)
        XCTAssertTrue(accepted)
        do { _ = try await client.transactionIfKnown(transactionHash); XCTFail("Mismatched bytes became valid") }
        catch { XCTAssertEqual(error as? BitcoinError, .invalidResponse) }
        await client.close()
    }
    func testMissingOptionalLookupNeverAcknowledgesFailedBroadcast() async throws {
        let raw = try XCTUnwrap(Data(hex: "0100000001" + String(repeating: "11", count: 32) + "0000000000ffffffff010100000000000000015100000000"))
        let txid = try BitcoinTransactions.txid(raw)
        for response in [
            #"[{"id":0,"error":{"code":-32603,"message":"missing transaction"}}]"#,
            try daemonReply(daemonAbsence)
        ] {
            let client = pool(response)
            let provider = UTXOBroadcastProvider(lookupDelay: .zero, sources: { _ in [
                .init(name: "fixture", delay: .zero, submit: { hex in
                    XCTAssertEqual(hex, raw.hex); throw BitcoinError.server(code: -27)
                }, lookup: { try await client.transactionIfKnown($0) })
            ] })
            let accepted = await provider.submit(raw, txid: txid, network: .bitcoin, reconcileFirst: true)
            XCTAssertFalse(accepted)
            await client.close()
        }
    }
    func testOtherFailuresAndMalformedRepliesRemainErrors() async throws {
        for response in [
            #"[{"id":0,"error":{"code":-32603,"message":"database unavailable"}}]"#,
            #"[{"id":0,"error":{"code":2,"message":"missing transaction"}}]"#,
            #"[{"id":0,"error":{"code":-32603,"message":"missing transaction: index unavailable"}}]"#,
            #"[{"id":1,"error":{"code":-32603,"message":"missing transaction"}}]"#,
            #"[{"id":0,"error":{"code":-32603,"message":"missing transaction"}},{"id":0,"result":"00"}]"#,
            #"[{"id":0,"result":null}]"#,
            #"[{"id":0}]"#,
            #"[{"id":0,"result":"00"}]"#,
            #"[{"id":0,"result":"00","error":{"code":-32603,"message":"missing transaction"}}]"#
        ] {
            let client = pool(response)
            do { _ = try await client.transactionIfKnown(transactionHash); XCTFail("Malformed/unavailable data became absence: \(response)") }
            catch { XCTAssertTrue(error is BitcoinError) }
            await client.close()
        }
    }
}

private actor OptionalLookupCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class ElectrumOptionalLookupDiagnosticsTests: XCTestCase, @unchecked Sendable {
    // Run separately: the shared outbox is configured once per process.
    func testOnlyOptionalAbsenceIsQuietAndRequiredFailurePreservesSafeContext() async throws {
        let capture = OptionalLookupCapture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        OathDiagnostics.configure(file: directory.appendingPathComponent("events.json"), transport: capture)
        let replies = [
            (-32603, "missing transaction"),
            (2, "daemon error: DaemonError({'code': -5, 'message': 'No such mempool or blockchain transaction. Use gettransaction for wallet transactions.'})")
        ]
        for (code, message) in replies {
            let response = try JSONSerialization.data(withJSONObject: [["id": 0, "error": ["code": code, "message": message]]])
            let client = ElectrumPool(servers: [.init("fixture")], transactionFallback: nil) { _ in
                OptionalLookupWire(response: response)
            }
            let txid = String(repeating: "a", count: 64), operationID = UUID()
            let optionalID = UUID()
            let absent = try await OathDiagnostics.$operationID.withValue(optionalID) {
                try await client.transactionIfKnown(txid)
            }
            XCTAssertNil(absent)
            try await Task.sleep(for: .milliseconds(100))
            await OathDiagnostics.flush()
            let before = await capture.events
            XCTAssertFalse(before.contains { $0.operationID == optionalID })
            await OathDiagnostics.$operationID.withValue(operationID) {
                do { _ = try await client.transactions(txids: [txid]); XCTFail("Required failure was hidden") }
                catch { XCTAssertEqual(error as? BitcoinError, .server(code: code)) }
            }
            for _ in 0..<100 {
                await OathDiagnostics.flush()
                if await capture.events.contains(where: { $0.operation == "rpc_response" && $0.operationID == operationID }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let events = await capture.events
            let event = try XCTUnwrap(events.first { $0.operation == "rpc_response" && $0.operationID == operationID })
            XCTAssertEqual(event.operationID, operationID)
            XCTAssertEqual(event.context["rpc_code"], String(code))
            XCTAssertFalse(events.contains { $0.operationID == optionalID })
            XCTAssertEqual(event.context["chain"], "bitcoin")
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains(txid))
            await client.close()
        }
    }
}
