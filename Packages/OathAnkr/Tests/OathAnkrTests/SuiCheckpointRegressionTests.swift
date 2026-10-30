import Foundation
import XCTest
@testable import OathAnkr

final class SuiCheckpointRegressionTests: XCTestCase, @unchecked Sendable {
    func testLiveAdvertisedCheckpointCanBeReadWithoutLoweringIt() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_SUI_KEY"] else {
            throw XCTSkip("Opt-in public mainnet read; no signing or broadcast")
        }
        // Existing public fixture; never reads a user's vault or key material.
        let owner = "0x39ee291682e829771ad0c3ed46ebc69a962b7c2f9e6477409b22616bcf21ac34"
        let configured = try SuiClient(apiKey: key)
        let publicClient = SuiClient(publicProvider: true)
        let checkpoint = try await configured.checkpoint()
        let actual = try await configured.inventory(owner: owner, atCheckpoint: checkpoint)
        let expected = try await publicClient.inventory(owner: owner, atCheckpoint: checkpoint)
        XCTAssertEqual(actual.checkpoint, checkpoint)
        XCTAssertEqual(expected.checkpoint, checkpoint)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: actual.holdings.map { ($0.reference, $0.amount) }),
                       Dictionary(uniqueKeysWithValues: expected.holdings.map { ($0.reference, $0.amount) }))
        XCTAssertGreaterThan(actual.holdings.count, 1)
        print("SUI_ADVERTISED_CHECKPOINT verified=\(checkpoint) holdings=\(actual.holdings.count) lowered=false broadcast=false")

        // Exercise the reported provider envelope against the real fallback,
        // including pagination. A healthy-primary read alone cannot prove this.
        let lagging = LiveLaggingSuiTransport()
        let recovered = try await SuiClient(apiKey: key, transport: lagging)
            .inventory(owner: owner, atCheckpoint: checkpoint, pageSize: 5)
        XCTAssertEqual(recovered.checkpoint, checkpoint)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: recovered.holdings.map { ($0.reference, $0.amount) }),
                       Dictionary(uniqueKeysWithValues: expected.holdings.map { ($0.reference, $0.amount) }))
        let pages = await lagging.pages
        XCTAssertGreaterThanOrEqual(pages.count, 2)
        XCTAssertEqual(pages.first?.host, "rpc.ankr.com")
        XCTAssertEqual(pages[0].body, pages[1].body, "Live fallback must retain the complete pinned query")
        XCTAssertEqual(pages.filter { $0.host == "rpc.ankr.com" }.count, 1, "Later pages must not retry a known lagging checkpoint")
        XCTAssertTrue(pages.dropFirst().allSatisfy { $0.host == "graphql.mainnet.sui.io" })
        print("SUI_LAG_RECOVERY holdings=\(recovered.holdings.count) exactMatches=\(expected.holdings.count) pages=\(pages.count - 1) checkpointUnchanged=true primaryAttempts=1 broadcast=false")
    }
    func testKnownLaggingCheckpointUsesFallbackForLaterPages() async throws {
        let transport = PaginatedLaggingSuiTransport()
        let client = try SuiClient(apiKey: "fixture", transport: transport)
        let result = try await client.inventory(owner: SuiTests.owner, atCheckpoint: 333686877, pageSize: 1)
        XCTAssertEqual(result.checkpoint, 333686877)
        XCTAssertEqual(result.holdings.filter { $0.reference != "native" }.count, 3)
        let pages = await transport.pages
        XCTAssertEqual(pages.map(\.host), ["rpc.ankr.com", "graphql.mainnet.sui.io", "graphql.mainnet.sui.io", "graphql.mainnet.sui.io"])
        XCTAssertEqual(pages[0].body, pages[1].body)
        XCTAssertEqual(pages.suffix(2).map { $0.body["variables"]["after"].string }, ["1", "2"])
    }
    func testLaggingCheckpointDoesNotDisableNewCheckpointOrPrimaryRecovery() async throws {
        let transport = PaginatedLaggingSuiTransport()
        let client = try SuiClient(apiKey: "fixture", transport: transport)
        _ = try await client.inventory(owner: SuiTests.owner, atCheckpoint: 333686877, pageSize: 1)
        _ = try await client.inventory(owner: SuiTests.owner, atCheckpoint: 333686878, pageSize: 1)
        let newCheckpointPages = await transport.pages
        XCTAssertEqual(newCheckpointPages.suffix(4).map(\.host), ["rpc.ankr.com", "graphql.mainnet.sui.io", "graphql.mainnet.sui.io", "graphql.mainnet.sui.io"], "Lag at one checkpoint must not defer a different checkpoint")
        await transport.recoverPrimaryAndFailFallback()
        let recovered = try await client.inventory(owner: SuiTests.owner, atCheckpoint: 333686877, pageSize: 1)
        XCTAssertEqual(recovered.checkpoint, 333686877)
        var pages = await transport.pages
        XCTAssertEqual(pages.suffix(4).map(\.host), ["graphql.mainnet.sui.io", "rpc.ankr.com", "rpc.ankr.com", "rpc.ankr.com"])
        _ = try await client.inventory(owner: SuiTests.owner, atCheckpoint: 333686878, pageSize: 1)
        pages = await transport.pages
        XCTAssertEqual(pages.suffix(3).map(\.host), Array(repeating: "rpc.ankr.com", count: 3))
    }
    func testLaggingPrimaryFallsBackAtSameCheckpointAndCursor() async throws {
        let transport = LaggingSuiTransport(mode: .laggingPrimary)
        let value = try await SuiClient(apiKey: "fixture", transport: transport).inventory(owner: SuiTests.owner, pageSize: 1)
        XCTAssertEqual(value.checkpoint, 333686877)
        XCTAssertEqual(value.holdings.first { $0.reference == "native" }?.amount, "123")
        XCTAssertEqual(value.holdings.first { $0.reference == "0x3::fixture::TOKEN" }?.amount, "456")
        let calls = await transport.pages
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[1].body, calls[2].body, "Fallback must reuse the checkpoint, owner and page cursor")
        XCTAssertEqual(calls.map(\.host), ["rpc.ankr.com", "rpc.ankr.com", "graphql.mainnet.sui.io"])
        XCTAssertTrue(calls.allSatisfy { $0.body["variables"]["checkpoint"].integer == 333686877 })
    }
    func testBothProvidersLaggingFailWithoutInventingZeroOrLoweringCheckpoint() async throws {
        let transport = LaggingSuiTransport(mode: .bothLagging)
        do { _ = try await SuiClient(apiKey: "fixture", transport: transport).inventory(owner: SuiTests.owner); XCTFail() }
        catch { XCTAssertEqual(error as? SuiError, .checkpointUnavailable) }
        let calls = await transport.pages; XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.body["variables"]["checkpoint"].integer == 333686877 })
    }
    func testUnrelatedGraphQLErrorIsNotTreatedAsReplicaLag() async throws {
        let transport = LaggingSuiTransport(mode: .unrelated)
        do { _ = try await SuiClient(apiKey: "fixture", transport: transport).inventory(owner: SuiTests.owner); XCTFail() }
        catch { XCTAssertEqual(error as? SuiError, .graphql) }
        let calls = await transport.pages; XCTAssertEqual(calls.count, 1)
    }
    func testCancellationDoesNotSwitchProviders() async throws {
        let transport = LaggingSuiTransport(mode: .cancelled)
        do { _ = try await SuiClient(apiKey: "fixture", transport: transport).inventory(owner: SuiTests.owner); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await transport.pages; XCTAssertEqual(calls.count, 1)
    }
}

