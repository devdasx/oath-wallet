import XCTest
import OathDiagnostics
@testable import OathAnkr

@MainActor final class SendQuoteExpiryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEveryEVMFixtureStillRequiresRefreshAfterNinetySeconds() throws {
        let fixture = EVMSendTests()
        for vector in try fixture.vectors() {
            let plan = fixture.plan(vector, now: now)
            XCTAssertNoThrow(try plan.validate(now: now.addingTimeInterval(90)))
            XCTAssertThrowsError(try plan.validate(now: now.addingTimeInterval(90.001))) { error in
                XCTAssertEqual((error as? any DiagnosticControlFlowError)?.isExpectedDiagnosticControlFlow, true)
            }
            XCTAssertThrowsError(try EVMSendCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32),
                                                       now: now.addingTimeInterval(91)))
            // Recovery verifies the original signed commitment without a fresh quote.
            XCTAssertNoThrow(try plan.validate(now: now.addingTimeInterval(91), checkAge: false))
        }
    }

    func testFutureDatedAndMalformedPlansDoNotBecomeExpectedExpiry() throws {
        let fixture = EVMSendTests(), vector = try fixture.vectors()[0]
        let plan = fixture.plan(vector, now: now)
        XCTAssertNoThrow(try plan.validate(now: now.addingTimeInterval(-5)))
        XCTAssertThrowsError(try plan.validate(now: now.addingTimeInterval(-5.001))) {
            XCTAssertEqual($0 as? EVMSendError, .expired)
            XCTAssertNotEqual(($0 as? any DiagnosticControlFlowError)?.isExpectedDiagnosticControlFlow, true)
        }
        for invalidTime in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try plan.validate(now: Date(timeIntervalSince1970: invalidTime))) {
                XCTAssertEqual($0 as? EVMSendError, .expired)
                XCTAssertNotEqual(($0 as? any DiagnosticControlFlowError)?.isExpectedDiagnosticControlFlow, true)
            }
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        json["recipient"] = "invalid"
        let malformed = try JSONDecoder().decode(EVMSendPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try malformed.validate(now: now.addingTimeInterval(91))) {
            XCTAssertNotEqual(($0 as? any DiagnosticControlFlowError)?.isExpectedDiagnosticControlFlow, true)
        }
    }

    func testExpiredQuoteCannotReachNetworkPreflight() async throws {
        let fixture = EVMSendTests(), vector = try fixture.vectors()[0]
        let plan = fixture.plan(vector, now: .now.addingTimeInterval(-120))
        let transport = ExpiredQuoteTransport()
        let client = try EVMSendClient(network: vector.network,
            endpoints: [URL(string: "https://fixture.invalid")!], transport: transport)
        do { try await client.preflight(plan); XCTFail("Expired quote reached preflight") }
        catch { XCTAssertEqual((error as? any DiagnosticControlFlowError)?.isExpectedDiagnosticControlFlow, true) }
        let requests = await transport.requests
        XCTAssertEqual(requests, 0)
    }

    func testExpiredQuoteIsNotUploadedButProviderExpiryAndLookalikesRemain() async throws {
        guard ProcessInfo.processInfo.environment["OATH_QUOTE_EXPIRY_DIAGNOSTICS_TEST"] == "1" else {
            throw XCTSkip("Run alone to isolate the process-wide diagnostics outbox")
        }
        let reports = ExpiredQuoteReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let fixture = EVMSendTests(), plan = fixture.plan(try fixture.vectors()[0], now: now)
        do { try plan.validate(now: now.addingTimeInterval(91)); XCTFail("Stale quote accepted") }
        catch {
            for operation in ["reserve", "submit"] {
                OathDiagnostics.record(error, component: "evm_send", operation: operation)
            }
        }
        OathDiagnostics.record(EVMSendError.expired, component: "evm_send", operation: "stale_provider_block")
        OathDiagnostics.record(EVMSendError.malformed, component: "evm_send", operation: "malformed")
        OathDiagnostics.record(NSError(domain: "OathAnkr.SendQuoteExpiredError", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "quote expired"]), component: "fixture", operation: "lookalike")
        for _ in 0..<200 {
            if await reports.events.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await reports.events
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(Set(events.map(\.operation)), ["stale_provider_block", "malformed", "lookalike"])
    }
}

private actor ExpiredQuoteTransport: AnkrTransport {
    var requests = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests += 1
        throw EVMSendError.transport
    }
}

private actor ExpiredQuoteReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
