import XCTest
import OathDiagnostics
@testable import OathAnkr

private final class StellarBrokenConnection: URLProtocol, @unchecked Sendable {
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        let code: URLError.Code = request.url?.path.contains("lost") == true ? .networkConnectionLost:.secureConnectionFailed
        client?.urlProtocol(self,didFailWithError:URLError(code))
    }
    override func stopLoading() { }
}
private actor StellarRecoveryTransport: AnkrTransport {
    enum Failure: Sendable, Equatable { case tls, lost, http(Int), cancelled, malformed, rpc, invalidResponse }
    let failure:Failure
    let failures:Int
    let http:AnkrHTTPTransport
    var requests:[URLRequest] = []
    init(_ failure:Failure = .tls, failures:Int = 1) {
        self.failure = failure; self.failures = failures
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StellarBrokenConnection.self]
        http = AnkrHTTPTransport(session:URLSession(configuration:config))
    }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        requests.append(request)
        if requests.count <= failures {
            switch failure {
            case .tls,.lost:
                var failing = request
                failing.url = URL(string:"https://rpc.test/" + (failure == .lost ? "lost":"tls"))!
                return try await http.send(failing)
            case .invalidResponse: throw URLError(.badServerResponse)
            case .http(let status): return (Data(),status)
            case .cancelled: throw CancellationError()
            case .malformed: return (Data("{}".utf8),200)
            case .rpc: return (Data("{\"error\":{\"code\":-32602}}".utf8),200)
            }
        }
        return (Data("{\"result\":{\"latestLedger\":20,\"events\":null}}".utf8),200)
    }
}

final class StellarReadRecoveryTests:XCTestCase, @unchecked Sendable {
    private func client(_ transport:StellarRecoveryTransport) throws -> StellarClient {
        try StellarClient(endpoint:URL(string:"https://rpc.test")!,horizon:URL(string:"https://horizon.test")!,transport:transport)
    }
    func testLostConnectionAndTLSRecoverWithoutChangingTheRead() async throws {
        for failure in [StellarRecoveryTransport.Failure.lost,.tls] {
            let transport = StellarRecoveryTransport(failure,failures:2)
            let height = try await client(transport).latestLedger(); XCTAssertEqual(height,20)
            let requests = await transport.requests; XCTAssertEqual(requests.count,3)
            XCTAssertTrue(requests.allSatisfy { $0.httpBody == requests.first?.httpBody && $0.url == requests.first?.url })
        }
    }
    func testTransientHTTPStatusesRetryAndPermanentFailuresDoNot() async throws {
        for status in [429,500,503] {
            let transport = StellarRecoveryTransport(.http(status))
            let height = try await client(transport).latestLedger(); XCTAssertEqual(height,20)
            let count = await transport.requests.count; XCTAssertEqual(count,2)
        }
        for status in [400,401,403,404] {
            let transport = StellarRecoveryTransport(.http(status))
            do { _ = try await client(transport).latestLedger(); XCTFail() }
            catch { XCTAssertEqual(error as? StellarError,.http(status)) }
            let count = await transport.requests.count; XCTAssertEqual(count,1)
        }
    }
    func testPersistentFailureStopsAfterThreeAttempts() async throws {
        let transport = StellarRecoveryTransport(.tls,failures:99)
        do { _ = try await client(transport).latestLedger(); XCTFail("Do not invent a history height") }
        catch { XCTAssertEqual(error as? StellarError,.transport) }
        let count = await transport.requests.count; XCTAssertEqual(count,3)
    }
    func testCancellationMalformedAndRPCFailuresNeverRetry() async throws {
        for failure in [StellarRecoveryTransport.Failure.cancelled,.malformed,.rpc] {
            let transport = StellarRecoveryTransport(failure)
            do { _ = try await client(transport).latestLedger(); XCTFail() }
            catch {
                if failure == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertNotNil(error as? StellarError) }
            }
            let count = await transport.requests.count; XCTAssertEqual(count,1)
        }
    }
    func testCancellationDuringBackoffStopsBeforeAnotherRequest() async throws {
        let transport = StellarRecoveryTransport(.tls,failures:99), client = try client(transport)
        let task = Task { try await client.latestLedger() }
        while await transport.requests.isEmpty { await Task.yield() }
        try await Task.sleep(for:.milliseconds(50)); task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.requests.count; XCTAssertEqual(count,1)
    }
    func testEventRetryPreservesCursorAndWindow() async throws {
        let transport = StellarRecoveryTransport(.lost)
        let page = try await client(transport).events(owner:"GBEBCRCJ5VX7GERSGJ5XGJX7K2CHNVQB67K2KGCX7RFGMCBIIZQ5E4GY",startLedger:1,endLedger:20,cursor:"saved")
        XCTAssertTrue(page.complete); XCTAssertEqual(page.next,"saved")
        let requests = await transport.requests; XCTAssertEqual(requests.count,2)
        XCTAssertEqual(requests.first?.httpBody,requests.last?.httpBody)
    }
}

