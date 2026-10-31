import XCTest
import OathDiagnostics
@testable import OathAnkr

private final class TronReadTLSFailure: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed)) }
    override func stopLoading() { }
}
private actor TronReadRecoveryTransport: AnkrTransport {
    enum Mode: Sendable { case unavailable, afterVerification, both, wrongChain, wrongGenesis, wrongOwner, badID, malformed, cancelled, http(Int) }
    let mode: Mode
    var requests: [URLRequest] = []
    let tls: AnkrHTTPTransport
    var publicTimes: [Date] = []
    init(_ mode: Mode) {
        self.mode = mode
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TronReadTLSFailure.self]
        tls = AnkrHTTPTransport(session: URLSession(configuration: configuration))
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let url = try XCTUnwrap(request.url)
        let body = try request.httpBody.map { try JSONDecoder().decode(TronJSON.self, from: $0) }
        let isPrimary = url.host == "rpc.ankr.com"
        if isPrimary {
            switch mode {
            case .afterVerification where body?.array?.first?["method"].string == "eth_chainId": break
            case .cancelled: throw URLError(.cancelled)
            case .http(let status): return (Data(), status)
            case .malformed: return (Data("invalid JSON".utf8), 200)
            default: return try await tls.send(request)
            }
        } else {
            publicTimes.append(.now)
            XCTAssertEqual(url.host, "api.trongrid.io")
            if case .both = mode { throw AnkrError.transport }
        }
        let value: TronJSON
        if let calls = body?.array {
            value = .array(try calls.map { call in
                let result: String
                switch call["method"].string {
                case "eth_chainId": result = mode == .wrongChain ? "0x1" : "0x2b6653dc"
                case "eth_call":
                    let data = call["params"].array?.first?["data"].string ?? ""
                    if data.hasPrefix("0x70a08231") { result = "0x" + String(repeating: "0", count: 64 - String(123456789012345, radix: 16).count) + String(123456789012345, radix: 16) }
                    else if data == "0x313ce567" { result = "0x" + String(repeating: "0", count: 63) + "6" }
                    else if data.hasPrefix("0x01ffc9a7") { result = "0x" + String(repeating: "0", count: 64) }
                    else { result = "0x" + "55534454" + String(repeating: "0", count: 56) }
                default: throw TronError.configuration
                }
                return .object(["jsonrpc": .string("2.0"), "id": mode == .badID ? .number("999") : call["id"], "result": .string(result)])
            })
        } else if url.path.hasSuffix("/wallet/getblockbynum") {
            value = .object(["blockID": .string(mode == .wrongGenesis ? "wrong" : TronSendNetwork.mainnet.genesisID)])
        } else if url.path.hasSuffix("/wallet/getaccount") {
            value = .object(["address": .string(mode == .wrongOwner ? TronIdentity.usdt : TronTests.owner), "balance": .number("9007199254740993")])
        } else if url.path.hasPrefix("/v1/accounts/") {
            // An indexed amount is deliberately incorrect. The RPC remains
            // authoritative even when its primary provider is unavailable.
            value = .object(["success": .bool(true), "data": .array([.object(["address": .string(TronTests.owner), "trc20": .array([.object([TronIdentity.usdt: .string("999")])])])])])
        } else { throw TronError.configuration }
        return (try JSONEncoder().encode(value), 200)
    }
    var recoveryRequests: [URLRequest] { requests.filter { $0.url?.host == "api.trongrid.io" && !$0.url!.path.hasPrefix("/v1/") } }
}
extension TronReadRecoveryTransport.Mode: Equatable { }