private actor PaginatedLaggingSuiTransport: AnkrTransport {
    struct Call: Sendable { let host: String; let body: SuiJSON }
    private(set) var pages: [Call] = []
    private var recovered = false
    func recoverPrimaryAndFailFallback() { recovered = true }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SuiJSON.self, from: request.httpBody!)
        guard body["query"].string?.contains("balances(first") == true else {
            return (try JSONEncoder().encode(SuiJSON.object(["data": .object(["chainIdentifier": .string(SuiIdentity.mainnet)])])), 200)
        }
        let host = request.url!.host!
        pages.append(.init(host: host, body: body))
        if recovered && host == "graphql.mainnet.sui.io" { throw URLError(.timedOut) }
        if !recovered && host == "rpc.ankr.com" {
            let checkpoint = try XCTUnwrap(body["variables"]["checkpoint"].integer)
            return (try JSONEncoder().encode(SuiJSON.object(["errors": .array([
                .object(["message": .string("Checkpoint \(checkpoint) in the future")])
            ])])), 200)
        }
        let page = Int(body["variables"]["after"].string ?? "0")!
        let value: SuiJSON = .object(["data": .object([
            "chainIdentifier": .string(SuiIdentity.mainnet),
            "address": .object(["address": .string(SuiTests.owner), "balances": .object([
                "nodes": .array([.object(["coinType": .object(["repr": .string("0x3::fixture::TOKEN\(page)")]),
                    "totalBalance": .string("456"), "coinBalance": .string("456"), "addressBalance": .string("0")])]),
                "pageInfo": .object(["hasNextPage": .bool(page < 2), "endCursor": page < 2 ? .string(String(page + 1)) : .null])
            ])])
        ])])
        return (try JSONEncoder().encode(value), 200)
    }
}

