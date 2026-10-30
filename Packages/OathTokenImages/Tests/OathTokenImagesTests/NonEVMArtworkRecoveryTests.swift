import XCTest
import OathArtworkSource
@testable import OathTokenImages

private struct EmptyNonEVMMetadata: TokenArtworkMetadata {
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] { [] }
}
private actor NonEVMArtworkFeed: ArtworkTransport {
    let live: Bool
    let lists: [String: Data]
    private(set) var calls: [String: Int] = [:]
    init(live: Bool, lists: [String: Data]) { self.live = live; self.lists = lists }
    func data(from url: URL) async throws -> Data {
        calls[url.absoluteString, default: 0] += 1
        if live { return try await ArtworkURLTransport().data(from: url) }
        if let data = lists[url.absoluteString] { return data }
        if url.host == "cdn.example.org" {
            return Data("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect width='16' height='16'/></svg>".utf8)
        }
        throw ArtworkError.http(404)
    }
}
final class NonEVMArtworkRecoveryTests: XCTestCase, @unchecked Sendable {
    private struct Sample: Decodable { let network: String; let reference: String; let sourceHash: String }
    private func samples() throws -> [Sample] {
        try JSONDecoder().decode([Sample].self, from: Data(contentsOf:
            Bundle.module.url(forResource: "non-evm-reported-artwork", withExtension: "json", subdirectory: "Fixtures")!))
    }
    private func guess(_ network: String, _ reference: String) -> String {
        "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/\(network)/assets/\(reference)/logo.png"
    }
    private func listURL(_ network: String) -> String {
        "https://tokens.coingecko.com/\(["near": "near-protocol", "ton": "the-open-network"][network] ?? network)/all.json"
    }
    private func list(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tokens": rows])
    }
    func testCatalogsRequireExactNetworkAndPublicReference() throws {
        for sample in try samples() {
            let id = ArtworkFallbackCatalog.identity(guess(sample.network, sample.reference))
            XCTAssertEqual(id?.networkID, sample.network)
            XCTAssertEqual(id?.contract, sample.reference)
            XCTAssertEqual(String(ArtworkSource.key(guess(sample.network, sample.reference)).prefix(12)), sample.sourceHash)
            let data = try list([["chainId": NSNull(), "address": sample.reference, "logoURI": "https://cdn.example.org/image.png"],
                                 ["chainId": 1, "address": sample.reference, "logoURI": "https://cdn.example.org/wrong.png"]])
            let decoded = try ArtworkFallbackCatalog.decode(data, chainID: nil, networkID: sample.network)
            XCTAssertEqual(decoded, [sample.reference: "https://cdn.example.org/image.png"])
            XCTAssertTrue(try ArtworkFallbackCatalog.decode(data, chainID: nil, networkID: "unsupported").isEmpty)
            let conflicting = try list([["chainId": NSNull(), "address": sample.reference, "logoURI": "https://cdn.example.org/a.png"],
                                        ["chainId": NSNull(), "address": sample.reference, "logoURI": "https://cdn.example.org/b.png"]])
            XCTAssertThrowsError(try ArtworkFallbackCatalog.decode(conflicting, chainID: nil, networkID: sample.network))
        }
        for pair in [("near", "wallet..near"), ("near", "Wallet.near"), ("stellar", "USDC"), ("tron", "symbol"),
                     ("sui", "0x2::coin::Coin<0x2::sui::SUI>")] {
            XCTAssertNil(ArtworkFallbackCatalog.identity(guess(pair.0, pair.1)))
        }
        let sui = ArtworkFallbackCatalog.identity(guess("sui", "0x2::sui::SUI"))
        XCTAssertEqual(sui?.contract, "0x" + String(repeating: "0", count: 63) + "2::sui::SUI")
        XCTAssertNotEqual(sui?.contract, ArtworkFallbackCatalog.identity(guess("sui", "0x2::sui::sui"))?.contract)
    }
    func testReportedImagesResolveAndSurviveOfflineRelaunch() async throws { try await verify(live: false) }
    func testLiveReportedImagesResolveAndSurviveOfflineRelaunch() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_NON_EVM_ARTWORK"] == "1" else {
            throw XCTSkip("Opt-in public images only; no wallet or credentials")
        }
        try await verify(live: true)
    }
    private func verify(live: Bool) async throws {
        let samples = try samples()
        var lists: [String: Data] = [:]
        for sample in samples {
            lists[listURL(sample.network)] = try list([["chainId": NSNull(), "address": sample.reference,
                "logoURI": "https://cdn.example.org/\(sample.network).svg"]])
        }
        let feed = NonEVMArtworkFeed(live: live, lists: lists)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let images = folder.appendingPathComponent("images"), identities = folder.appendingPathComponent("identities")
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: images, transport: feed,
            fallbackCatalog: ArtworkFallbackCatalog(transport: feed)), metadata: EmptyNonEVMMetadata(), directory: identities)
        for sample in samples {
            let token = TokenArtworkIdentity(networkID: sample.network, reference: sample.reference)!
            let image = await resolver.image(for: token, sources: [guess(sample.network, sample.reference)])
            XCTAssertNotNil(image, sample.network)
        }
        let calls = await feed.calls
        for sample in samples {
            XCTAssertEqual(calls[listURL(sample.network)], 1)
            XCTAssertNil(calls[guess(sample.network, sample.reference)])
        }
        let offline = NonEVMArtworkFeed(live: false, lists: [:])
        let restored = TokenArtworkResolver(loader: ArtworkLoader(directory: images, transport: offline,
            fallbackCatalog: ArtworkFallbackCatalog(transport: offline)), metadata: EmptyNonEVMMetadata(), directory: identities)
        for sample in samples {
            let image = await restored.image(for: TokenArtworkIdentity(networkID: sample.network, reference: sample.reference)!, sources: [])
            XCTAssertNotNil(image, sample.network)
        }
        let offlineCalls = await offline.calls; XCTAssertTrue(offlineCalls.isEmpty)
        if live { print("NON_EVM_ARTWORK_RECOVERY networks=near,stellar,sui,tron,ton decoded=5 offline=5 guessedRequests=0") }
    }
}
