import Foundation
import XCTest
@testable import OathAnkr

final class PolkadotTests: XCTestCase, @unchecked Sendable {
    let owner = "13vg3Mrxm3GL9eXxLsGgLYRueiwFCiMbkdHBL4ZN5aob5D4N"
    func testSS58ChecksumAndNetwork() throws {
        let publicKey = try PolkadotIdentity.publicKey(owner)
        XCTAssertEqual(try PolkadotIdentity.address(publicKey: publicKey), owner)
        XCTAssertEqual(try PolkadotIdentity.publicKey("111111111111111111111111111111111HC1"), Data(repeating: 0, count: 32))
        let generic = Data([42]) + publicKey
        let genericAddress = SuiSendCrypto.base58(generic + SuiSendCrypto.hash(Data("SS58PRE".utf8) + generic, length: 64).prefix(2))
        XCTAssertEqual(try PolkadotIdentity.address(genericAddress), owner)
        XCTAssertThrowsError(try PolkadotIdentity.address(String(owner.dropLast()) + "1"))
        let kusama = Data([2]) + publicKey
        XCTAssertThrowsError(try PolkadotIdentity.address(SuiSendCrypto.base58(kusama + SuiSendCrypto.hash(Data("SS58PRE".utf8) + kusama, length: 64).prefix(2))))
        XCTAssertThrowsError(try PolkadotIdentity.address("0x" + String(repeating: "ab", count: 20)))
    }
    func testBlakeAndUnsigned128Exact() throws {
        XCTAssertEqual(PolkadotIdentity.hex(SuiSendCrypto.hash(Data(), length: 64)), "0x786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
        XCTAssertEqual(PolkadotIdentity.uint(Data(repeating: 255, count: 16)), "340282366920938463463374607431768211455")
        var account = Data(repeating: 0, count: 80); account[16] = 10; account[32] = 7
        XCTAssertEqual(try PolkadotStorage.native(.string(PolkadotIdentity.hex(account))), "17")
        XCTAssertEqual(try PolkadotStorage.native(.null), "0")
        XCTAssertThrowsError(try PolkadotStorage.native(.string("0x010203")))
    }
    func testCurrentRuntimeMetadataVectors() throws {
        let url = Bundle.module.url(forResource: "PolkadotStorage", withExtension: "json", subdirectory: "Fixtures")!
        let fixture = try JSONDecoder().decode(SolanaJSON.self, from: Data(contentsOf: url))
        for pallet in ["Assets", "ForeignAssets"] {
            for row in fixture[pallet].array! {
                let token = try PolkadotStorage.token(key: row["key"].string!, value: row["value"], pallet: pallet)
                XCTAssertEqual(token.decimals, Int(row["metadata"]["decimals"].text!))
                XCTAssertTrue(try PolkadotStorage.accountKey(token, owner: owner).hasPrefix("0x" + PolkadotStorage.pallets[pallet]! + PolkadotStorage.account))
                if token.reference == "assets:1984" { XCTAssertEqual(token.symbol, "USDt"); XCTAssertEqual(token.coinGeckoID, "tether") }
                if pallet == "ForeignAssets" { XCTAssertEqual(token.reference.count, 74) }
                XCTAssertThrowsError(try PolkadotStorage.token(key: row["key"].string!, value: .string("0x00"), pallet: pallet))
                let holding = try PolkadotStorage.holding(.string("0x" + String(repeating: "ff", count: 16) + "0100"), token: token)
                XCTAssertEqual(holding?.amount, "340282366920938463463374607431768211455"); XCTAssertEqual(holding?.frozen, true)
            }
        }
    }
    func testReferencesRemainSpecificToPalletAndNetwork() throws {
        XCTAssertEqual(try TokenDiscoveryNetworks.canonical("1337", network: "polkadot"), "assets:1337")
        XCTAssertEqual(try PolkadotIdentity.reference("pool:1337"), "pool:1337")
        for invalid in ["001337", "assets:-1", "assets:4294967296", "pool:1/2", "foreign:0x1234", "0x0000000000000000000000000000000000001337"] {
            XCTAssertThrowsError(try PolkadotIdentity.reference(invalid))
        }
    }
    func testBundledDiscoveryIncludesAssetHubStablecoins() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = TokenDiscoveryCatalog(directory: folder)
        let results = await catalog.search("us", networks: ["polkadot"])
        XCTAssertTrue(results.contains { $0.reference == "assets:1337" && $0.decimals == 6 })
        XCTAssertTrue(results.contains { $0.reference == "assets:1984" && $0.decimals == 6 })
    }
    func testExactPriceIdentityAndPartialFallback() async throws {
        let transport = DotMock { request in
            let host = request.url!.host!, path = request.url!.path
            if path.hasSuffix("/list") { return (Data(#"[{"id":"usd-coin","platforms":{"polkadot":"1337"}}]"#.utf8), 200) }
            if path.hasSuffix("/price") { return (Data(#"{"polkadot":{"usd":5.25}}"#.utf8), 200) }
            XCTAssertEqual(host, "coins.llama.fi")
            return (Data(), 403)
        }
        let client = try PolkadotClient(transport: transport)
        let usdc = PolkadotToken(reference: "assets:1337", name: "USD Coin", symbol: "USDC", decimals: 6, pallet: "Assets", key: Data())
        let fake = PolkadotToken(reference: "assets:9999999", name: "USD Coin", symbol: "USDC", decimals: 6, pallet: "Assets", key: Data())
        let result = try await client.prices(for: [.native, usdc, fake])
        XCTAssertEqual(result.map(\.reference), ["native"])
        XCTAssertEqual(result.first?.usd, "5.25")
        let fallback = DotMock { request in
            if request.url!.path.hasSuffix("/list") { return (Data(#"[{"id":"polkadot","platforms":{}}]"#.utf8), 200) }
            if request.url!.host == "coins.llama.fi" { return (Data(#"{"coins":{"coingecko:polkadot":{"price":5.5}}}"#.utf8), 200) }
            return (Data(), 403)
        }
        let prices = try await PolkadotClient(transport: fallback).prices(for: [.native])
        XCTAssertEqual(prices.first?.usd, "5.5")
    }
    func testRejectsRelayAndFallsBackToCorrectGenesis() async throws {
        let transport = DotMock { request in
            let body = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
            let result: SolanaJSON = body["method"].string == "chain_getBlockHash" ? .string(request.url!.host == "relay.test" ? PolkadotIdentity.relayGenesis : PolkadotIdentity.genesis) : .string("ok")
            return (try JSONEncoder().encode(SolanaJSON.object(["id": .number("1"), "result": result])), 200)
        }
        let client = try PolkadotClient(endpoints: [URL(string: "https://relay.test")!, URL(string: "https://hub.test")!], transport: transport)
        let result = try await client.rpc("system_chain", []); XCTAssertEqual(result.string, "ok")
        let counts = await transport.counts(); XCTAssertEqual(counts["relay.test:system_chain"], nil)
    }
    func testStorageBatchesAreCompleteAndPinned() async throws {
        let pin = "0x" + String(repeating: "ab", count: 32)
        let transport = DotMock { request in
            let body = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
            if body["method"].string == "chain_getBlockHash" { return (try JSONEncoder().encode(SolanaJSON.object(["id": .number("1"), "result": .string(PolkadotIdentity.genesis)])), 200) }
            let params = body["params"].array!, keys = params[0].array!
            XCTAssertLessThanOrEqual(keys.count, 100); XCTAssertEqual(params[1].string, pin)
            return (try JSONEncoder().encode(SolanaJSON.object(["id": .number("1"), "result": .array([.object(["block": .string(pin), "changes": .array(keys.reversed().map { .array([$0, .null]) })])])])), 200)
        }
        let client = try PolkadotClient(endpoints: [URL(string: "https://hub.test")!], transport: transport)
        let values = try await client.storage((0..<301).map { "key\($0)" }, at: pin)
        XCTAssertEqual(values.count, 301)
        let counts = await transport.counts(); XCTAssertEqual(counts["hub.test:state_queryStorageAt"], 4)
        let corrupt = DotMock { request in
            let body = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
            let result: SolanaJSON = body["method"].string == "chain_getBlockHash" ? .string(PolkadotIdentity.genesis) : .array([.object(["block": .string(pin), "changes": .array([])])])
            return (try JSONEncoder().encode(SolanaJSON.object(["id": .number("1"), "result": result])), 200)
        }
        do { _ = try await PolkadotClient(endpoints: [URL(string: "https://hub.test")!], transport: corrupt).storage(["key"], at: pin); XCTFail() }
        catch { XCTAssertEqual(error as? PolkadotError, .incompleteInventory) }
    }
    func testLiveInventoryHistoryAndPrices() async throws {
        guard ProcessInfo.processInfo.environment["OATH_POLKADOT_LIVE"] == "1" else { throw XCTSkip("Opt-in public network validation") }
        let client = try PolkadotClient()
        let inventory = try await client.inventory(owner: owner)
        XCTAssertGreaterThan(inventory.holdings.count, 2)
        XCTAssertNotEqual(inventory.holdings.first?.amount, "0")
        let metadata = try await client.currentMetadata(reference: "1337")
        XCTAssertEqual(metadata.reference, "assets:1337"); XCTAssertEqual(metadata.decimals, 6)
        async let native = client.history(owner: owner, stream: "native", page: 0, finalizedHeight: inventory.height)
        async let assets = client.history(owner: owner, stream: "assets", page: 0, finalizedHeight: inventory.height)
        async let foreign = client.history(owner: owner, stream: "foreign", page: 0, finalizedHeight: inventory.height)
        async let extrinsics = client.history(owner: owner, stream: "extrinsics", page: 0, finalizedHeight: inventory.height)
        async let prices = client.prices(for: inventory.holdings.map(\.token))
        let history = try await [native, assets, foreign, extrinsics], quotes = try await prices
        XCTAssertFalse(history[0].events.isEmpty); XCTAssertFalse(history[1].events.isEmpty)
        XCTAssertTrue(quotes.contains { $0.reference == "native" })
        let report = DotLiveReport(inventory: inventory, eventCounts: history.map { $0.events.count }, prices: quotes)
        try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: "/tmp/oath-dot-swift-live.json"))
    }
    func testLiveLargePortfolioAndFallback() async throws {
        guard ProcessInfo.processInfo.environment["OATH_POLKADOT_LIVE"] == "1" else { throw XCTSkip("Opt-in public network validation") }
        let owner = "13cKp89Uh2yWgTG28JA1QEvPUMjEPKejqkjHKf9zqLiFKjH6"
        let client = try PolkadotClient()
        let started = Date(), inventory = try await client.inventory(owner: owner)
        XCTAssertGreaterThan(inventory.holdings.count, 300)
        XCTAssertGreaterThan(inventory.holdings.filter { $0.token.pallet == "ForeignAssets" }.count, 10)
        let elapsed = Date().timeIntervalSince(started)
        async let assets = client.history(owner: owner, stream: "assets", page: 1, finalizedHeight: inventory.height)
        async let foreign = client.history(owner: owner, stream: "foreign", page: 0, finalizedHeight: inventory.height)
        async let prices = client.prices(for: inventory.holdings.map(\.token))
        let (a, f, p) = try await (assets, foreign, prices)
        XCTAssertFalse(a.events.isEmpty); XCTAssertFalse(f.events.isEmpty)
        XCTAssertTrue(p.contains { $0.reference == "assets:1337" })
        try JSONEncoder().encode(DotLiveReport(inventory: inventory, eventCounts: [a.events.count, f.events.count], prices: p)).write(to: URL(fileURLWithPath: "/tmp/oath-dot-swift-large.json"))
        let fallback = try PolkadotClient(endpoints: [URL(string: "https://asset-hub.selvagelabs.io")!])
        let key = try PolkadotStorage.nativeKey(owner)
        let value = try await fallback.storage([key], at: inventory.blockHash)
        XCTAssertEqual(try PolkadotStorage.native(value[key]!), inventory.holdings.first!.amount)
        print("Polkadot finalized portfolio read: \(inventory.holdings.count) assets in \(String(format: "%.2f", elapsed)) seconds; independent RPC balance matched.")
    }
    func testLiveAnkrRelayHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_POLKADOT_LIVE"] == "1" else { throw XCTSkip("Opt-in public network validation") }
        let owner = "14QKFrBmnhP5xoH1t7nC2q7mssgj671AhzThsGewVj3Ea8Xt"
        let client = try PolkadotClient(ankrAPIKey: ProcessInfo.processInfo.environment["OATH_POLKADOT_ANKR_KEY"])
        let height = try await client.relayFinalizedHeight()
        async let native = client.history(owner: owner, stream: "relay-native", page: 0, finalizedHeight: height)
        async let extrinsics = client.history(owner: owner, stream: "relay-extrinsics", page: 0, finalizedHeight: height)
        let (transfers, calls) = try await (native, extrinsics)
        XCTAssertFalse(transfers.events.isEmpty)
        XCTAssertTrue(transfers.events.allSatisfy { $0.transaction.hasPrefix("relay:") && $0.height <= height })
        XCTAssertTrue(calls.events.allSatisfy { $0.id.hasPrefix("extrinsic:relay:") })
    }
}
private struct DotLiveReport: Codable { let inventory: PolkadotInventory; let eventCounts: [Int]; let prices: [PolkadotPrice] }
private actor DotMock: AnkrTransport {
    private let handler: @Sendable (URLRequest) throws -> (Data, Int)
    private var calls: [String: Int] = [:]
    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) { self.handler = handler }
    func counts() -> [String: Int] { calls }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try request.httpBody.map { try JSONDecoder().decode(SolanaJSON.self, from: $0) } ?? .null
        calls[(request.url!.host ?? "") + ":" + (body["method"].string ?? ""), default: 0] += 1
        return try handler(request)
    }
}
