import XCTest
import OathArtworkSource
@testable import OathTokenImages

private actor SolanaImageTransport: ArtworkTransport {
    let live: Bool
    let list: Data
    var calls: [String: Int] = [:]
    init(live: Bool, list: Data) { self.live = live; self.list = list }
    func data(from url: URL) async throws -> Data {
        calls[url.absoluteString, default: 0] += 1
        if live { return try await ArtworkURLTransport().data(from: url) }
        if url.host == "tokens.coingecko.com" { return list }
        if url.host == "cdn.example.org" {
            return Data("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect width='16' height='16'/></svg>".utf8)
        }
        throw ArtworkError.http(404)
    }
}

private actor NoSolanaDetailMetadata: TokenArtworkMetadata {
    var freshRequests = 0
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        if !cachedOnly { freshRequests += 1 }
        return []
    }
}

final class SolanaArtworkRecoveryTests: XCTestCase, @unchecked Sendable {
    private struct Reported: Decodable { let reference: String; let sourceHash: String }
    private let listURL = "https://tokens.coingecko.com/solana/all.json"
    private func guess(_ mint: String) -> String {
        "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/solana/assets/\(mint)/logo.png"
    }
    private func reported() throws -> [Reported] {
        let file = Bundle.module.url(forResource: "solana-reported-artwork", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode([Reported].self, from: Data(contentsOf: file))
    }
    private func list(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tokens": rows])
    }

    func testSolanaIdentityPreservesCaseAndRejectsInvalidMintsAndForeignPaths() throws {
        let mint = try reported()[0].reference
        let identity = ArtworkFallbackCatalog.identity(guess(mint))
        XCTAssertEqual(identity?.networkID, "solana")
        XCTAssertEqual(identity?.contract, mint)
        XCTAssertNil(identity?.chainID)
        for invalid in ["0x" + String(repeating: "a", count: 40), String(repeating: "1", count: 31),
                        String(repeating: "1", count: 33), String(repeating: "z", count: 44), "0" + mint.dropFirst()] {
            XCTAssertNil(ArtworkFallbackCatalog.identity(guess(invalid)))
        }
        XCTAssertNil(ArtworkFallbackCatalog.identity(guess(mint) + "?key=ignored"))
        XCTAssertNil(ArtworkFallbackCatalog.identity(guess(mint).replacingOccurrences(of: "trustwallet/assets", with: "other/assets")))
    }

    func testSolanaListDoesNotFoldCaseOrAcceptEVMRowsAndConflictingLogos() throws {
        let mint = try reported()[0].reference
        let logo = "https://cdn.example.org/mint.png"
        let row: [String: Any] = ["chainId": NSNull(), "address": mint, "logoURI": logo]
        let data = try list([row, ["chainId": 1, "address": "0x" + String(repeating: "a", count: 40), "logoURI": logo]])
        let decoded = try ArtworkFallbackCatalog.decode(data, chainID: nil)
        XCTAssertEqual(decoded, [mint: logo])
        XCTAssertNil(decoded[mint.lowercased()])
        XCTAssertTrue(try ArtworkFallbackCatalog.decode(list([row]), chainID: 1).isEmpty)
        XCTAssertThrowsError(try ArtworkFallbackCatalog.decode(list([row,
            ["chainId": NSNull(), "address": mint, "logoURI": "https://cdn.example.org/other.png"]]), chainID: nil))
        XCTAssertThrowsError(try ArtworkFallbackCatalog.decode(list([
            ["chainId": NSNull(), "address": String(repeating: "z", count: 44), "logoURI": logo]]), chainID: nil))
    }

    func testReportedSolanaImagesUseOneListAndSurviveOfflineRelaunch() async throws {
        try await verifyRecovery(live: false)
    }

    func testLiveReportedSolanaImagesDecodeAndSurviveOfflineRelaunch() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_SOLANA_ARTWORK"] == "1" else {
            throw XCTSkip("Opt-in public artwork reads; no wallets or credentials")
        }
        try await verifyRecovery(live: true)
    }

    private func verifyRecovery(live: Bool) async throws {
        let samples = try reported()
        XCTAssertEqual(samples.count, 24)
        let data = try list(samples.map { ["chainId": NSNull(), "address": $0.reference,
                                          "logoURI": "https://cdn.example.org/\($0.reference).svg"] })
        let transport = SolanaImageTransport(live: live, list: data)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let metadata = NoSolanaDetailMetadata()
        let images = folder.appendingPathComponent("images"), identities = folder.appendingPathComponent("identities")
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: images, transport: transport,
            fallbackCatalog: ArtworkFallbackCatalog(transport: transport)), metadata: metadata, directory: identities)
        // Small bounded groups also exercise catalog coalescing on a cold start.
        for offset in stride(from: 0, to: samples.count, by: 3) {
            let batch = samples[offset..<min(offset + 3, samples.count)]
            for sample in batch { XCTAssertEqual(String(ArtworkSource.key(guess(sample.reference)).prefix(12)), sample.sourceHash) }
            let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for sample in batch {
                    let mint = sample.reference
                    group.addTask {
                        await resolver.image(for: TokenArtworkIdentity(networkID: "solana", reference: mint, decimals: 6)!,
                            sources: [self.guess(mint)]) != nil
                    }
                }
                var results = [Bool](); for await value in group { results.append(value) }; return results
            }
            XCTAssertTrue(results.allSatisfy { $0 })
        }
        let calls = await transport.calls
        XCTAssertEqual(calls[listURL], 1)
        for sample in samples { XCTAssertNil(calls[guess(sample.reference)]) }
        let fresh = await metadata.freshRequests; XCTAssertEqual(fresh, 0)
        let offline = SolanaImageTransport(live: false, list: Data())
        let relaunched = TokenArtworkResolver(loader: ArtworkLoader(directory: images, transport: offline,
            fallbackCatalog: ArtworkFallbackCatalog(transport: offline)), metadata: NoSolanaDetailMetadata(), directory: identities)
        for sample in samples {
            let restored = await relaunched.image(for: TokenArtworkIdentity(networkID: "solana", reference: sample.reference, decimals: 6)!, sources: [])
            XCTAssertNotNil(restored)
        }
        let offlineCalls = await offline.calls; XCTAssertTrue(offlineCalls.isEmpty)
        if live { print("SOLANA_ARTWORK_RECOVERY images=24 catalogRequests=1 guessedRequests=0 metadataRequests=0 offlineImages=24") }
    }
}
