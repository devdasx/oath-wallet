import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

final class StablecoinSolanaRecoveryTests: XCTestCase, @unchecked Sendable {
    private let endpoint = URL(string: "https://primary.example/solana")!
    private let owner = "11111111111111111111111111111111"
    private var tokens: [StablecoinRestrictionToken] {
        StablecoinRestrictionRegistry.tokens.filter { $0.network == "solana" }
    }

    func testReportedTimeoutRecoversBothTokenPoliciesWithVerifiedMainnetAndExactIdentity() async throws {
        let transport = SolanaPolicyRecoveryTransport()
        let results = await StablecoinRestrictionCheck(endpoints: ["solana": endpoint], transport: transport)
            .check(.init(network: "solana", address: owner), tokens: tokens)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first { $0.token.symbol == "USDT" }?.outcome, .restricted)
        XCTAssertEqual(results.first { $0.token.symbol == "USDC" }?.outcome, .notDetected)
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.host == "primary.example" && $0.method == "getTokenAccountsByOwner" }.count, 2)
        let fallback = calls.filter { $0.host == "api.mainnet-beta.solana.com" }
        XCTAssertEqual(fallback.count, 4, "One identity check and one bounded read per token")
        XCTAssertEqual(Set(fallback.filter { $0.method == "getTokenAccountsByOwner" }.compactMap(\.mint)), Set(tokens.map(\.reference)))
        XCTAssertTrue(fallback.filter { $0.method == "getTokenAccountsByOwner" }.allSatisfy { $0.owner == owner && $0.commitment == "finalized" })
    }

    func testFallbackFailureWrongChainAndMalformedPolicyStayUnavailable() async {
        for mode in [SolanaPolicyRecoveryTransport.Mode.outage, .wrongChain, .wrongOwner, .wrongMint, .malformed] {
            let transport = SolanaPolicyRecoveryTransport(mode: mode)
            let results = await StablecoinRestrictionCheck(endpoints: ["solana": endpoint], transport: transport)
                .check(.init(network: "solana", address: owner), tokens: [tokens[0]])
            XCTAssertEqual(results.map(\.outcome), [.unavailable], "\(mode)")
            let calls = await transport.calls
            XCTAssertLessThanOrEqual(calls.count, 4)
            if mode == .wrongChain {
                XCTAssertFalse(calls.contains { $0.host != "primary.example" && $0.method == "getTokenAccountsByOwner" })
            }
        }
    }

    func testPermanentPrimaryErrorsAndCancellationNeverStartFallback() async {
        for mode in [SolanaPolicyRecoveryTransport.Mode.primaryMalformed, .primaryRPC, .cancelled] {
            let transport = SolanaPolicyRecoveryTransport(mode: mode)
            let results = await StablecoinRestrictionCheck(endpoints: ["solana": endpoint], transport: transport)
                .check(.init(network: "solana", address: owner), tokens: [tokens[0]])
            XCTAssertEqual(results.map(\.outcome), [.unavailable])
            let calls = await transport.calls
            XCTAssertTrue(calls.allSatisfy { $0.host == "primary.example" })
        }
    }

    func testPublicPrimaryDoesNotRetryItself() async {
        let transport = SolanaPolicyRecoveryTransport(mode: .outage)
        let results = await StablecoinRestrictionCheck(endpoints: ["solana": StablecoinRestrictionCheck.publicMainnetEndpoints["solana"]!], transport: transport)
            .check(.init(network: "solana", address: owner), tokens: [tokens[0]])
        XCTAssertEqual(results.map(\.outcome), [.unavailable])
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testRecoveredAvailabilityIsExcludedButPermanentFailureRetainsPrivateDiagnostic() async throws {
        let reports = SolanaPolicyReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let transport = SolanaPolicyRecoveryTransport()
        let endpoint = endpoint.appendingPathComponent("fixtureCredentialNeverLog")
        _ = await StablecoinRestrictionCheck(endpoints: ["solana": endpoint], transport: transport)
            .check(.init(network: "solana", address: owner), tokens: [tokens[0]])
        // Availability failures are intentionally excluded by the shared policy.
        // A permanent malformed response must still report, with private data removed.
        _ = await StablecoinRestrictionCheck(endpoints: ["solana": endpoint],
                transport: SolanaPolicyRecoveryTransport(mode: .primaryMalformed))
            .check(.init(network: "solana", address: owner), tokens: [tokens[0]])
        for _ in 0..<100 {
            if await reports.events.contains(where: { $0.operation == "restriction_probe" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.operation, "restriction_probe")
        XCTAssertEqual(event.error.domain, "OathAnkr.StablecoinRestrictionCheck.Failure")
        XCTAssertEqual(event.error.message, "malformed")
        XCTAssertEqual(event.context["chain"], "solana")
        XCTAssertEqual(event.context["stage"], "token_policy")
        XCTAssertNotNil(event.operationID)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for privateValue in [owner, tokens[0].reference, "fixtureCredentialNeverLog", "getTokenAccountsByOwner"] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
    }

    func testTransientHTTPAndRPCFailuresRecoverWithoutRetryingPrimary() async {
        for mode in [SolanaPolicyRecoveryTransport.Mode.http503, .rpcBusy] {
            let transport = SolanaPolicyRecoveryTransport(mode: mode)
            let results = await StablecoinRestrictionCheck(endpoints: ["solana": endpoint], transport: transport)
                .check(.init(network: "solana", address: owner), tokens: [tokens[0]])
            XCTAssertNotEqual(results.first?.outcome, .unavailable)
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 4)
        }
    }

    func testLivePublicPolicyRecoveryAfterInjectedPrimaryTimeout() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SOLANA_POLICY_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public system-program policy reads only")
        }
        let baseline = await StablecoinRestrictionCheck.publicMainnet().check(.init(network: "solana", address: owner), tokens: tokens)
        XCTAssertEqual(baseline.count, 2)
        XCTAssertTrue(baseline.allSatisfy { $0.outcome == .notDetected })
        let transport = SolanaPolicyLiveTransport()
        let recovered = await StablecoinRestrictionCheck(endpoints: ["solana": endpoint], transport: transport)
            .check(.init(network: "solana", address: owner), tokens: tokens)
        XCTAssertEqual(recovered.map(\.outcome), baseline.map(\.outcome))
        let injections = await transport.injections
        XCTAssertEqual(injections, 2)
    }
}

