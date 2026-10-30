import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor ThorchainReadTransport: AnkrTransport {
    private var replies: [(Data, Int)]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [(String, Int)]) { self.replies = replies.map { (Data($0.0.utf8), $0.1) } }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard !replies.isEmpty else { throw AnkrError.invalidResponse }
        return replies.removeFirst()
    }
}

private actor ThorchainCatalogTransport: AnkrTransport {
    let missingRuji: Bool
    private(set) var priceURLs: [URL] = []
    init(missingRuji: Bool = false) { self.missingRuji = missingRuji }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = try XCTUnwrap(request.url)
        let json: SolanaJSON
        if url.host == "api.coingecko.com" {
            priceURLs.append(url)
            json = .object(["rujira": .object(["usd": .number("2"), "last_updated_at": .number(String(Int(Date().timeIntervalSince1970)))])])
        } else if url.path.hasSuffix("denoms_metadata") {
            json = .object(["metadatas": .array([]), "pagination": .object([:])])
        } else if url.path.hasSuffix("/pools") || url.path.hasSuffix("/securedassets") {
            json = .array([])
        } else if url.path.hasSuffix("/stats") {
            json = .object(["runePriceUSD": .string("1")])
        } else if url.host == "api.rujira.network" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "query" })?.value ?? ""
            if query.contains("strategies") {
                json = .object(["data": .object(["rujira": .object(["strategies": .object(["edges": .array([]), "pageInfo": .object(["hasNextPage": .bool(false)])])])])])
            } else {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let start = query.range(of: "nodes(ids:")!.upperBound
                let end = query[start...].range(of: "){...")!.lowerBound
                let ids = try JSONDecoder().decode([String].self, from: Data(query[start..<end].utf8))
                let assets = ids.compactMap { Data(base64Encoded: $0).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst(6)) } }
                let rows = assets.map { asset -> SolanaJSON in
                    if asset == "X/RUJI" && missingRuji { return .null }
                    return .object(["asset": .string(asset), "price": .object(["current": .string("1000000000000"), "timestamp": .string(formatter.string(from: .now))])])
                }
                json = .object(["data": .object(["nodes": .array(rows)])])
            }
        } else { throw AnkrError.invalidResponse }
        return (try JSONEncoder().encode(json), 200)
    }
}

private actor ThorchainLiveReadTransport: AnkrTransport {
    private let base = AnkrHTTPTransport()
    private(set) var publicPriceRequests = 0
    private(set) var oracleReplies: [(Data, Int)] = []
    private(set) var oracleURLs: [URL] = []
    private(set) var graphQLReplies: [(Data, Int)] = []
    private(set) var injectedRejections = 0
    private var injectRateLimit: Bool
    private let blockCoinGecko: Bool
    init(injectRateLimit: Bool = false, blockCoinGecko: Bool = false) {
        self.injectRateLimit = injectRateLimit
        self.blockCoinGecko = blockCoinGecko
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.httpMethod == nil || request.httpMethod == "GET", request.httpBody == nil else { throw AnkrError.invalidResponse }
        if request.url?.host == "api.coingecko.com" {
            publicPriceRequests += 1
            if blockCoinGecko { return (Data(), 429) }
        }
        let url = try XCTUnwrap(request.url)
        let graphQL = url.host == "api.rujira.network"
        let oracle = graphQL &&
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "query" })?.value?.contains("nodes(ids:") == true
        let reply: (Data, Int)
        // Vault discovery and oracle quotes share a bucket. Either can be
        // first; inject at the first actual request, not an assumed schedule.
        if graphQL && injectRateLimit {
            injectRateLimit = false
            injectedRejections += 1
            let errors = Array(repeating: ["message": "rate bucket full (5000). bucket drains 500/s."], count: 9)
            let data = try JSONSerialization.data(withJSONObject: ["errors": errors])
            DiagnosticHTTP.response(data, status: 200, request: request)
            reply = (data, 200)
        } else { reply = try await base.send(request) }
        if graphQL { graphQLReplies.append(reply) }
        if oracle {
            oracleReplies.append(reply)
            oracleURLs.append(url)
        }
        return reply
    }
}

