import XCTest
import OathArtworkSource
import OathDiagnostics
@testable import OathTokenImages

private actor CatalogImageTransport: ArtworkTransport {
    enum Response: Sendable { case data(Data), http(Int) }
    let responses: [String: Response]
    var calls: [String: Int] = [:]
    init(_ responses: [String: Response]) { self.responses = responses }
    func data(from url: URL) async throws -> Data {
        calls[url.absoluteString, default: 0] += 1
        try await Task.sleep(for: .milliseconds(15))
        switch responses[url.absoluteString] ?? .http(404) {
        case .data(let data): return data
        case .http(let status): throw ArtworkError.http(status)
        }
    }
}

private actor ArtworkDiagnosticCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class ArtworkFallbackTests: XCTestCase, @unchecked Sendable {
    private let contract = "0x7712c34205737192402172409a8f7ccef8aa2aec"
    private let catalog = "https://tokens.coingecko.com/ethereum/all.json"
    private let logo = "https://cdn.example.org/published.png"
    private var source: String { source(contract) }
    private func source(_ contract: String, network: String = "ethereum") -> String {
        "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/\(network)/assets/\(contract)/logo.png"
    }
    private func list(_ tokens: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tokens": tokens])
    }
    private func token(_ contract: String, chain: Int = 1, logo: String? = nil) -> [String: Any] {
        ["chainId": chain, "address": contract, "symbol": "SAME", "logoURI": logo ?? self.logo]
    }
    private var image: Data {
        Data("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect width='16' height='16'/></svg>".utf8)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testMissingOriginalRecoversAndCachedReplacementAvoidsRepeated404AfterRelaunch() async throws {
        let transport = CatalogImageTransport([
            source: .http(404), catalog: .data(try list([token(contract)])), logo: .data(image)
        ])
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let loader = ArtworkLoader(directory: folder, transport: transport,
            fallbackCatalog: ArtworkFallbackCatalog(transport: transport))
        let result = await loader.image(for: [source])
        XCTAssertNotNil(result)
        let offline = CatalogImageTransport([:])
        let relaunched = ArtworkLoader(directory: folder, transport: offline,
            fallbackCatalog: ArtworkFallbackCatalog(transport: offline))
        let restored = await relaunched.image(for: [source])
        XCTAssertNotNil(restored)
        let calls = await transport.calls, offlineCalls = await offline.calls
        XCTAssertEqual(calls[source], 1); XCTAssertEqual(calls[catalog], 1); XCTAssertEqual(calls[logo], 1)
        XCTAssertTrue(offlineCalls.isEmpty)
    }

    func testChainAndContractIdentityPreventSameTickerSubstitution() async throws {
        let other = "0x1111111111111111111111111111111111111111"
        let data = try list([token(contract, chain: 56), token(other)])
        let decoded = try ArtworkFallbackCatalog.decode(data, chainID: 1)
        XCTAssertNil(decoded[contract]); XCTAssertEqual(decoded[other], logo)
        let transport = CatalogImageTransport([catalog: .data(data)])
        let resolver = ArtworkFallbackCatalog(transport: transport)
        let result = await resolver.sources(for: source)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(ArtworkFallbackCatalog.identity(source)?.chainID, 1)
        XCTAssertEqual(ArtworkFallbackCatalog.identity(source(contract, network: "smartchain"))?.chainID, 56)
        XCTAssertEqual(ArtworkFallbackCatalog.identity(source("0x" + contract.dropFirst(2).uppercased()))?.contract, contract)
    }

    func testUnsafeAndConflictingMetadataIsNotUsed() throws {
        for invalid in ["file:///private/image.png", "https://127.0.0.1/image.png", "https://user:secret@cdn.example.org/logo.png"] {
            XCTAssertTrue(try ArtworkFallbackCatalog.decode(list([token(contract, logo: invalid)]), chainID: 1).isEmpty)
        }
        XCTAssertThrowsError(try ArtworkFallbackCatalog.decode(list([
            token(contract), token(contract, logo: "https://cdn.example.org/different.png")
        ]), chainID: 1))
        for invalid in [source + "?credentials=secret", source.replacingOccurrences(of: "trustwallet/assets", with: "someone/assets"),
                        source.replacingOccurrences(of: "raw.githubusercontent.com", with: "cdn.example.org"), source("0x1234"),
                        source(contract, network: "unknown")] {
            XCTAssertNil(ArtworkFallbackCatalog.identity(invalid))
        }
    }

    func testConcurrentMissingImagesShareCatalogAndFinishWithoutNestedSlotDeadlock() async throws {
        let contracts = (1...12).map { "0x" + String(format: "%040x", $0) }
        let transport = CatalogImageTransport([catalog: .data(try list(contracts.map { token($0) })), logo: .data(image)])
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let loader = ArtworkLoader(directory: folder, transport: transport,
            fallbackCatalog: ArtworkFallbackCatalog(transport: transport))
        let sources = contracts.map { source($0) }
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for source in sources { group.addTask { await loader.image(for: [source]) != nil } }
            var count = 0; for await result in group { if result { count += 1 } }; return count
        }
        XCTAssertEqual(count, 12)
        let calls = await transport.calls
        XCTAssertEqual(calls[catalog], 1)
    }

    func testTransientImageFailureDoesNotTriggerCatalogAndCatalogFailureHasCooldown() async throws {
        let transport = CatalogImageTransport([source: .http(503), catalog: .data(try list([token(contract)])), logo: .data(image)])
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let loader = ArtworkLoader(directory: folder, transport: transport,
            fallbackCatalog: ArtworkFallbackCatalog(transport: transport))
        let image = await loader.image(for: [source]); XCTAssertNil(image)
        let calls = await transport.calls; XCTAssertNil(calls[catalog])
        let unavailable = CatalogImageTransport([catalog: .http(503)])
        let resolver = ArtworkFallbackCatalog(transport: unavailable)
        for _ in 0..<3 {
            let sources = await resolver.sources(for: source); XCTAssertTrue(sources.isEmpty)
        }
        let retryCalls = await unavailable.calls; XCTAssertEqual(retryCalls[catalog], 1)
    }

    func testOriginalAndFallbackFailureUseSharedPrivateCorrelatedDiagnostics() async throws {
        let capture = ArtworkDiagnosticCapture()
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        OathDiagnostics.configure(file: folder.appendingPathComponent("outbox.json"), transport: capture)
        let transport = CatalogImageTransport([source: .http(404), catalog: .http(503)])
        let loader = ArtworkLoader(directory: folder.appendingPathComponent("images"), transport: transport,
            fallbackCatalog: ArtworkFallbackCatalog(transport: transport))
        let result = await OathDiagnostics.$chain.withValue("ethereum") { await loader.image(for: [source]) }
        XCTAssertNil(result)
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.events.contains(where: { $0.operation == "fallback_catalog" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events
        let primary = try XCTUnwrap(events.first { $0.operation == "download_decode" })
        let fallback = try XCTUnwrap(events.first { $0.operation == "fallback_catalog" })
        XCTAssertEqual(primary.error.message, "http(404)")
        XCTAssertEqual(fallback.error.message, "http(503)")
        XCTAssertNotNil(primary.operationID); XCTAssertEqual(primary.operationID, fallback.operationID)
        XCTAssertEqual(fallback.context["chain"], "ethereum")
        XCTAssertEqual(primary.context["stage"], "primary")
        let report = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(report.contains(contract)); XCTAssertFalse(report.contains("https://"))
        XCTAssertFalse(report.contains("/all.json")); XCTAssertFalse(report.contains("logo.png"))
    }
}
