import XCTest
import OathDiagnostics
@testable import OathAnkr

private final class TonReadTLSFailure: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed)) }
    override func stopLoading() { }
}

private actor TonReadRecoveryTransport: AnkrTransport {
    enum Mode: Sendable { case tls, afterVerification, both, wrongNetwork, malformed, invalidJSON, rpcFailure, badID, legacyPrimary, cancelled, unauthorized, http(Int), wrongOwner }
    let mode: Mode
    let tls: AnkrHTTPTransport
    var requests: [URLRequest] = []
    init(_ mode: Mode) {
        self.mode = mode
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TonReadTLSFailure.self]
        tls = AnkrHTTPTransport(session: URLSession(configuration: configuration))
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if request.url?.host == "tonapi.io" {
            return (try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "inventory", withExtension: "json", subdirectory: "Fixtures/Ton"))), 200)
        }
        let call = try JSONDecoder().decode(TonJSON.self, from: XCTUnwrap(request.httpBody))
        let method = try XCTUnwrap(call["method"].string)
        let primary = request.url?.host == "rpc.ankr.com"
        if primary {
            switch mode {
            case .cancelled: throw URLError(.cancelled)
            case .unauthorized: return (Data(), 401)
            case .http(let status): return (Data(), status)
            case .malformed: return (Data("{}".utf8), 200)
            case .invalidJSON: return (Data("invalid json".utf8), 200)
            case .rpcFailure: return (Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"invalid params"}}"#.utf8), 200)
            case .afterVerification where method == "getMasterchainInfo", .legacyPrimary: break
            default: return try await tls.send(request)
            }
        } else {
            XCTAssertEqual(request.url?.absoluteString, "https://toncenter.com/api/v2/jsonRPC")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            if case .both = mode { throw AnkrError.transport }
        }
        let result: TonJSON
        switch method {
        case "getMasterchainInfo":
            result = .object(["init": .object(["root_hash": .string(mode == .wrongNetwork ? "wrong" : TonIdentity.genesis)])])
        case "getAddressInformation": result = .object(["state": .string("active"), "balance": .string("6684406248")])
        case "getTokenData": result = .object(["contract_type": .string("jetton_wallet"), "owner": .string(mode == .wrongOwner ? TonIdentity.usdt : TonTests.owner), "jetton": .string(TonIdentity.usdt), "balance": .string("879187990649145")])
        case "runGetMethod":
            let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "walletBinding", withExtension: "json", subdirectory: "Fixtures/Ton")))
            result = try JSONDecoder().decode(TonJSON.self, from: data)["result"]
        default: XCTFail("Unexpected method: \(method)"); throw TonError.configuration
        }
        let legacy = !primary || mode == .legacyPrimary
        let value: TonJSON = mode == .badID && !primary
            ? .object(["jsonrpc": .string("2.0"), "id": .number("2"), "result": result])
            : legacy ? .object(["ok": .bool(true), "result": result])
            : .object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": result])
        return (try JSONEncoder().encode(value), 200)
    }
    var secondaryMethods: [String] {
        requests.filter { $0.url?.host == "toncenter.com" }.compactMap { request in
            (try? JSONDecoder().decode(TonJSON.self, from: request.httpBody!))?["method"].string
        }
    }
}

extension TonReadRecoveryTransport.Mode: Equatable { }

