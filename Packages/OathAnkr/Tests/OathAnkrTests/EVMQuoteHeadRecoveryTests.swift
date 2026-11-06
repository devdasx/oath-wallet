import Foundation
import OathDiagnostics
import XCTest
@testable import OathAnkr

private enum QuoteHeadReply: Sendable {
    case fresh, offset(Double), invalidHash, invalidHeight, wrongChain, cancelled
}

private actor QuoteHeadTransport: AnkrTransport {
    struct Read: Sendable { let host: String; let method: String; let params: [SolanaJSON] }
    let primary: QuoteHeadReply
    let backup: QuoteHeadReply
    let fixture: EVMSendFixtureTransport
    let alterHistorical: Bool
    private(set) var reads: [Read] = []

    init(_ primary: QuoteHeadReply, backup: QuoteHeadReply = .fresh, network: EVMSendNetwork = .ethereum, alterHistorical: Bool = false) {
        self.primary = primary; self.backup = backup
        self.alterHistorical = alterHistorical
        fixture = EVMSendFixtureTransport(network: network)
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array!
        let call = calls.first { $0["id"].integer == 1 }!
        let host = request.url!.host!, method = call["method"].string!
        reads.append(.init(host: host, method: method, params: call["params"].array ?? []))
        let reply = host == "primary.example" ? primary : backup
        if case .cancelled = reply { throw CancellationError() }
        let (data, status) = try await fixture.send(request)
        var rows = try JSONDecoder().decode(SolanaJSON.self, from: data).array!
        if case .wrongChain = reply {
            let index = rows.firstIndex { $0["id"].integer == 0 }!
            rows[index] = .object(["jsonrpc": .string("2.0"), "id": .number("0"), "result": .string("0x2")])
        }
        if method == "eth_getBlockByNumber", call["params"].array?.first == .string("latest") || alterHistorical {
            let index = rows.firstIndex { $0["id"].integer == 1 }!
            guard case .object(var block) = rows[index]["result"] else { throw EVMSendError.malformed }
            switch reply {
            case .offset(let seconds):
                block["timestamp"] = .string("0x" + String(UInt64(Date.now.timeIntervalSince1970 + seconds), radix: 16))
                block["number"] = .string("0x64")
            case .invalidHash: block["hash"] = .string("not-a-block-hash")
            case .invalidHeight: block["number"] = .string("invalid")
            default: break
            }
            rows[index] = .object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": .object(block)])
        }
        return (try JSONEncoder().encode(SolanaJSON.array(rows)), status)
    }
}

final class EVMQuoteHeadRecoveryTests: XCTestCase, @unchecked Sendable {
    private func client(_ transport: QuoteHeadTransport, network: EVMSendNetwork = .ethereum) throws -> EVMSendClient {
        try EVMSendClient(network: network,
                          endpoints: [URL(string: "https://primary.example")!, URL(string: "https://backup.example")!],
                          transport: transport)
    }
    private func quote(_ client: EVMSendClient) async throws -> EVMSendPlan {
        try await client.quote(sender: "0x1111111111111111111111111111111111111111",
                               recipient: "0x2222222222222222222222222222222222222222",
                               reference: "native", decimals: 18, amount: "1")
    }

    func testStaleOrFuturePrimaryUsesFreshVerifiedBackupAndPinsItsHeight() async throws {
        for offset in [-600.0, 120.0] {
            let transport = QuoteHeadTransport(.offset(offset))
            let plan = try await quote(client(transport))
            try plan.validate()
            XCTAssertEqual(plan.blockHeight, 101)
            let reads = await transport.reads
            XCTAssertEqual(reads.filter { $0.method == "eth_getBlockByNumber" && $0.params.first == .string("latest") }.map(\.host), ["primary.example", "backup.example"])
            XCTAssertTrue(reads.filter { $0.method == "eth_getBalance" }.allSatisfy { $0.params.last == .string("0x65") })
            XCTAssertTrue(reads.dropFirst(2).allSatisfy { $0.host == "backup.example" }, "Pinned reads must not return to the lagging primary")
            XCTAssertFalse(reads.contains { $0.method == "eth_sendRawTransaction" })
        }
    }

