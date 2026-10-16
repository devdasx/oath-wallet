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
