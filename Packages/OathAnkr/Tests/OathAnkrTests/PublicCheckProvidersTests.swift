import Foundation
import XCTest
@testable import OathAnkr

@MainActor final class PublicCheckProvidersTests: XCTestCase {
    func testPaidRoutesKeepRESTAndGraphQLProtocolsAndPublicExceptions() throws {
        let endpoints = try PublicCheckProviders.endpoints(ankrAPIKey: "fixture")
        XCTAssertEqual(endpoints["ethereum"]?.path, "/eth/fixture")
        XCTAssertEqual(endpoints["tron"]?.path, "/premium-http/tron/fixture")
        XCTAssertEqual(endpoints["aptos"]?.path, "/premium-http/aptos/fixture/v1")
        XCTAssertEqual(endpoints["sui"]?.path, "/premium-http/sui_graphql/fixture")
        XCTAssertEqual(endpoints["ton"]?.path, "/ton_api_v2/fixture")
        XCTAssertNotEqual(endpoints["arc"]?.host, "rpc.ankr.com")
        XCTAssertEqual(endpoints["stellar"]?.host, "horizon.stellar.org")
        XCTAssertThrowsError(try PublicCheckProviders.endpoints(ankrAPIKey: ""))
        XCTAssertThrowsError(try PublicCheckProviders.endpoints(ankrAPIKey: "bad/key"))
        let request = try PublicMultisigCheck.request(.init(chain: .tron, address: PublicMultisigTests.tron),
                                                    endpoint: endpoints["tron"])
        XCTAssertEqual(request.url?.path, "/premium-http/tron/fixture/walletsolidity/getaccount")
    }

