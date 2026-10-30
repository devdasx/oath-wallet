import XCTest
import OathArtworkSource
@testable import OathTokenImages

private actor ReportedEVMImageFeed: ArtworkTransport {
    let offline: Bool
    private(set) var calls: [String: Int] = [:]
    init(offline: Bool = false) { self.offline = offline }
    func data(from url: URL) async throws -> Data {
        calls[url.absoluteString, default: 0] += 1
        if offline { throw ArtworkError.http(503) }
        return try await ArtworkURLTransport().data(from: url)
    }
}
private actor ReportedEVMNoMetadata: TokenArtworkMetadata {
    private(set) var freshRequests = 0
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        if !cachedOnly { freshRequests += 1 }
        return []
    }
}
final class ReportedEVMArtworkTests: XCTestCase, @unchecked Sendable {
    func testExactReportedTokensUsePublishedImagesAndSurviveOfflineRelaunch() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_REPORTED_EVM_ARTWORK"] == "1" else {
            throw XCTSkip("Opt-in exact reported public token images; no wallets or credentials")
        }
        struct Sample: Decodable { let network: String; let reference: String; let source: String; let sourceHash: String }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf:
            Bundle.module.url(forResource: "evm-reported-artwork", withExtension: "json", subdirectory: "Fixtures")!))
        XCTAssertEqual(Set(samples.map(\.network)), ["flare", "gnosis", "unichain"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let images = folder.appendingPathComponent("images"), identities = folder.appendingPathComponent("identities")
        let feed = ReportedEVMImageFeed(), metadata = ReportedEVMNoMetadata()
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: images, transport: feed,
            fallbackCatalog: ArtworkFallbackCatalog(transport: feed)), metadata: metadata, directory: identities)
        for sample in samples {
            XCTAssertEqual(String(ArtworkSource.key(sample.source).prefix(12)), sample.sourceHash)
            XCTAssertEqual(ArtworkFallbackCatalog.identity(sample.source)?.contract, sample.reference)
            let result = await resolver.image(for: TokenArtworkIdentity(networkID: sample.network, reference: sample.reference, decimals: 6)!, sources: [sample.source])
            XCTAssertNotNil(result, sample.network)
        }
        let calls = await feed.calls
        for sample in samples {
            let platform = sample.network == "flare" ? "flare-network" : sample.network == "gnosis" ? "xdai" : sample.network
            XCTAssertEqual(calls["https://tokens.coingecko.com/\(platform)/all.json"], 1)
            XCTAssertNil(calls[sample.source], "Published artwork must avoid the reported 404")
        }
        let requests = await metadata.freshRequests; XCTAssertEqual(requests, 0)
        let offline = ReportedEVMImageFeed(offline: true)
        let restored = TokenArtworkResolver(loader: ArtworkLoader(directory: images, transport: offline,
            fallbackCatalog: ArtworkFallbackCatalog(transport: offline)), metadata: ReportedEVMNoMetadata(), directory: identities)
        for sample in samples {
            let result = await restored.image(for: TokenArtworkIdentity(networkID: sample.network, reference: sample.reference, decimals: 6)!, sources: [])
            XCTAssertNotNil(result, sample.network)
        }
        let offlineCalls = await offline.calls; XCTAssertTrue(offlineCalls.isEmpty)
        print("REPORTED_EVM_ARTWORK_RECOVERY networks=flare,gnosis,unichain decoded=3 offline=3 guessedRequests=0 metadataRequests=0")
    }
}