    func testMalformedPrimaryHeadUsesBackup() async throws {
        for reply in [QuoteHeadReply.invalidHash, .invalidHeight] {
            let transport = QuoteHeadTransport(reply)
            let plan = try await quote(client(transport))
            XCTAssertEqual(plan.blockHeight, 101)
        }
    }

    func testEveryStaleProviderStillFailsBeforeBalanceOrFeeReads() async throws {
        let transport = QuoteHeadTransport(.offset(-600), backup: .offset(-600))
        do { _ = try await quote(client(transport)); XCTFail("Stale heads must not produce a quote") }
        catch { XCTAssertEqual(error as? EVMSendError, .expired) }
        let reads = await transport.reads
        XCTAssertEqual(reads.map(\.method), ["eth_getBlockByNumber", "eth_getBlockByNumber"])
    }

    func testBackupMustVerifyTheSameChain() async throws {
        let transport = QuoteHeadTransport(.offset(-600), backup: .wrongChain)
        do { _ = try await quote(client(transport)); XCTFail("Wrong-chain fallback accepted") }
        catch { XCTAssertEqual(error as? EVMSendError, .wrongNetwork) }
        let reads = await transport.reads
        XCTAssertEqual(reads.count, 2)
    }

    func testCancellationDoesNotTryBackup() async throws {
        let transport = QuoteHeadTransport(.cancelled)
        do { _ = try await quote(client(transport)); XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        let reads = await transport.reads
        XCTAssertEqual(reads.count, 1)
    }

    func testHistoricalBlockReadsDoNotRequireFreshTimestamps() async throws {
        let transport = QuoteHeadTransport(.offset(-86_400), alterHistorical: true)
        let block = try await client(transport).block(.string("0x64"))
        XCTAssertEqual(block["number"], .string("0x64"))
        let reads = await transport.reads
        XCTAssertEqual(reads.count, 1)
    }

    func testFilecoinRetainsItsLongerFreshnessWindow() async throws {
        for (offset, height) in [(-120.0, UInt64(100)), (-240.0, UInt64(101))] {
            let transport = QuoteHeadTransport(.offset(offset), network: .filecoin)
            let plan = try await quote(client(transport, network: .filecoin))
            XCTAssertEqual(plan.blockHeight, height)
        }
    }
}

private actor QuoteHeadReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class EVMQuoteHeadReportingTests: XCTestCase, @unchecked Sendable {
    func testFailedProvidersReportOnceEachWithoutCleanupDuplicatesOrPrivateContext() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_HEAD_REPORT_CAPTURE"] == "1" else {
            throw XCTSkip("Dedicated process for the shared diagnostics recorder")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = QuoteHeadReports()
        OathDiagnostics.configure(file: directory.appendingPathComponent("outbox.json"), transport: reports)
        for (offset, reason) in [(-600.0, "head_timestamp_stale"), (120.0, "head_timestamp_future")] {
            let operation = UUID()
            let transport = QuoteHeadTransport(.offset(offset), backup: .offset(offset))
            let client = try EVMSendClient(network: .ethereum,
                                          endpoints: [URL(string: "https://primary.example/private-key")!, URL(string: "https://backup.example/private-key")!],
                                          transport: transport)
            do {
                _ = try await OathDiagnostics.$operationID.withValue(operation) {
                    try await client.quote(sender: "0x1111111111111111111111111111111111111111",
                                           recipient: "0x2222222222222222222222222222222222222222",
                                           reference: "native", decimals: 18, amount: "1")
                }
                XCTFail("Expired heads accepted")
            } catch { XCTAssertEqual(error as? EVMSendError, .expired) }
            for _ in 0..<200 {
                if await reports.events.filter({ $0.operationID == operation }).count >= 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(100))
            await OathDiagnostics.flush()
            let events = await reports.events.filter { $0.operationID == operation }
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(Set(events.compactMap { $0.context["host"] }), ["primary.example", "backup.example"])
            XCTAssertTrue(events.allSatisfy { $0.context["reason"] == reason })
            XCTAssertTrue(events.allSatisfy { $0.error.message == "expired" && $0.context["chain"] == "ethereum" && $0.operation == "eth_getBlockByNumber" && $0.privacyFiltered })
            let payload = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
            XCTAssertFalse(payload.contains("private-key")); XCTAssertFalse(payload.contains("https://"))
            XCTAssertFalse(payload.contains("0x1111111111111111111111111111111111111111"))
        }
    }
}
