import XCTest
import OathArtworkSource
@testable import OathTokenImages

private actor TokenMetadata: TokenArtworkMetadata {
    var values: [TokenArtworkIdentity: [String]]
    let cached: Bool
    var calls = 0
    var active = 0
    var peak = 0
    init(_ values: [TokenArtworkIdentity: [String]], cached: Bool = false) { self.values = values; self.cached = cached }
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        if cachedOnly { return cached ? values[token] ?? [] : [] }
        calls += 1; active += 1; peak = max(peak, active)
        try? await Task.sleep(for: .milliseconds(10))
        active -= 1
        return values[token] ?? []
    }
}
private actor TokenImages: ArtworkTransport {
    var calls = 0
    let values: [String: Data]
    init(_ values: [String: Data]) { self.values = values }
    func data(from url: URL) async throws -> Data {
        calls += 1
        guard let data = values[url.absoluteString] else { throw ArtworkError.http(404) }
        return data
    }
}

final class TokenArtworkResolverTests: XCTestCase, @unchecked Sendable {
    private let image = Data("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><circle cx='8' cy='8' r='8' fill='red'/></svg>".utf8)
    private let source = "https://cdn.example.org/token.svg"
    private let missing = "https://cdn.example.org/missing.png"
    private let reference = "0x1234567890aBcDEF1234567890abcDEF12345678"
    private func token(_ network: String = "ethereum", reference: String? = nil, decimals: Int = 6) -> TokenArtworkIdentity {
        TokenArtworkIdentity(networkID: network, reference: reference ?? self.reference, decimals: decimals)!
    }
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testAllTokenNetworksRecoverMissingAndAbsentLogosAndSurviveRelaunch() async throws {
        let networks = TokenArtworkIdentity.evmNetworks.union(["solana", "tron", "ton", "aptos", "sui", "near", "xrpl", "stellar", "thorchain"])
        XCTAssertEqual(networks.count, 31)
        for network in networks.sorted() {
            let token = token(network), dir = folder()
            defer { try? FileManager.default.removeItem(at: dir) }
            let metadata = TokenMetadata([token: [source]])
            let bytes = TokenImages([source: image])
            let loader = ArtworkLoader(directory: dir.appendingPathComponent("images"), transport: bytes)
            let resolver = TokenArtworkResolver(loader: loader, metadata: metadata, directory: dir.appendingPathComponent("identities"))
            // Search supplies an absent guessed URL. Home may supply nil. Detail
            // supplies market metadata. All three must converge on one image.
            let found = await resolver.image(for: token, sources: [missing])
            XCTAssertNotNil(found, network)
            let home = await resolver.image(for: token, sources: [])
            let detail = await resolver.image(for: token, sources: [source])
            XCTAssertNotNil(home, network); XCTAssertNotNil(detail, network)
            let calls = await metadata.calls
            XCTAssertEqual(calls, 1, network)
            let offline = TokenImages([:]), noMetadata = TokenMetadata([:])
            let relaunched = TokenArtworkResolver(
                loader: ArtworkLoader(directory: dir.appendingPathComponent("images"), transport: offline),
                metadata: noMetadata, directory: dir.appendingPathComponent("identities"))
            let restored = await relaunched.cached(for: token, sources: [])
            XCTAssertNotNil(restored, network)
            let downloads = await offline.calls
            XCTAssertEqual(downloads, 0)
        }
    }

    func testIdentitySeparatesNetworksDecimalsAndCaseSensitiveReferences() {
        XCTAssertEqual(token(), token(reference: reference.lowercased()))
        XCTAssertNotEqual(token(), token("base"))
        XCTAssertNotEqual(token(), token(decimals: 18))
        for network in ["solana", "tron", "ton", "aptos", "sui", "near", "xrpl", "stellar", "thorchain"] {
            XCTAssertNotEqual(token(network, reference: "AbC"), token(network, reference: "abc"), network)
        }
        XCTAssertNil(TokenArtworkIdentity(networkID: "ethereum", reference: "native", decimals: 18))
        XCTAssertNil(TokenArtworkIdentity(networkID: "ethereum", reference: "", decimals: 18))
        XCTAssertNil(TokenArtworkIdentity(networkID: "ethereum", reference: reference, decimals: 256))
    }