private actor ThorchainLaggedLiveHeightTransport: AnkrTransport {
    let baseline: Int64
    private var injected = false
    private let live = AnkrHTTPTransport()
    private(set) var liveReads = 0
    init(baseline: Int64) { self.baseline = baseline }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.httpBody == nil, request.url?.host == ThorchainClient.node.host,
              request.url?.path.hasSuffix("/blocks/latest") == true else { throw ThorchainError.malformed }
        if !injected {
            injected = true
            return (Data("{\"block\":{\"header\":{\"chain_id\":\"thorchain-1\",\"height\":\"\(baseline - 1)\"}}}".utf8), 200)
        }
        liveReads += 1
        return try await live.send(request)
    }
}

private actor ThorchainLaggedLiveInventoryTransport: AnkrTransport {
    private let live = AnkrHTTPTransport()
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.httpMethod == "GET", request.httpBody == nil,
              request.url?.host == ThorchainClient.node.host,
              request.url?.path.contains("/balances/") == true,
              request.value(forHTTPHeaderField: "x-cosmos-block-height") != nil else {
            throw AnkrError.invalidResponse
        }
        requests.append(request)
        if requests.count <= 2 {
            let data = Data(#"{"code":2,"message":"cannot query with height in the future; please provide a valid height: invalid height"}"#.utf8)
            DiagnosticHTTP.response(data, status: 500, request: request)
            return (data, 500)
        }
        return try await live.send(request)
    }
}

final class ThorchainReadRegressionTests: XCTestCase, @unchecked Sendable {
    private let future = #"{"code":2,"message":"cannot query with height in the future; please provide a valid height: invalid height"}"#
    private let balances = #"{"balances":[{"denom":"rune","amount":"123"}],"pagination":{"next_key":null}}"#
    private let owner = "thor1dheycdevq39qlkxs2a6wuuzyn4aqxhve4qxtxt" // Public protocol reserve, not a user's account.

    func testPublicMarketHeadersUseSharedRateLimiter() async throws {
        let transport = ThorchainReadTransport([("{}", 200)])
        _ = try await ThorchainClient(transport: transport).read(URL(string: "https://api.coingecko.com")!, path: "api/v3/simple/price")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-client-id"))
        XCTAssertTrue(PublicMarketRequests.accepts(request))
    }