final class TonReadRecoveryTests: XCTestCase, @unchecked Sendable {
    func testTLSRecoveryKeepsNativeJettonAmountsAndOwnershipChecks() async throws {
        for mode in [TonReadRecoveryTransport.Mode.tls, .afterVerification] {
            let transport = TonReadRecoveryTransport(mode)
            let client = TonClient(testTransport: transport)
            let value = try await client.inventory(owner: TonTests.owner)
            XCTAssertTrue(value.discoveryComplete)
            XCTAssertTrue(value.failedReferences.isEmpty)
            XCTAssertEqual(value.holdings.first { $0.token.reference == "native" }?.amount, "6684406248")
            XCTAssertEqual(value.holdings.first { $0.token.reference == TonIdentity.usdt }?.amount, "879187990649145")
            let methods = await transport.secondaryMethods
            XCTAssertEqual(methods.first, "getMasterchainInfo")
            XCTAssertTrue(methods.contains("runGetMethod"))
            XCTAssertTrue(methods.contains("getTokenData"))
        }
    }
    func testWrongNetworkAndInvalidEnvelopesNeverBecomeBalanceData() async throws {
        for mode in [TonReadRecoveryTransport.Mode.wrongNetwork, .badID, .malformed, .invalidJSON, .legacyPrimary] {
            let transport = TonReadRecoveryTransport(mode)
            do { try await TonClient(testTransport: transport).verifyNetwork(); XCTFail("Invalid network accepted") }
            catch { XCTAssertEqual(error as? TonError, mode == .wrongNetwork ? .wrongNetwork : .malformed) }
            if mode == .malformed || mode == .invalidJSON || mode == .legacyPrimary {
                let methods = await transport.secondaryMethods; XCTAssertTrue(methods.isEmpty)
            }
        }
    }
    func testCancellationAndAuthorizationNeverFailOver() async throws {
        for mode in [TonReadRecoveryTransport.Mode.cancelled, .unauthorized] {
            let transport = TonReadRecoveryTransport(mode)
            do { try await TonClient(testTransport: transport).verifyNetwork(); XCTFail("Expected failure") }
            catch {
                if mode == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? TonError, .http(401)) }
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }
    func testPersistentOutageStopsAfterEachProvidersBoundedAttempts() async throws {
        let transport = TonReadRecoveryTransport(.both)
        do { try await TonClient(testTransport: transport).verifyNetwork(); XCTFail("Outage accepted") }
        catch { XCTAssertEqual(error as? TonError, .transport) }
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.host == "rpc.ankr.com" }.count, 3)
        XCTAssertEqual(requests.filter { $0.url?.host == "toncenter.com" }.count, 3)
    }
    func testTransientHTTPRecoversButPermanentHTTPDoesNot() async throws {
        for status in [429, 503, 400] {
            let transport = TonReadRecoveryTransport(.http(status))
            do { try await TonClient(testTransport: transport).verifyNetwork(); XCTAssertNotEqual(status, 400) }
            catch { XCTAssertEqual(status, 400); XCTAssertEqual(error as? TonError, .http(400)) }
            let methods = await transport.secondaryMethods
            XCTAssertEqual(methods, status == 400 ? [] : ["getMasterchainInfo"])
        }
    }
    func testCancellationDuringBackoffStopsRecovery() async throws {
        let transport = TonReadRecoveryTransport(.tls)
        let client = TonClient(testTransport: transport)
        let task = Task { try await client.verifyNetwork() }
        while await transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled read returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testProviderRejectionAndUnknownMethodsNeverFailOver() async throws {
        let rejected = TonReadRecoveryTransport(.rpcFailure)
        do { try await TonClient(testTransport: rejected).verifyNetwork(); XCTFail("RPC error accepted") }
        catch { XCTAssertEqual(error as? TonError, .rpc(-32602)) }
        let rejectedRequests = await rejected.requests
        XCTAssertEqual(rejectedRequests.count, 1)
        let transport = TonReadRecoveryTransport(.tls)
        do { _ = try await TonClient(testTransport: transport).rpc("unsupportedMethod"); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? TonError, .transport) }
        let secondary = await transport.secondaryMethods
        XCTAssertTrue(secondary.isEmpty)
    }
    func testRecoveredProviderCannotSubstituteAnotherJettonOwner() async throws {
        let transport = TonReadRecoveryTransport(.wrongOwner)
        let value = try await TonClient(testTransport: transport).inventory(owner: TonTests.owner)
        XCTAssertEqual(value.failedReferences, [TonIdentity.usdt])
        XCTAssertEqual(value.holdings.count, 1)
    }
}