private actor SolanaPolicyReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private actor SolanaPolicyRecoveryTransport: AnkrTransport {
    enum Mode { case success, outage, wrongChain, wrongOwner, wrongMint, malformed, primaryMalformed, primaryRPC, cancelled, http503, rpcBusy }
    struct Call: Sendable { let host: String; let method: String; let owner: String?; let mint: String?; let commitment: String? }
    let mode: Mode
    private(set) var calls: [Call] = []
    init(mode: Mode = .success) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        let method = body["method"].string!, params = body["params"].array ?? []
        let host = request.url!.host!, primary = host == "primary.example"
        calls.append(.init(host: host, method: method, owner: params.first?.string,
                           mint: params.count > 1 ? params[1]["mint"].string : nil,
                           commitment: params.count > 2 ? params[2]["commitment"].string : nil))
        func response(_ result: SolanaJSON) throws -> (Data, Int) {
            (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": result])), 200)
        }
        if method == "getGenesisHash" {
            return try response(.string(!primary && mode == .wrongChain ? "wrong" : SolanaIdentity.genesis))
        }
        XCTAssertEqual(method, "getTokenAccountsByOwner")
        if primary {
            switch mode {
            case .primaryMalformed: return try response(.null)
            case .primaryRPC, .rpcBusy:
                return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"),
                    "error": .object(["code": .number(mode == .rpcBusy ? "-32005" : "-32602")])])), 200)
            case .cancelled: throw URLError(.cancelled)
            case .http503: return (Data("<html>Service unavailable</html>".utf8), 503)
            default: throw AnkrError.transport
            }
        }
        if mode == .outage { throw URLError(.timedOut) }
        if mode == .malformed { return try response(.object(["value": .array([])])) }
        let mint = params[1]["mint"].string!
        let frozen = StablecoinRestrictionRegistry.tokens.contains { $0.network == "solana" && $0.reference == mint && $0.symbol == "USDT" }
        let row: SolanaJSON = .object([
            "pubkey": .string("11111111111111111111111111111111"),
            "account": .object(["owner": .string(SolanaIdentity.tokenProgram), "data": .object([
                "parsed": .object(["type": .string("account"), "info": .object([
                    "owner": mode == .wrongOwner ? .string("wrong") : params[0],
                    "mint": .string(mode == .wrongMint ? "wrong" : mint),
                    "state": .string(frozen ? "frozen" : "initialized")])])])])])
        return try response(.object(["context": .object(["slot": .number("123")]), "value": .array([row])]))
    }
}

private actor SolanaPolicyLiveTransport: AnkrTransport {
    private let base = AnkrHTTPTransport()
    private(set) var injections = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "primary.example" {
            let body = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
            if body["method"].string == "getGenesisHash" {
                return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": .string(SolanaIdentity.genesis)])), 200)
            }
            injections += 1
            throw AnkrError.transport
        }
        return try await base.send(request)
    }
}
