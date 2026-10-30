import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

final class MultisigProviderRecoveryTests: XCTestCase {
    private let owner = PublicMultisigTests.xrp
    private let primary = URL(string: "https://rpc.ankr.com/xrp_mainnet/fixture")!
    private var account: PublicMultisigAccount { .init(chain: .xrpl, address: owner) }

    private func response(multisig: Bool = false) -> Data {
        Data("""
        {"result":{"status":"success","validated":true,"account_data":{"Account":"\(owner)"},"signer_lists":\(multisig ? "[{\"SignerQuorum\":1,\"SignerEntries\":[{\"SignerEntry\":{\"Account\":\"\(PublicMultisigTests.signer)\",\"SignerWeight\":1}}]}]" : "[]")}}
        """.utf8)
    }

    func testTransientXRPFailuresUseOneFallbackWithTheExactSameRead() async throws {
        for first in [MultisigRecoveryTransport.Reply.failure(URLError(.timedOut)),
                      .failure(AnkrError.transport), .response(Data("unavailable".utf8), 503)] {
            let transport = MultisigRecoveryTransport([first, .response(response(multisig: true), 200)])
            let checker = PublicMultisigCheck(endpoints: ["xrpl": primary], transport: transport)
            let result = await checker.check(account)
            guard case .confirmed = result else { return XCTFail("Lost the signer policy after failover") }
            let cached = await checker.check(account)
            XCTAssertEqual(cached, result)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests.first?.url, primary)
            XCTAssertEqual(requests.last?.url, XrplSendNetwork.mainnet.endpoint)
            XCTAssertEqual(requests.first?.httpBody, requests.last?.httpBody)
        }
    }

    func testFailureStaysBoundedAndSharedAcrossConcurrentChecks() async throws {
        let transport = MultisigRecoveryTransport(Array(repeating: .failure(URLError(.timedOut)), count: 3))
        let checker = PublicMultisigCheck(endpoints: ["xrpl": primary], transport: transport)
        let account = account
        let results = await withTaskGroup(of: PublicMultisigResult.self) { group in
            for _ in 0..<12 { group.addTask { await checker.check(account) } }
            var values: [PublicMultisigResult] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results, Array(repeating: .unavailable, count: 12))
        let cached = await checker.check(account), calls = await transport.requests.count
        XCTAssertEqual(cached, .unavailable)
        XCTAssertEqual(calls, 2)
    }

    func testInvalidPolicyAuthorizationAndCancellationNeverFallBack() async throws {
        let wrong = Data(String(decoding: response(), as: UTF8.self)
            .replacingOccurrences(of: owner, with: PublicMultisigTests.signer).utf8)
        for first in [MultisigRecoveryTransport.Reply.response(wrong, 200),
                      .response(Data("not JSON".utf8), 200), .response(Data(), 401),
                      .failure(CancellationError()), .failure(URLError(.cancelled))] {
            let transport = MultisigRecoveryTransport([first, .response(response(), 200)])
            let checker = PublicMultisigCheck(endpoints: ["xrpl": primary], transport: transport)
            let result = await checker.check(account), calls = await transport.requests.count
            XCTAssertEqual(result, .unavailable)
            XCTAssertEqual(calls, 1)
        }
    }

    func testMainnetOverrideNeverRedirectsTestnetAndDefaultStillMakesOneRead() async throws {
        for testnet in [false, true] {
            let transport = MultisigRecoveryTransport([.response(response(), 200)])
            let checker = PublicMultisigCheck(endpoints: testnet ? ["xrpl": primary] : [:], transport: transport)
            let result = await checker.check(.init(chain: .xrpl, address: owner, testnet: testnet))
            let requests = await transport.requests
            XCTAssertEqual(result, .notDetected)
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url, (testnet ? XrplSendNetwork.testnet : .mainnet).endpoint)
        }
    }

    func testRetryDiagnosticKeepsChainButNeverPrivateEndpointOrAccount() async throws {
        let capture = MultisigRecoveryReports()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        OathDiagnostics.configure(file: directory.appendingPathComponent("events.json"), transport: capture)
        let secret = "sensitive-fixture-token"
        let transport = MultisigRecoveryTransport([.failure(AnkrError.transport), .response(response(), 200)])
        let checker = PublicMultisigCheck(endpoints: ["xrpl": primary.deletingLastPathComponent().appendingPathComponent(secret)], transport: transport)
        let result = await checker.check(account)
        XCTAssertEqual(result, .notDetected)
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await !capture.events.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events.filter { $0.operation == "public_account_retry" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.context["chain"], "xrpl")
        XCTAssertEqual(events.first?.context["host"], "rpc.ankr.com")
        XCTAssertNotNil(events.first?.operationID)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains(owner))
        XCTAssertFalse(encoded.contains("account_info"))
    }

    func testLiveAuthenticatedPublicAccountAndAbsentHolder() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_RESTRICTION_KEY"], !key.isEmpty else {
            throw XCTSkip("Opt-in read-only public network check")
        }
        let endpoint = primary.deletingLastPathComponent().appendingPathComponent(key)
        let checker = PublicMultisigCheck(endpoints: ["xrpl": endpoint])
        // Published XRPL example account and hash-derived unfunded address;
        // no private wallet contents or signing are involved.
        for address in [owner, "rh58Qu1geRrc8ieM7DhMbyxou8jgbHtxM7"] {
            let result = await checker.check(.init(chain: .xrpl, address: address))
            XCTAssertEqual(result, .notDetected)
        }
    }
}

private actor MultisigRecoveryTransport: AnkrTransport {
    enum Reply: @unchecked Sendable { case response(Data, Int), failure(any Error) }
    private var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        try await Task.sleep(for: .milliseconds(5))
        switch reply {
        case .response(let data, let status): return (data, status)
        case .failure(let error): throw error
        }
    }
}

private actor MultisigRecoveryReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
}