final class TronReadRecoveryTests: XCTestCase, @unchecked Sendable {
    func testInventoryRecoversNativeAndAuthoritativeTokenAmounts() async throws {
        for mode in [TronReadRecoveryTransport.Mode.unavailable, .afterVerification] {
            let transport = TronReadRecoveryTransport(mode)
            let client = try TronClient(apiKey: "FixtureKey", transport: transport)
            let value = try await client.inventory(owner: TronTests.owner)
            XCTAssertTrue(value.discoveryComplete)
            XCTAssertTrue(value.failedReferences.isEmpty)
            XCTAssertEqual(value.holdings.first { $0.token.reference == "native" }?.amount, "9007199254740993")
            XCTAssertEqual(value.holdings.first { $0.token.reference == TronIdentity.usdt }?.amount, "123456789012345")
            let recovery = await transport.recoveryRequests
            XCTAssertFalse(recovery.isEmpty)
            let times = await transport.publicTimes
            for (earlier, later) in zip(times, times.dropFirst()) {
                XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), 1.0, "Recovery and index share one paced budget")
            }
            XCTAssertTrue(recovery.allSatisfy { !$0.url!.absoluteString.contains("FixtureKey") })
        }
    }
    func testRejectsWrongNetworkOwnerAndMalformedReplies() async throws {
        for mode in [TronReadRecoveryTransport.Mode.wrongChain, .wrongGenesis, .wrongOwner, .badID, .malformed] {
            let transport = TronReadRecoveryTransport(mode)
            do { _ = try await TronClient(apiKey: "FixtureKey", transport: transport).inventory(owner: TronTests.owner); XCTFail("Invalid provider accepted") }
            catch {
                let expected: TronError = mode == .wrongChain || mode == .wrongGenesis ? .wrongNetwork : mode == .wrongOwner ? .wrongOwner : .malformed
                XCTAssertEqual(error as? TronError, expected)
            }
            if mode == .malformed { let recovery = await transport.recoveryRequests; XCTAssertTrue(recovery.isEmpty) }
        }
    }
    func testCancellationAndPermanentHTTPNeverUseRecovery() async throws {
        for mode in [TronReadRecoveryTransport.Mode.cancelled, .http(401)] {
            let transport = TronReadRecoveryTransport(mode)
            do { try await TronClient(apiKey: "FixtureKey", transport: transport).verifyNetwork(); XCTFail("Expected failure") }
            catch {
                if mode == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? TronError, .http(401)) }
            }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
    }
    func testBothProvidersUnavailableStayBounded() async throws {
        let transport = TronReadRecoveryTransport(.both)
        do { try await TronClient(apiKey: "FixtureKey", transport: transport).verifyNetwork(); XCTFail("Expected outage") }
        catch { XCTAssertEqual(error as? TronError, .transport) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 6)
    }
    func testCancellationDuringRetryDoesNotStartAlternateReads() async throws {
        let transport = TronReadRecoveryTransport(.unavailable)
        let client = try TronClient(apiKey: "FixtureKey", transport: transport)
        let task = Task { try await client.verifyNetwork() }
        while await transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled operation completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testHTTP503CanRecoverNetworkVerification() async throws {
        let transport = TronReadRecoveryTransport(.http(503))
        try await TronClient(apiKey: "FixtureKey", transport: transport).verifyNetwork()
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.host == "rpc.ankr.com" }.count, 3)
    }
}

