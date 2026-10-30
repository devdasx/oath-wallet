import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private let contextOwner = "0x1111111111111111111111111111111111111111"

private actor ContextTransport: AnkrTransport {
    struct Call: Sendable { let chain: String?; let operation: UUID?; let optionalProbe: Bool }
    let chainID: UInt64
    let cancelled: Bool
    var failures: Int
    var calls: [Call] = []
    init(chainID: UInt64 = 1, cancelled: Bool = false, failures: Int = 0) {
        self.chainID = chainID; self.cancelled = cancelled; self.failures = failures
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls.append(.init(chain: OathDiagnostics.chain, operation: OathDiagnostics.operationID,
                           optionalProbe: DiagnosticHTTP.optionalEVMMetadataProbe))
        if cancelled { throw CancellationError() }
        if failures > 0 { failures -= 1; return (Data(), 503) }
        let input = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let rows = try XCTUnwrap(input.array).map { call in
            SolanaJSON.object(["jsonrpc": .string("2.0"), "id": call["id"], "result":
                .string(call["method"].string == "eth_chainId" ? "0x" + String(chainID, radix: 16) : "0x1")])
        }
        return (try JSONEncoder().encode(SolanaJSON.array(rows)), 200)
    }
}

final class ClientDiagnosticContextTests: XCTestCase, @unchecked Sendable {
    func testEveryEVMNetworkSuppliesChainAndFreshRequestCorrelation() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for network in EVMSendNetwork.allCases {
                group.addTask {
                    let transport = ContextTransport(chainID: network.chainID)
                    let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://rpc.example")!], transport: transport)
                    for _ in 0..<2 {
                        let value = try await client.balance(owner: contextOwner, reference: "native")
                        XCTAssertEqual(value, "1")
                    }
                    let calls = await transport.calls
                    XCTAssertEqual(calls.count, 2)
                    XCTAssertTrue(calls.allSatisfy { $0.chain == network.rawValue })
                    XCTAssertTrue(calls.allSatisfy { $0.operation != nil })
                    XCTAssertNotEqual(calls.first?.operation, calls.last?.operation)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertNil(OathDiagnostics.chain)
        XCTAssertNil(OathDiagnostics.operationID)
    }

    func testKnownNetworkOverridesCallerWhilePreservingCorrelationAndOptionalProbe() async throws {
        let transport = ContextTransport(chainID: EVMSendNetwork.ethereum.chainID)
        let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://rpc.example")!], transport: transport)
        let operation = UUID()
        try await OathDiagnostics.$chain.withValue("robinhood") {
            try await OathDiagnostics.$operationID.withValue(operation) {
                _ = try await client.permissionIdentity(address: contextOwner)
                XCTAssertEqual(OathDiagnostics.chain, "robinhood")
                XCTAssertEqual(OathDiagnostics.operationID, operation)
            }
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.chain == "ethereum" && $0.operation == operation && $0.optionalProbe })
        XCTAssertNil(OathDiagnostics.chain)
        XCTAssertNil(OathDiagnostics.operationID)
    }

