import XCTest
import OathArtworkSource
@testable import OathTokenImages

final class ArtworkLiveTests: XCTestCase, @unchecked Sendable {
    struct Sample: Decodable, Sendable { let name: String; let url: String }
    func testReportedBUIDLMissingArtworkRecoversAndSurvivesRelaunch() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_BUIDL_ARTWORK"] == "1" else {
            throw XCTSkip("Opt-in public BUIDL artwork recovery; no wallet or credentials")
        }
        let source = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0x7712c34205737192402172409a8F7ccef8aA2AEc/logo.png"
        XCTAssertEqual(String(ArtworkSource.key(source).prefix(12)), "be01ed61ace5")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = ArtworkLoader(directory: directory)
        let recovered = await loader.image(for: [source])
        XCTAssertNotNil(recovered, "The missing catalog image must recover from the exact contract identity")
        let relaunched = ArtworkLoader(directory: directory)
        let saved = await relaunched.cached(for: [source])
        XCTAssertNotNil(saved, "The successfully decoded original must survive relaunch")
    }

    func testPublicProviderArtworkDownloadsAndDecodesAtSourceResolution() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_ARTWORK"] == "1" else { throw XCTSkip("Opt-in public image downloads; no wallet or RPC credentials") }
        let file = try XCTUnwrap(Bundle.module.url(forResource: "live-artwork", withExtension: "json", subdirectory: "Fixtures"))
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: file))
        // Small batches respect the public CDN; each sample uses the production
        // bounded transport and decoder, including TON WebP and Aptos SVG.
        for offset in stride(from: 0, to: samples.count, by: 4) {
            await withTaskGroup(of: (String, String, Bool).self) { group in
                for sample in samples[offset..<min(offset + 4, samples.count)] {
                    group.addTask {
                        do {
                            let data = try await ArtworkURLTransport().data(from: URL(string: sample.url)!)
                            let image = try ArtworkImage.decode(data)
                            let detail: String
                            switch image {
                            case .raster(let raster): detail = "\(raster.width)x\(raster.height)"
                            case .vector: detail = "vector"
                            }
                            return (sample.name, detail, true)
                        } catch { return (sample.name, String(describing: error), false) }
                    }
                }
                for await (name, detail, success) in group {
                    print("ARTWORK_LIVE \(name): \(detail)")
                    XCTAssertTrue(success, name + ": " + detail)
                }
            }
        }
    }
}

private struct PublicCatalogMetadata: TokenArtworkMetadata {
    let token: TokenArtworkIdentity
    let source: String
    func sources(for requested: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        requested == token && !cachedOnly ? [source] : []
    }
}

extension ArtworkLiveTests {
    func testPublicTokenMatrixThroughProductionResolverAndOfflineRelaunch() async throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_LIVE_TOKEN_MATRIX"] else {
            throw XCTSkip("Opt-in read-only published token catalog matrix")
        }
        struct Token: Decodable, Sendable {
            let networkID: String, reference: String, name: String, source: String, storedSource: String
            let decimals: Int
        }
        let tokens = try JSONDecoder().decode([Token].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThan(tokens.count, 50)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = ArtworkLoader(directory: dir.appendingPathComponent("images"))
        let identities = dir.appendingPathComponent("identities")
        for offset in stride(from: 0, to: tokens.count, by: 3) {
            await withTaskGroup(of: (String, String, Bool).self) { group in
                for token in tokens[offset..<min(offset + 3, tokens.count)] {
                    group.addTask {
                        guard let identity = TokenArtworkIdentity(networkID: token.networkID, reference: token.reference, decimals: token.decimals) else {
                            return (token.networkID, token.name, false)
                        }
                        let metadata = PublicCatalogMetadata(token: identity, source: token.source)
                        let resolver = TokenArtworkResolver(loader: loader, metadata: metadata, directory: identities)
                        // nil logos follow the same fallback as a failed guessed
                        // source, without making the live probe request 90 known
                        // nonexistent files. Broken-source handling is host-tested.
                        let search = await resolver.image(for: identity, sources: [])
                        let home = await resolver.cached(for: identity, sources: [token.storedSource])
                        let relaunched = TokenArtworkResolver(
                            loader: ArtworkLoader(directory: dir.appendingPathComponent("images")),
                            metadata: metadata, directory: identities)
                        let offline = await relaunched.cached(for: identity, sources: [])
                        return (token.networkID, token.name, search != nil && home != nil && offline != nil)
                    }
                }
                for await (network, name, passed) in group {
                    print("TOKEN_ARTWORK_LIVE \(network) / \(name): \(passed ? "decoded + shared + offline" : "unavailable")")
                    XCTAssertTrue(passed, network + " / " + name)
                }
            }
        }
    }
}