    func testPublicMarketRateLimitDoesNotTriggerImmediateRetry() async throws {
        let transport = ThorchainReadTransport([("{}", 429), ("{}", 429)])
        do {
            _ = try await ThorchainClient(transport: transport).read(URL(string: "https://api.coingecko.com")!, path: "api/v3/simple/price")
            XCTFail("Rate limit should be returned to the existing fallback")
        } catch { XCTAssertEqual(error as? ThorchainError, .http(429)) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testAvailableOraclePricesDoNotSpendCoinGeckoQuota() async throws {
        let transport = ThorchainCatalogTransport()
        let catalog = try await ThorchainClient(transport: transport).catalog()
        XCTAssertEqual(catalog.prices["native"], "1")
        XCTAssertEqual(catalog.prices["x/ruji"], "1")
        let requests = await transport.priceURLs
        XCTAssertTrue(requests.isEmpty, "Authoritative market prices are already available")
    }

    func testCoinGeckoFallbackRequestsOnlyMissingExactIdentities() async throws {
        let transport = ThorchainCatalogTransport(missingRuji: true)
        let catalog = try await ThorchainClient(transport: transport).catalog()
        XCTAssertEqual(catalog.prices["native"], "1")
        XCTAssertEqual(catalog.prices["x/ruji"], "2")
        let requests = await transport.priceURLs
        XCTAssertEqual(requests.count, 1)
        let url = try XCTUnwrap(requests.first)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ids" })?.value, "rujira")
    }

    func testHeightUsesBalanceAPIAndValidatesNetwork() async throws {
        let transport = ThorchainReadTransport([(#"{"block":{"header":{"chain_id":"thorchain-1","height":"123"}}}"#, 200)])
        let height = try await ThorchainClient(transport: transport).latestHeight()
        XCTAssertEqual(height, 123)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/chain/thorchain_api/cosmos/base/tendermint/v1beta1/blocks/latest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-client-id"), "oath-wallet")
        let wrong = ThorchainReadTransport([(#"{"block":{"header":{"chain_id":"stagenet","height":"123"}}}"#, 200)])
        do { _ = try await ThorchainClient(transport: wrong).latestHeight(); XCTFail("Wrong chain accepted") }
        catch { XCTAssertEqual(error as? ThorchainError, .malformed) }
    }

    func testHeightFloorRetriesKnownLagButNeverInventsAHeight() async throws {
        func reply(_ height: Int64, chain: String = "thorchain-1") -> (String, Int) {
            ("{\"block\":{\"header\":{\"chain_id\":\"\(chain)\",\"height\":\"\(height)\"}}}", 200)
        }
        let transport = ThorchainReadTransport([reply(198), reply(199), reply(200)])
        let height = try await ThorchainClient(transport: transport).latestHeight(atLeast: 200)
        XCTAssertEqual(height, 200)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.compactMap(\.url)).count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.httpBody == nil && $0.value(forHTTPHeaderField: "x-cosmos-block-height") == nil })

        let wrong = ThorchainReadTransport([reply(199, chain: "stagenet"), reply(201)])
        do { _ = try await ThorchainClient(transport: wrong).latestHeight(atLeast: 200); XCTFail("Wrong chain retried") }
        catch { XCTAssertEqual(error as? ThorchainError, .malformed) }
        let wrongCount = await wrong.requests.count
        XCTAssertEqual(wrongCount, 1)

        let invalid = ThorchainReadTransport([reply(200)])
        do { _ = try await ThorchainClient(transport: invalid).latestHeight(atLeast: 0); XCTFail("Invalid floor accepted") }
        catch { XCTAssertEqual(error as? ThorchainError, .malformed) }
        let invalidCount = await invalid.requests.count
        XCTAssertEqual(invalidCount, 0)
    }

    func testLiveHeightRecoveryAfterInjectedLag() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_HEIGHT_LIVE"] == "1" else {
            throw XCTSkip("Public block-height reads only; first lag response is injected")
        }
        let baseline = try await ThorchainClient().latestHeight()
        let transport = ThorchainLaggedLiveHeightTransport(baseline: baseline)
        let recovered = try await ThorchainClient(transport: transport).latestHeight(atLeast: baseline)
        XCTAssertGreaterThanOrEqual(recovered, baseline)
        let liveReads = await transport.liveReads
        XCTAssertTrue((1...2).contains(liveReads))
    }

    func testFutureHeightRetryPreservesExactSnapshotAndPagination() async throws {
        let transport = ThorchainReadTransport([(future, 500), (balances, 200)])
        let value = try await ThorchainClient(transport: transport).inventory(owner: owner, height: 123)
        XCTAssertEqual(value.height, 123)
        XCTAssertEqual(value.holdings.first?.amount, "123")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url, requests.last?.url)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-cosmos-block-height") == "123" })
    }

    func testPersistentFutureHeightStaysBoundedAndCannotBecomeEmptySuccess() async throws {
        let transport = ThorchainReadTransport(Array(repeating: (future, 500), count: 5))
        do { _ = try await ThorchainClient(transport: transport).inventory(owner: owner, height: 123); XCTFail("Invented balance") }
        catch { XCTAssertEqual(error as? ThorchainError, .http(500)) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 3)
    }

    func testUnrelatedServerErrorsAreNotClassifiedAsHeightLag() async throws {
        for response in [#"{"code":2,"message":"database unavailable"}"#, #"{"code":7,"message":"cannot query with height in the future; please provide a valid height: invalid height"}"#] {
            let transport = ThorchainReadTransport([(response, 500)])
            do { _ = try await ThorchainClient(transport: transport).inventory(owner: owner, height: 123); XCTFail() }
            catch { XCTAssertEqual(error as? ThorchainError, .http(500)) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testCancellationStopsPinnedHeightRecovery() async throws {
        let transport = ThorchainReadTransport([(future, 500), (balances, 200)])
        let owner = owner
        let task = Task { try await ThorchainClient(transport: transport).inventory(owner: owner, height: 123) }
        for _ in 0..<100 {
            if await transport.requests.count > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testLivePinnedInventoryThroughProductionClient() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_READ_LIVE"] == "1" else { throw XCTSkip("Opt-in read-only public protocol account") }
        let client = ThorchainClient()
        for _ in 0..<3 {
            let height = try await client.latestHeight()
            let inventory = try await client.inventory(owner: owner, height: height)
            XCTAssertEqual(inventory.height, height)
            XCTAssertTrue(inventory.holdings.contains { $0.reference == "native" })
        }
        print("Live THORChain API height and pinned public inventory: 3 successful cycles, no signing or broadcast.")
    }

    func testLivePinnedInventoryRecoversReportedFutureHeightEnvelope() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_READ_LIVE"] == "1" else {
            throw XCTSkip("Public protocol reserve only; two replica-lag responses are injected")
        }
        let client = ThorchainClient()
        let height = try await client.latestHeight()
        let expected = try await client.inventory(owner: owner, height: height)
        let transport = ThorchainLaggedLiveInventoryTransport()
        let recovered = try await ThorchainClient(transport: transport).inventory(owner: owner, height: height)
        XCTAssertEqual(recovered.height, height)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: recovered.holdings.map { ($0.reference, $0.amount) }),
                       Dictionary(uniqueKeysWithValues: expected.holdings.map { ($0.reference, $0.amount) }))
        let requests = await transport.requests
        XCTAssertGreaterThanOrEqual(requests.count, 3)
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(requests[1], requests[2], "Recovery must retain the exact height and page")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-cosmos-block-height") == String(height) })
        print("Live THORChain replica-lag recovery: two injected HTTP 500 envelopes; \(recovered.holdings.count) holdings matched the same pinned block \(height).")
    }

    func testLiveCatalogHasNativeAndEcosystemPricesWithoutCoinGecko() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_READ_LIVE"] == "1" else { throw XCTSkip("Opt-in public market API reads") }
        let transport = ThorchainLiveReadTransport(blockCoinGecko: true)
        let catalog = try await ThorchainClient(transport: transport).catalog()
        for reference in ["native", "tcy", "x/ruji"] {
            let price = try XCTUnwrap(catalog.prices[reference].flatMap { Decimal(string: $0) })
            XCTAssertGreaterThan(price, 0)
        }
        let count = await transport.publicPriceRequests
        for (data, status) in await transport.oracleReplies {
            let reply = try JSONDecoder().decode(SolanaJSON.self, from: data)
            let rows = reply["data"]["nodes"].array ?? []
            let errors = reply["errors"].array ?? []
            print("Live public oracle: HTTP \(status), \(rows.count) nodes, \(errors.count) GraphQL errors.")
            for error in errors {
                let message = error["message"].string ?? "missing message"
                print("Public oracle error: \(DiagnosticPrivacy.text(message))")
            }
            let prices = try ThorchainClient.decodeOracle(rows, expected: Set(rows.compactMap { $0["asset"].string }))
            let native = prices["THOR.RUNE"] != nil, tcy = prices["THOR.TCY"] != nil, ruji = prices["X/RUJI"] != nil
            print("Live oracle usable prices: \(prices.count); RUNE=\(native), TCY=\(tcy), RUJI=\(ruji).")
        }
        XCTAssertLessThanOrEqual(count, 1, "Only one batched fallback attempt is permitted")
        print("Live THORChain catalog: \(count) blocked CoinGecko requests; native, TCY and RUJI recovered independently.")
    }

    func testLiveCatalogRecoversFromInjectedRateLimitWithoutRetryingBlockedProvider() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_READ_LIVE"] == "1" else { throw XCTSkip("Opt-in read-only public market recovery") }
        let transport = ThorchainLiveReadTransport(injectRateLimit: true)
        let shared = ThorchainCatalogRequests()
        let first = ThorchainClient(transport: transport, catalogRequests: shared)
        let second = ThorchainClient(transport: transport, catalogRequests: shared)
        async let a = first.catalog()
        async let b = second.catalog()
        for catalog in try await [a, b] {
            for ref in ["native", "tcy", "x/ruji"] {
                let price = try XCTUnwrap(catalog.prices[ref].flatMap { Decimal(string: $0) })
                XCTAssertGreaterThan(price, 0)
            }
        }
        _ = try await first.catalog()
        let replies = await transport.graphQLReplies
        XCTAssertEqual(replies.count, 1, "The shared bucket must not be retried by either consumer")
        let injected = await transport.injectedRejections
        XCTAssertEqual(injected, 1, "The test must actually exercise the provider rejection")
        let rejected = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(replies.first).0)
        XCTAssertTrue(ThorchainClient.isMarketRateLimit(rejected))
        XCTAssertEqual(rejected["errors"].array?.count, 9)
        let fallbackRequests = await transport.publicPriceRequests
        XCTAssertEqual(fallbackRequests, 1)
        print("Public recovery evidence: one injected nine-error GraphQL rejection; independent quotes recovered both consumers and cached reread. No signing or broadcast.")
    }
}