private actor LiveLaggingSuiTransport: AnkrTransport {
    struct Call: Sendable { let host: String; let body: Data }
    private let live = AnkrHTTPTransport()
    private(set) var pages: [Call] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SuiJSON.self, from: request.httpBody!)
        if body["query"].string?.contains("balances(first") == true {
            let host = request.url!.host!
            pages.append(.init(host: host, body: request.httpBody!))
            if host == "rpc.ankr.com" {
                let checkpoint = try XCTUnwrap(body["variables"]["checkpoint"].integer)
                return (try JSONEncoder().encode(SuiJSON.object(["errors": .array([
                    .object(["message": .string("Checkpoint \(checkpoint) in the future")])
                ])])), 200)
            }
        }
        return try await live.send(request)
    }
}

private actor LaggingSuiTransport: AnkrTransport {
    enum Mode { case laggingPrimary, bothLagging, unrelated, cancelled }
    struct Call: Sendable { let host: String; let body: SuiJSON }
    let mode: Mode
    private(set) var pages: [Call] = []
    init(mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SuiJSON.self, from: request.httpBody!)
        var value: [String: SuiJSON] = ["chainIdentifier": .string(SuiIdentity.mainnet)]
        if body["query"].string!.contains("balances(first") {
            pages.append(.init(host: request.url!.host!, body: body))
            if mode == .cancelled { throw CancellationError() }
            let first = body["variables"]["after"].isNull
            if mode == .bothLagging || mode == .unrelated || (!first && request.url!.host == "rpc.ankr.com") {
                let message = mode == .unrelated ? "Checkpoint 999 in the future" : "Checkpoint 333686877 in the future"
                return (try JSONEncoder().encode(SuiJSON.object(["errors": .array([.object(["message": .string(message)])])])), 200)
            }
            let row: SuiJSON = .object(["coinType": .object(["repr": .string(first ? SuiIdentity.coin : "0x3::fixture::TOKEN")]),
                                      "totalBalance": .string(first ? "123" : "456"), "coinBalance": .string(first ? "123" : "456"), "addressBalance": .string("0")])
            value["address"] = .object(["address": .string(SuiTests.owner), "balances": .object([
                "nodes": .array([row]), "pageInfo": .object(["hasNextPage": .bool(first), "endCursor": first ? .string("fixture-cursor") : .null])])])
        } else if body["query"].string!.contains("sequenceNumber") {
            value["checkpoint"] = .object(["sequenceNumber": .number("333686877")])
        }
        return (try JSONEncoder().encode(SuiJSON.object(["data": .object(value)])), 200)
    }
}