    func testRequestBudgetIsConcurrentBoundedAndCancellationReleasesSlots() async throws {
        let base = ConcurrentCheckFixture()
        let transport = PublicCheckTransport(maximumRequests: 3, transport: base)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = try await transport.send(URLRequest(url: URL(string: "https://rpc.ankr.com/eth/fixture")!))
                }
            }
            try await group.waitForAll()
        }
        let peak = await base.peak
        XCTAssertEqual(peak, 3)
        let task = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        _ = try await transport.send(URLRequest(url: URL(string: "https://rpc.ankr.com/eth/fixture")!))
                    }
                }
                try await group.waitForAll()
            }
        }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        do { try await task.value; XCTFail("Cancelled work completed") } catch is CancellationError {}
        _ = try await transport.send(URLRequest(url: URL(string: "https://rpc.ankr.com/eth/fixture")!))
        let active = await base.active
        XCTAssertEqual(active, 0)
    }

    func testOnlyNetworkMetadataIsCachedNotAccountResults() async throws {
        let base = ConcurrentCheckFixture()
        let transport = PublicCheckTransport(transport: base)
        func request(_ method: String) -> URLRequest {
            var value = URLRequest(url: URL(string: "https://rpc.ankr.com/eth/fixture")!)
            value.httpMethod = "POST"
            value.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"METHOD","params":[]}"#.replacingOccurrences(of: "METHOD", with: method).utf8)
            return value
        }
        for _ in 0..<3 { _ = try await transport.send(request("eth_chainId")) }
        var reordered = request("eth_chainId")
        reordered.httpBody = Data(#"{"params":[],"method":"eth_chainId","id":1,"jsonrpc":"2.0"}"#.utf8)
        _ = try await transport.send(reordered)
        for _ in 0..<3 { _ = try await transport.send(request("eth_getCode")) }
        let count = await base.count
        XCTAssertEqual(count, 4)
    }

    func testPaidCapacityReachesBoundButPublicHostRemainsLimited() async throws {
        for (host, expected) in [("rpc.ankr.com", 128), ("public-fixture.example", 4)] {
            let base = ConcurrentCheckFixture()
            let transport = PublicCheckTransport(transport: base)
            let url = URL(string: "https://" + host + "/fixture")!
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<140 {
                    group.addTask { _ = try await transport.send(URLRequest(url: url)) }
                }
                try await group.waitForAll()
            }
            let peak = await base.peak
            XCTAssertEqual(peak, expected)
        }
    }

    func testQueuedMetadataReusesCompletedResponseWithoutRepeatingAccountProbes() async throws {
        let base = ConcurrentCheckFixture()
        let transport = PublicCheckTransport(maximumRequests: 1, transport: base)
        var request = URLRequest(url: URL(string: "https://rpc.ankr.com/eth/fixture")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}"#.utf8)
        let value = request
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { _ = try await transport.send(value) } }
            try await group.waitForAll()
        }
        let count = await base.count
        XCTAssertEqual(count, 1)
    }

    func testPaidNEARIdentityUsesSupportedGenesisMethodAndRejectsWrongChain() async throws {
        for (host, method) in [("rpc.ankr.com", "EXPERIMENTAL_genesis_config"), ("rpc.mainnet.near.org", "status")] {
            for chain in ["mainnet", "testnet"] {
                let base = NearNetworkFixture(chain: chain)
                let checker = StablecoinRestrictionCheck(endpoints: [:], transport: base)
                let url = URL(string: "https://" + host + "/near/fixture")!
                do {
                    try await checker.verify(.init(network: "near", address: "wrap.near"), url)
                    XCTAssertEqual(chain, "mainnet")
                } catch {
                    XCTAssertEqual(chain, "testnet")
                }
                let methods = await base.methods
                XCTAssertEqual(methods, [method])
            }
        }
    }

    func testUncreatedNEARAccountRequiresExactMissingAccountEvidence() throws {
        let owner = "public-fixture.near"
        let missing: SolanaJSON = .object(["jsonrpc": .string("2.0"), "id": .number("1"),
            "error": .object(["code": .number("-32000"),
                              "data": .string("account \(owner) does not exist while viewing")])])
        XCTAssertFalse(try PublicSigningAuthority.nearAccountExists(missing, address: owner))
        XCTAssertThrowsError(try PublicSigningAuthority.nearAccountExists(missing, address: "another.near"))
        XCTAssertThrowsError(try PublicSigningAuthority.nearAccountExists(.object([:]), address: owner))
        let present: SolanaJSON = .object(["jsonrpc": .string("2.0"), "id": .number("1"),
            "result": .object(["amount": .string("0"), "storage_usage": .number("128")])])
        XCTAssertTrue(try PublicSigningAuthority.nearAccountExists(present, address: owner))
    }

    /// Public fixtures only. Never prints URLs, configuration, or user records.
    func testLivePaidProvidersBeforeClaimingWallets() async throws {
        guard let path = ProcessInfo.processInfo.environment["VAULT_PAID_PROVIDER_CONFIG"] else {
            throw XCTSkip("Opt-in paid provider compatibility check")
        }
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let endpoints = try PublicCheckProviders.endpoints(ankrAPIKey: config["AnkrAPIKey"] ?? "")
        let transport = PublicCheckTransport()
        let authority = PublicSigningAuthority(endpoints: endpoints, transport: transport)
        let restrictions = StablecoinRestrictionCheck(endpoints: endpoints, transport: transport)
        let owners = ["solana": SolanaIdentity.wrappedSOL, "tron": PublicMultisigTests.tron,
                      "near": "wrap.near", "aptos": "0x1", "sui": "0x1", "ton": TonIdentity.usdt,
                      "stellar": PublicMultisigTests.stellar, "xrpl": PublicMultisigTests.xrp]
        let selected = ProcessInfo.processInfo.environment["VAULT_PAID_NETWORKS"]?.split(separator: ",").map(String.init)
        let networks = Set(endpoints.keys).filter { selected == nil || selected!.contains($0) }.sorted()
        try await withThrowingTaskGroup(of: (String, PublicSigningAssessment, [StablecoinRestrictionResult]).self) { group in
            for network in networks {
                group.addTask {
                    let address = owners[network] ?? "0x0000000000000000000000000000000000000001"
                    async let signing = authority.check(.init(network: network, address: address))
                    let tokens = StablecoinRestrictionRegistry.tokens(network: network)
                    async let token = tokens.isEmpty ? [] : restrictions.check(.init(network: network, address: address), tokens: tokens)
                    return try await (network, signing, token)
                }
            }
            for try await (network, signing, tokens) in group {
                print("PAID PROVIDER \(network): signing=\(signing.coverage.rawValue), tokens=\(tokens.filter { $0.outcome != .unavailable }.count)/\(tokens.count)")
                XCTAssertNotEqual(signing.coverage, .unavailable, network)
                XCTAssertFalse(tokens.contains { $0.outcome == .unavailable }, network)
            }
        }
        if selected == nil || selected!.contains("near") {
            let uncreated = try await authority.check(.init(network: "near",
                address: "vault-public-fixture-nonexistent-20261020.near"))
            XCTAssertEqual(uncreated.coverage, .checked)
            XCTAssertTrue(uncreated.findings.isEmpty)
        }
    }
}

private actor ConcurrentCheckFixture: AnkrTransport {
    var active = 0, peak = 0, count = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        active += 1; peak = max(peak, active); count += 1
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(25))
        return (Data(#"{"jsonrpc":"2.0","id":1,"result":"0x1"}"#.utf8), 200)
    }
}

private actor NearNetworkFixture: AnkrTransport {
    let chain: String
    var methods: [String] = []
    init(chain: String) { self.chain = chain }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        methods.append(body["method"].string ?? "")
        return (try JSONEncoder().encode(SolanaJSON.object([
            "jsonrpc": .string("2.0"), "id": .number("1"),
            "result": .object(["chain_id": .string(chain)])
        ])), 200)
    }
}