private actor StellarRetryReports:DiagnosticTransport {
    var events:[DiagnosticEvent] = []
    func upload(_ events:[DiagnosticEvent]) async throws { self.events += events }
}
final class StellarReadRecoveryDiagnosticsTests:XCTestCase, @unchecked Sendable {
    func testOriginalFailureAndAttemptStayPrivateAndCorrelated() async throws {
        let reports = StellarRetryReports(), operation = UUID()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at:file) }
        OathDiagnostics.configure(file:file,transport:reports)
        let client = try StellarClient(apiKey:"privateFixtureKey",transport:StellarRecoveryTransport(.lost))
        let height = try await OathDiagnostics.$operationID.withValue(operation) {
            try await OathDiagnostics.$chain.withValue("stellar") { try await client.latestLedger() }
        }
        XCTAssertEqual(height,20)
        let invalid = StellarRecoveryTransport(.invalidResponse)
        do {
            _ = try await OathDiagnostics.$operationID.withValue(operation) {
                try await OathDiagnostics.$chain.withValue("stellar") {
                    try await StellarClient(apiKey:"privateFixtureKey",transport:invalid).latestLedger()
                }
            }
            XCTFail("Invalid response must not yield a ledger")
        } catch { XCTAssertEqual(error as? StellarError, .transport) }
        let calls = await invalid.requests.count
        XCTAssertEqual(calls, 1, "A permanent invalid response is not retryable")
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.contains(where: { $0.operation == "stellar_read" }) { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        let events = await reports.events.filter { $0.operationID == operation }
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events.contains { $0.error.domain == NSURLErrorDomain && $0.error.code == URLError.badServerResponse.rawValue })
        XCTAssertFalse(events.contains { $0.error.code == URLError.networkConnectionLost.rawValue })
        XCTAssertTrue(events.contains { $0.operation == "stellar_read" && $0.context["attempt"] == "1" })
        XCTAssertTrue(events.allSatisfy { $0.privacyFiltered && $0.context["chain"] == "stellar" })
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(events),as:UTF8.self).contains("privateFixtureKey"))
    }
}

private actor StellarInventoryRetryTransport:AnkrTransport {
    let fail:Bool
    var attempts:[String:Int] = [:]
    init(fail:Bool = true) { self.fail = fail }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let key = request.url!.path + String(decoding:request.httpBody ?? Data(),as:UTF8.self)
        attempts[key,default:0] += 1
        if fail && attempts[key] == 1 { throw AnkrError.transport }
        let name:String
        if request.httpMethod == "POST" {
            let body = try JSONDecoder().decode(StellarJSON.self,from:request.httpBody!)
            name = body["params"]["onlyWhitelisted"] == .bool(true) ? "whitelist":"inventory"
        } else { name = request.url!.path.contains("accounts/") ? "sdf":"root" }
        return (try Data(contentsOf:Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures/Stellar")!),200)
    }
}
final class StellarInventoryRecoveryTests:XCTestCase, @unchecked Sendable {
    func testRecoveredFullInventoryMatchesHealthyReadIncludingWhitelistAndTrustlines() async throws {
        let owner = "GBEBCRCJ5VX7GERSGJ5XGJX7K2CHNVQB67K2KGCX7RFGMCBIIZQ5E4GY"
        let recovered = try await StellarClient(apiKey:"fixture",transport:StellarInventoryRetryTransport()).inventory(owner:owner)
        let healthy = try await StellarClient(apiKey:"fixture",transport:StellarInventoryRetryTransport(fail:false)).inventory(owner:owner)
        XCTAssertEqual(recovered.holdings.map(\.reference),healthy.holdings.map(\.reference))
        XCTAssertEqual(recovered.holdings.map(\.amount),healthy.holdings.map(\.amount))
        XCTAssertEqual(recovered.holdings.map(\.token),healthy.holdings.map(\.token))
        XCTAssertEqual(recovered.verified,healthy.verified); XCTAssertEqual(recovered.ledger.height,healthy.ledger.height)
        XCTAssertEqual(recovered.exists,healthy.exists)
        XCTAssertEqual(try JSONDecoder().decode(StellarJSON.self,from:recovered.raw),try JSONDecoder().decode(StellarJSON.self,from:healthy.raw))
    }
}

private actor StellarLiveRetryTransport:AnkrTransport {
    let failing:AnkrHTTPTransport
    let live = AnkrHTTPTransport()
    var calls = 0
    init() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StellarBrokenConnection.self]
        failing = AnkrHTTPTransport(session:URLSession(configuration:config))
    }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        calls += 1
        if calls == 1 { return try await failing.send(request) }
        return try await live.send(request)
    }
}
final class StellarLiveReadRecoveryTests:XCTestCase, @unchecked Sendable {
    func testLiveHistoryIndexReadRecoversInjectedTLSFailure() async throws {
        guard ProcessInfo.processInfo.environment["OATH_STELLAR_RECOVERY_LIVE"] == "1" else { throw XCTSkip("Opt-in public read") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let keys = try PropertyListDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let transport = StellarLiveRetryTransport()
        let height = try await StellarClient(apiKey:XCTUnwrap(keys["AnkrAPIKey"]),transport:transport).latestLedger()
        XCTAssertGreaterThan(height,0)
        let count = await transport.calls; XCTAssertEqual(count,2)
        print("Live Stellar history index: valid ledger returned after injected TLS failure")
    }
}
