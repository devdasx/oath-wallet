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
        } else if url.path.hasSuffix("/network") {
            json = .object(["runePriceInUSD": .string("1")])
        } else if url.host == "api.rujira.network" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "query" })?.value ?? ""
            if query.contains("strategies") {
                json = .object(["data": .object(["rujira": .object(["strategies": .object(["edges": .array([]), "pageInfo": .object(["hasNextPage": .bool(false)])])])])])
            } else {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let rows = ["THOR.RUNE", "THOR.TCY", "X/RUJI"].map { asset -> SolanaJSON in
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
    private var injectRateLimit: Bool
    init(injectRateLimit: Bool = false) { self.injectRateLimit = injectRateLimit }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.httpMethod == nil || request.httpMethod == "GET", request.httpBody == nil else { throw AnkrError.invalidResponse }
        if request.url?.host == "api.coingecko.com" { publicPriceRequests += 1 }
        let url = try XCTUnwrap(request.url)
        let oracle = url.host == "api.rujira.network" &&
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "query" })?.value?.contains("nodes(ids:") == true
        let reply: (Data, Int)
        if oracle && injectRateLimit {
            injectRateLimit = false
            let data = Data(#"{"errors":[{"message":"rate bucket full (5000). bucket drains 500/s."}]}"#.utf8)
            DiagnosticHTTP.response(data, status: 200, request: request)
            reply = (data, 200)
        } else { reply = try await base.send(request) }
        if oracle {
            oracleReplies.append(reply)
            oracleURLs.append(url)
        }
        return reply
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

    func testLiveCatalogHasNativeAndEcosystemPricesWithoutCoinGecko() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THORCHAIN_READ_LIVE"] == "1" else { throw XCTSkip("Opt-in public market API reads") }
        let transport = ThorchainLiveReadTransport()
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
        XCTAssertEqual(count, 0)
        print("Live THORChain catalog: \(count) CoinGecko requests.")
    }

    func testLiveCatalogRecoversFromInjectedRateLimitWithOneRealRetry() async throws {
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
        let replies = await transport.oracleReplies
        XCTAssertEqual(replies.count, 2, "One injected rejection, then one live request for both consumers")
        let accepted = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(replies.last).0)
        XCTAssertFalse(ThorchainClient.isMarketRateLimit(accepted))
        XCTAssertFalse(try XCTUnwrap(accepted["data"]["nodes"].array).isEmpty)
        let urls = await transport.oracleURLs
        XCTAssertEqual(urls.first, urls.last)
        let fallbackRequests = await transport.publicPriceRequests
        XCTAssertEqual(fallbackRequests, 0)
        print("Public recovery evidence: \(replies.count) oracle attempts, \(fallbackRequests) CoinGecko requests; first rejection injected, final response live. No signing or broadcast.")
    }
}