private actor TronReadReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
final class TronReadRecoveryDiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testOriginalTLSAndRecoveryKeepKeysAndWalletsOutOfReports() async throws {
        let reports = TronReadReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let operation = UUID()
        let transport = TronReadRecoveryTransport(.unavailable)
        try await OathDiagnostics.$chain.withValue("tron") {
            try await OathDiagnostics.$operationID.withValue(operation) {
                try await TronClient(apiKey: "PrivateFixtureKey", transport: transport).verifyNetwork()
            }
        }
        let invalid = TronReadRecoveryTransport(.malformed)
        do {
            try await OathDiagnostics.$chain.withValue("tron") {
                try await OathDiagnostics.$operationID.withValue(operation) {
                    try await TronClient(apiKey: "PrivateFixtureKey", transport: invalid).verifyNetwork()
                }
            }
            XCTFail("Malformed response must not verify a network")
        } catch { XCTAssertEqual(error as? TronError, .malformed) }
        let calls = await invalid.requests.count
        XCTAssertEqual(calls, 1, "Malformed replies must not retry or switch providers")
        for _ in 0..<30 {
            await OathDiagnostics.flush()
            if await reports.events.contains(where: { $0.operationID == operation && $0.error.message == "malformed" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let events = await reports.events.filter { $0.operationID == operation }
        XCTAssertTrue(events.contains { $0.error.message == "malformed" })
        XCTAssertTrue(events.contains { $0.operation == "tron_read" && $0.context["attempt"] == "1" })
        XCTAssertFalse(events.contains { $0.error.domain == NSURLErrorDomain || $0.operation == "tron_read_recovery" })
        XCTAssertTrue(events.allSatisfy { $0.privacyFiltered && $0.context["chain"] == "tron" })
        let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(text.contains("PrivateFixtureKey")); XCTAssertFalse(text.contains(TronTests.owner))
    }
}
private actor TronLiveReadRecovery: AnkrTransport {
    let http = AnkrHTTPTransport()
    var primaryFailures = 0
    var secondaryReads = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard let url = request.url else { throw TronError.configuration }
        if url.host == "rpc.ankr.com" { primaryFailures += 1; throw AnkrError.transport }
        guard url.host == "api.trongrid.io", url.scheme == "https" else { throw TronError.configuration }
        if url.path.hasPrefix("/v1/accounts/") { return (Data(#"{"success":true,"data":[]}"#.utf8), 200) }
        guard ["/jsonrpc", "/wallet/getblockbynum", "/wallet/getaccount"].contains(url.path) else { throw TronError.configuration }
        if url.path == "/jsonrpc" {
            let calls = try XCTUnwrap(JSONDecoder().decode(TronJSON.self, from: XCTUnwrap(request.httpBody)).array)
            guard calls.allSatisfy({ ["eth_chainId", "eth_call"].contains($0["method"].string ?? "") }) else { throw TronError.configuration }
        }
        secondaryReads += 1
        return try await http.send(request)
    }
}
final class TronReadRecoveryLiveTests: XCTestCase, @unchecked Sendable {
    func testLiveMainnetIdentityNativeAndTokenReadsAfterPrimaryOutage() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TRON_READ_RECOVERY_LIVE"] == "1" else { throw XCTSkip("Read-only public TronGrid recovery check") }
        let transport = TronLiveReadRecovery()
        let client = try TronClient(apiKey: "UnusedFixtureKey", transport: transport)
        // Small public account from the TronGrid documentation, with no
        // unrelated TRC10 holdings requiring additional metadata routes.
        let inventory = try await client.inventory(owner: "TUoHaVjx7n5xz8LwPRDckgFrDWhMhuSuJM", additionalTokens: [TronIdentity.usdt])
        XCTAssertTrue(inventory.discoveryComplete); XCTAssertTrue(inventory.failedReferences.isEmpty)
        XCTAssertNotNil(inventory.holdings.first { $0.token.reference == "native" })
        let token = try XCTUnwrap(inventory.holdings.first { $0.token.reference == TronIdentity.usdt })
        XCTAssertEqual(token.token.decimals, 6)
        XCTAssertNotNil(Decimal(string: token.amount))
        let reads = await transport.secondaryReads
        XCTAssertGreaterThanOrEqual(reads, 6)
        print("TRON_READ_RECOVERY live chain/genesis, native and USDT reads validated; primary outage injected; discovery stubbed; no signing or broadcast")
    }
}

private actor TronNileReadOutage: AnkrTransport {
    var hosts: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        hosts.append(request.url?.host ?? "")
        throw AnkrError.transport
    }
}
final class TronReadRecoveryBoundaryTests: XCTestCase, @unchecked Sendable {
    func testNileOutageNeverRoutesTestnetReadsToMainnet() async throws {
        let transport = TronNileReadOutage()
        do { try await TronClient(apiKey: "FixtureKey", network: .nile, transport: transport).verifyNetwork(); XCTFail("Expected outage") }
        catch { XCTAssertEqual(error as? TronError, .transport) }
        let hosts = await transport.hosts
        XCTAssertEqual(hosts, Array(repeating: TronSendNetwork.nile.endpoint.host!, count: 3))
    }
}