    func testDetailImageUpdatesAnAlreadyMountedHomeRowAndDoesNotLeakToAnotherChain() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: dir.appendingPathComponent("images"),
            transport: TokenImages([source: image])), metadata: TokenMetadata([:]), directory: dir.appendingPathComponent("identities"))
        let token = token()
        let missingImage = await resolver.image(for: token, sources: [missing])
        XCTAssertNil(missingImage)
        let stream = await resolver.updates(for: token)
        var iterator = stream.makeAsyncIterator()
        let detailImage = await resolver.image(for: token, sources: [source])
        XCTAssertNotNil(detailImage)
        let update = await iterator.next()
        XCTAssertNotNil(update)
        let wrongChain = await resolver.cached(for: self.token("base"), sources: [])
        XCTAssertNil(wrongChain)
    }

    func testExistingDetailMetadataAvoidsBrokenURLAndNoFreshMetadataRequest() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let metadata = TokenMetadata([token(): [source]], cached: true), bytes = TokenImages([source: image])
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: dir.appendingPathComponent("images"), transport: bytes),
            metadata: metadata, directory: dir.appendingPathComponent("identities"))
        let result = await resolver.image(for: token(), sources: [missing])
        XCTAssertNotNil(result)
        let downloads = await bytes.calls, requests = await metadata.calls
        XCTAssertEqual(downloads, 1); XCTAssertEqual(requests, 0)
    }

    func testMissingMetadataHasCooldownAndNeverPersistsPlaceholder() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let metadata = TokenMetadata([:])
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: dir.appendingPathComponent("images"), transport: TokenImages([:])),
            metadata: metadata, directory: dir.appendingPathComponent("identities"))
        for _ in 0..<5 {
            let image = await resolver.image(for: token(), sources: [])
            XCTAssertNil(image)
        }
        let requests = await metadata.calls
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("identities").path))
    }

    func testConcurrentRowsCoalesceAndMetadataRequestsStayBounded() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let tokens = (0..<12).map { token(reference: "0x" + String(format: "%040x", $0)) }
        let metadata = TokenMetadata(Dictionary(uniqueKeysWithValues: tokens.map { ($0, [source]) }))
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: dir.appendingPathComponent("images"), transport: TokenImages([source: image])),
            metadata: metadata, directory: dir.appendingPathComponent("identities"))
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for token in tokens + tokens { group.addTask { await resolver.image(for: token, sources: []) != nil } }
            var count = 0; for await result in group { if result { count += 1 } }; return count
        }
        XCTAssertEqual(count, 24)
        let requests = await metadata.calls, peak = await metadata.peak
        XCTAssertEqual(requests, 12); XCTAssertLessThanOrEqual(peak, 3)
    }

    func testObserverStoppedBeforeIterationDoesNotWaitForAnotherImage() async {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let resolver = TokenArtworkResolver(metadata: TokenMetadata([:]), directory: dir)
        let id = UUID(), token = token()
        let stream = await resolver.updates(for: token, observerID: id)
        await resolver.stopUpdates(for: token, observerID: id)
        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertNil(next)
    }

    func testFallbackCatalogCoversEverySupportedEVMNetwork() throws {
        let directories = ["avalanche": "avalanchec", "bnb": "smartchain", "gnosis": "xdai"]
        for network in TokenArtworkIdentity.evmNetworks {
            let directory = directories[network] ?? network
            let source = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/\(directory)/assets/\(reference)/logo.png"
            let identity = try XCTUnwrap(ArtworkFallbackCatalog.identity(source), network)
            XCTAssertEqual(identity.networkID, network)
            XCTAssertEqual(identity.contract, reference.lowercased())
        }
    }
}
