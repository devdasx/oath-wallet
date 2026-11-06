import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor TronOptionalLabelFeed: AnkrTransport {
    var metadataCalls = 0
    let labelMessage: String
    init(labelMessage: String = "REVERT opcode executed") { self.labelMessage = labelMessage }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let calls = try XCTUnwrap(JSONDecoder().decode(TronJSON.self, from: XCTUnwrap(request.httpBody)).array)
        let rows = try calls.map { call -> TronJSON in
            let result: String
            if call["method"].string == "eth_chainId" { result = "0x2b6653dc" }
            else {
                metadataCalls += 1
                let selector = call["params"].array?.first?["data"].string ?? ""
                if ["0x06fdde03", "0x95d89b41"].contains(selector) {
                    return .object(["jsonrpc": .string("2.0"), "id": call["id"],
                        "error": .object(["code": .number("-32000"), "message": .string(labelMessage)])])
                }
                guard selector == "0x313ce567" || selector.hasPrefix("0x01ffc9a7") else { throw TronError.malformed }
                result = "0x" + String(repeating: "0", count: 63) + (selector == "0x313ce567" ? "6" : "0")
            }
            return .object(["jsonrpc": .string("2.0"), "id": call["id"], "result": .string(result)])
        }
        let data = try JSONEncoder().encode(TronJSON.array(rows))
        DiagnosticHTTP.response(data, status: 200, request: request)
        return (data, 200)
    }
}

private actor TronLabelReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class TronOptionalLabelTests: XCTestCase, @unchecked Sendable {
    func testMissingLabelsKeepVerifiedDecimalsWithoutRepeatedReads() async throws {
        let feed = TronOptionalLabelFeed()
        let client = try TronClient(apiKey: "FixtureKey", transport: feed)
        let token = try await client.token(TronIdentity.usdt)
        XCTAssertEqual(token.reference, TronIdentity.usdt)
        XCTAssertEqual(token.decimals, 6)
        XCTAssertEqual(token.symbol, "TRC-20")
        XCTAssertFalse(token.name.isEmpty)
        _ = try await client.token(TronIdentity.usdt)
        let calls = await feed.metadataCalls
        XCTAssertEqual(calls, 3, "Absent optional labels must not repeat the metadata batch or trigger an NFT probe")
    }

    func testExpectedLabelAbsenceDoesNotUploadFailureReports() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TRON_LABEL_REPORTS"] == "1" else {
            throw XCTSkip("Isolated diagnostics capture")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let reports = TronLabelReports()
        OathDiagnostics.configure(file: file, transport: reports)
        let operation = UUID()
        _ = try await OathDiagnostics.$operationID.withValue(operation) {
            try await TronClient(apiKey: "FixtureKey", transport: TronOptionalLabelFeed()).token(TronIdentity.usdt)
        }
        try await Task.sleep(for: .milliseconds(200))
        await OathDiagnostics.flush()
        let events = await reports.events.filter { $0.operationID == operation }
        XCTAssertTrue(events.isEmpty, "Validated absence of optional labels is not a failed refresh")
        let failureOperation = UUID()
        _ = try await OathDiagnostics.$operationID.withValue(failureOperation) {
            try await TronClient(apiKey: "FixtureKey", transport: TronOptionalLabelFeed(labelMessage: "upstream revert failure")).token(TronIdentity.usdt)
        }
        try await Task.sleep(for: .milliseconds(200))
        await OathDiagnostics.flush()
        let failures = await reports.events.filter { $0.operationID == failureOperation }
        XCTAssertTrue(failures.contains { $0.error.message == "upstream revert failure" }, "Other provider errors must retain their original cause")
    }
}