private actor TonReadReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
final class TonReadRecoveryDiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testOriginalTLSAndRecoveryReportsRemainPrivacyFiltered() async throws {
        let reports = TonReadReports()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        OathDiagnostics.configure(file: folder.appendingPathComponent("events.json"), transport: reports)
        let operation = UUID()
        let transport = TonReadRecoveryTransport(.tls)
        try await OathDiagnostics.$chain.withValue("ton") {
            try await OathDiagnostics.$operationID.withValue(operation) {
                try await TonClient(apiKey: "FixtureKeyPrivate123", transport: transport).verifyNetwork()
            }
        }
        let invalid = TonReadRecoveryTransport(.invalidJSON)
        do {
            try await OathDiagnostics.$chain.withValue("ton") {
                try await OathDiagnostics.$operationID.withValue(operation) {
                    try await TonClient(apiKey: "FixtureKeyPrivate123", transport: invalid).verifyNetwork()
                }
            }
            XCTFail("Malformed response must not verify a network")
        } catch { XCTAssertEqual(error as? TonError, .malformed) }
        let calls = await invalid.requests.count
        XCTAssertEqual(calls, 1, "Malformed replies must not retry or switch providers")
        for _ in 0..<30 {
            await OathDiagnostics.flush()
            if await reports.events.contains(where: { $0.operationID == operation && $0.error.message == "malformed" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let events = await reports.events.filter { $0.operationID == operation }
        XCTAssertTrue(events.contains { $0.error.message == "malformed" })
        XCTAssertTrue(events.contains { $0.operation == "ton_read" && $0.context["attempt"] == "1" })
        XCTAssertFalse(events.contains { $0.error.domain == NSURLErrorDomain || $0.operation == "ton_read_recovery" })
        XCTAssertTrue(events.allSatisfy { $0.privacyFiltered && $0.context["chain"] == "ton" })
        let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(text.contains("FixtureKeyPrivate123"))
        XCTAssertFalse(text.contains(TonTests.owner))
    }
}

private actor TonLiveReadRecovery: AnkrTransport {
    let http = AnkrHTTPTransport()
    var primaryFailures = 0
    var secondaryReads = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "rpc.ankr.com" { primaryFailures += 1; throw AnkrError.transport }
        guard request.url?.absoluteString == "https://toncenter.com/api/v2/jsonRPC" else { throw TonError.configuration }
        let call = try JSONDecoder().decode(TonJSON.self, from: XCTUnwrap(request.httpBody))
        guard ["getMasterchainInfo", "getAddressInformation"].contains(call["method"].string ?? "") else { throw TonError.configuration }
        secondaryReads += 1
        return try await http.send(request)
    }
}
final class TonReadRecoveryLiveTests: XCTestCase, @unchecked Sendable {
    func testRealMainnetIdentityAndReadAfterPrimaryOutage() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TON_READ_RECOVERY_LIVE"] == "1" else { throw XCTSkip("Read-only public TON Center recovery check") }
        let transport = TonLiveReadRecovery()
        let client = try TonClient(apiKey: "UnusedFixtureKey", transport: transport)
        try await client.verifyNetwork()
        let account = try await client.rpc("getAddressInformation", ["address": .string("0:" + String(repeating: "0", count: 64))])
        XCTAssertTrue(["active", "uninitialized", "frozen"].contains(account["state"].string ?? ""))
        let amount = try TonIdentity.amount(account["balance"])
        XCTAssertFalse(amount.isEmpty)
        let primary = await transport.primaryFailures, secondary = await transport.secondaryReads
        XCTAssertEqual(primary, 6); XCTAssertEqual(secondary, 2)
        print("TON_READ_RECOVERY live mainnet genesis and native account validated; primary outage injected; read-only; no credentials or broadcasts")
    }
}