    func testDeferredClientsKeepCancellationAndChainAtTransportBoundary() async throws {
        for kind in ["arc_state", "arc_send", "robinhood_index", "arc_alchemy", "robinhood_alchemy"] {
            let transport = ContextTransport(cancelled: true)
            do {
                switch kind {
                case "arc_state": _ = try await ArcClient(transport: transport).head()
                case "arc_send": _ = try await ArcSendClient(transport: transport).balance(owner: contextOwner, reference: "native")
                case "robinhood_index":
                    _ = try await RobinhoodClient(apiKey: "fixture", blockscoutKey: "fixture", transport: transport)
                        .history(owner: contextOwner, stream: .transactions)
                default:
                    _ = try await AlchemyHistoryClient(network: kind == "arc_alchemy" ? .arc : .robinhood,
                                                      apiKey: "fixture", transport: transport).request("eth_getBalance", [])
                }
                XCTFail("Cancellation was swallowed")
            } catch { XCTAssertTrue(error is CancellationError) }
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1, "Cancellation must not retry or use a fallback")
            XCTAssertEqual(calls.first?.chain, kind.hasPrefix("arc") ? "arc" : "robinhood")
            XCTAssertNotNil(calls.first?.operation)
        }
    }

    func testAlchemyRetryAndEVMSendFallbackKeepOneOperation() async throws {
        let alchemyTransport = ContextTransport(chainID: UInt64(RobinhoodIdentity.chainID), failures: 1)
        let alchemy = try AlchemyHistoryClient(network: .robinhood, apiKey: "fixture", transport: alchemyTransport)
        _ = try await alchemy.request("eth_getBalance", [])
        let alchemyCalls = await alchemyTransport.calls
        XCTAssertEqual(alchemyCalls.count, 2)
        XCTAssertTrue(alchemyCalls.allSatisfy { $0.chain == "robinhood" && $0.operation != nil })
        XCTAssertEqual(alchemyCalls.first?.operation, alchemyCalls.last?.operation)

        let evmTransport = ContextTransport(failures: 1)
        let evm = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://first.example")!, URL(string: "https://second.example")!], transport: evmTransport)
        _ = try await evm.balance(owner: contextOwner, reference: "native")
        let evmCalls = await evmTransport.calls
        XCTAssertEqual(evmCalls.count, 2)
        XCTAssertTrue(evmCalls.allSatisfy { $0.chain == "ethereum" && $0.operation != nil })
        XCTAssertEqual(evmCalls.first?.operation, evmCalls.last?.operation)
    }
}

private actor ContextReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

/// Exercise the real URLSession/AnkrHTTPTransport diagnostics, without a public
/// network, account, or transaction. The API key and owner are synthetic canaries.
private final class ContextHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let chainID = request.url?.host?.hasPrefix("arc-") == true ? ArcIdentity.chainID : RobinhoodIdentity.chainID
        let body = """
        [{"jsonrpc":"2.0","id":0,"result":"0x\(String(chainID, radix: 16))"},
         {"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"invalid page key"}}]
        """
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class ClientDiagnosticUploadTests: XCTestCase, @unchecked Sendable {
    // Run independently: OathDiagnostics intentionally configures once per process.
    func testRealTransportAndCursorFailureUploadCanonicalChainWithoutSecrets() async throws {
        let reports = ContextReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContextHTTPProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for network in [AlchemyHistoryClient.Network.arc, .robinhood] {
            let client = try AlchemyHistoryClient(network: network, apiKey: "fixture_secret_key", transport: AnkrHTTPTransport(session: session))
            do {
                _ = try await client.transfers(owner: contextOwner, incoming: false, categories: ["external"], cursor: "fixture_secret_cursor")
                XCTFail("Provider rejection succeeded")
            } catch { XCTAssertEqual(error as? AnkrError, .http(422)) }
        }
        for _ in 0..<200 {
            if await reports.events.count >= 8 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events
        XCTAssertEqual(events.count, 8)
        for chain in ["arc", "robinhood"] {
            let matching = events.filter { $0.context["chain"] == chain }
            XCTAssertEqual(matching.count, 4)
            XCTAssertEqual(matching.filter { $0.operation == "provider_response" }.count, 1)
            XCTAssertEqual(matching.filter { $0.operation == "alchemy_cursor" }.count, 1)
            XCTAssertEqual(Set(matching.compactMap(\.operationID)).count, 1)
            XCTAssertTrue(matching.allSatisfy { $0.operationID != nil && $0.privacyFiltered })
        }
        XCTAssertEqual(Set(events.compactMap(\.operationID)).count, 2)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for secret in ["fixture_secret_key", "fixture_secret_cursor", contextOwner, "https://"] {
            XCTAssertFalse(encoded.contains(secret))
        }
    }
}
