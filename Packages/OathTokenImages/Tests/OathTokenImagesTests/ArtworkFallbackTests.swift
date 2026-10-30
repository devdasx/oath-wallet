import XCTest
import OathArtworkSource
import OathDiagnostics
@testable import OathTokenImages

private actor CatalogImageTransport: ArtworkTransport {
    enum Response: Sendable { case data(Data), http(Int), limited(String) }
    var responses: [String: Response]
    var calls: [String: Int] = [:]
    init(_ responses: [String: Response]) { self.responses = responses }
    func set(_ response: Response, for url: String) { responses[url] = response }
    func data(from url: URL) async throws -> Data {
        calls[url.absoluteString, default: 0] += 1
        try await Task.sleep(for: .milliseconds(15))
        switch responses[url.absoluteString] ?? .http(404) {
        case .data(let data): return data
        case .http(let status):
            if [404, 410].contains(status) {
                try ArtworkURLTransport.validate(HTTPURLResponse(url: url, statusCode: status,
                    httpVersion: nil, headerFields: nil)!, request: URLRequest(url: url))
            }
            throw ArtworkError.http(status)
        case .limited(let retryAfter): throw ArtworkRateLimit(retryAfter: retryAfter)
        }
    }
}

private final class ArtworkTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 0)
    func read() -> Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value = value.addingTimeInterval(interval) } }
}

actor ArtworkDiagnosticCapture: DiagnosticTransport {
    static let shared = ArtworkDiagnosticCapture()
    static let file = FileManager.default.temporaryDirectory.appendingPathComponent("OathArtworkDiagnostics-" + UUID().uuidString).appendingPathComponent("outbox.json")
    func since(_ date: Date) -> [DiagnosticEvent] { events.filter { $0.occurredAt >= date } }
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private actor UnavailableTokenArtworkMetadata: TokenArtworkMetadata {
    var requests = 0
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        if !cachedOnly { requests += 1 }
        return []
    }
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

    func testReportedBNBMissingOptionalLogoDoesNotRepeatAfterRelaunch() async throws {
        let reported = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/smartchain/assets/0x6f4A363845c9B10E69E1CEb9c69b4754209a672f/logo.png"
        XCTAssertEqual(String(ArtworkSource.key(reported).prefix(12)), "fd1b77f2e21c")
        let bnbCatalog = "https://tokens.coingecko.com/binance-smart-chain/all.json"
        let transport = CatalogImageTransport([reported: .http(404), bnbCatalog: .data(try list([token(contract, chain: 56)]))])
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let capture = ArtworkDiagnosticCapture.shared, started = Date()
        OathDiagnostics.configure(file: ArtworkDiagnosticCapture.file, transport: capture)
        for _ in 0..<3 {
            let loader = ArtworkLoader(directory: folder.appendingPathComponent("images"), transport: transport,
                fallbackCatalog: ArtworkFallbackCatalog(transport: transport))
            let result = await loader.image(for: [reported])
            XCTAssertNil(result, "Keep the existing fallback icon when the exact token has no published logo")
        }
        let calls = await transport.calls
        XCTAssertEqual(calls[reported], 1, "Known absence must survive relaunch without repeated missing-file requests")
        // Confirm the shared asynchronous diagnostic sink is active so an
        // accidentally unconfigured capture cannot make this check pass.
        // Availability errors are intentionally excluded by the current policy.
        OathDiagnostics.record(ArtworkError.invalidImage, component: "artwork_test", operation: "sentinel")
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.since(started).contains(where: { $0.operation == "sentinel" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.since(started)
        XCTAssertTrue(events.contains { $0.operation == "sentinel" }, "The diagnostic sink must actually receive the barrier")
        XCTAssertFalse(events.contains { $0.component == "artwork" || $0.component == "network" })
    }

    func testMissingLogoCanRecoverAfterExpiryWithoutSlidingTheDeadline() async throws {
        let clock = ArtworkTestClock()
        let transport = CatalogImageTransport([source: .http(410), catalog: .data(try list([token("0x9999999999999999999999999999999999999999")]))])
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let loader = ArtworkLoader(directory: folder, transport: transport,
            fallbackCatalog: ArtworkFallbackCatalog(transport: transport, now: { clock.read() }), now: { clock.read() })
        let missing = await loader.image(for: [source]); XCTAssertNil(missing)
        clock.advance(12 * 3600)
        await transport.set(.data(image), for: source)
        let stillAbsent = await loader.image(for: [source]); XCTAssertNil(stillAbsent)
        clock.advance(12 * 3600 + 1)
        let recovered = await loader.image(for: [source]); XCTAssertNotNil(recovered)
        let calls = await transport.calls; XCTAssertEqual(calls[source], 2)
        let restored = ArtworkLoader(directory: folder, transport: CatalogImageTransport([:]), now: { clock.read() })
        let saved = await restored.image(for: [source]); XCTAssertNotNil(saved)
    }

    func testMissingGuessDoesNotBlockAnotherSourceOrPersistPlaceholder() async throws {
        let transport = CatalogImageTransport([source: .http(404), catalog: .data(try list([token("0x9999999999999999999999999999999999999999")])), logo: .data(image)])
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let loader = ArtworkLoader(directory: folder, transport: transport,
            fallbackCatalog: ArtworkFallbackCatalog(transport: transport))
        let result = await loader.image(for: [source, logo]); XCTAssertNotNil(result)
        let guessed = await loader.cached(for: [source]); XCTAssertNil(guessed)
        let actual = await loader.cached(for: [logo]); XCTAssertNotNil(actual)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let marker = try XCTUnwrap(files.first { $0.pathExtension == "missing" })
        XCTAssertEqual(marker.deletingPathExtension().lastPathComponent, ArtworkSource.key(source))
        let data = try Data(contentsOf: marker)
        XCTAssertLessThan(data.count, 1024)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(contract))
    }

    func testOnlyExactDirectory404And410AreOptionalNotOtherFailures() throws {
        let url = try XCTUnwrap(URL(string: source))
        for status in [404, 410] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try ArtworkURLTransport.validate(response, request: URLRequest(url: url))) {
                XCTAssertTrue($0 is OptionalArtworkAbsent)
            }
        }
        for status in [401, 403, 429, 500, 503] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try ArtworkURLTransport.validate(response, request: URLRequest(url: url))) {
                XCTAssertFalse($0 is OptionalArtworkAbsent)
            }
        }
        for unrecognized in [logo, source + "?revision=2", source.replacingOccurrences(of: "trustwallet/assets", with: "someone/assets")] {
            let other = try XCTUnwrap(URL(string: unrecognized))
            let response = HTTPURLResponse(url: other, statusCode: 404, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try ArtworkURLTransport.validate(response, request: URLRequest(url: other))) {
                XCTAssertEqual($0 as? ArtworkError, .http(404))
            }
            XCTAssertThrowsError(try ArtworkURLTransport.validate(response, request: URLRequest(url: url))) {
                XCTAssertEqual($0 as? ArtworkError, .http(404), "A redirected failure is not proof the original optional file is absent")
            }
        }
    }

    func testActualImageFailuresRemainReportedAndDoNotCreateAbsenceMarkers() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let capture = ArtworkDiagnosticCapture.shared, started = Date()
        OathDiagnostics.configure(file: ArtworkDiagnosticCapture.file, transport: capture)
        let transport = CatalogImageTransport([source: .http(403), logo: .http(404)])
        let images = folder.appendingPathComponent("images")
        let loader = ArtworkLoader(directory: images, transport: transport,
            fallbackCatalog: ArtworkFallbackCatalog(transport: transport))
        let result = await loader.image(for: [source, logo]); XCTAssertNil(result)
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.since(started).filter({ $0.operation == "download_decode" }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.since(started)
        XCTAssertEqual(Set(events.filter { $0.operation == "download_decode" }.map { $0.error.message }), ["http(403)", "http(404)"])
        XCTAssertTrue(events.contains { $0.component == "network" && $0.error.code == 404 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: images.appendingPathComponent(ArtworkSource.key(source) + ".missing").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: images.appendingPathComponent(ArtworkSource.key(logo) + ".missing").path))
        let report = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(report.contains(contract)); XCTAssertFalse(report.contains("https://"))
    }

    func testAbsentLogoDiskEntriesAreBounded() async throws {
        let contracts = (1...260).map { "0x" + String(format: "%040x", $0) }
        let transport = CatalogImageTransport([catalog: .data(try list([token("0x9999999999999999999999999999999999999999")]))])
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let loader = ArtworkLoader(directory: folder, transport: transport,
            fallbackCatalog: ArtworkFallbackCatalog(transport: transport))
        await withTaskGroup(of: Void.self) { group in
            for contract in contracts { group.addTask { _ = await loader.image(for: [self.source(contract)]) } }
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "missing" }.count, 256)
        XCTAssertFalse(files.contains { $0.pathExtension == "artwork" }, "No failed response or placeholder is saved as an image")
    }

    func testSearchUsesOnePublishedListBeforeMissingGuessedImagesOrPerCoinMetadata() async throws {
        let contracts = (1...12).map { "0x" + String(format: "%040x", $0) }
        let transport = CatalogImageTransport([
            catalog: .data(try list(contracts.map { token($0) })), logo: .data(image)
        ])
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let metadata = UnavailableTokenArtworkMetadata()
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: folder.appendingPathComponent("images"),
            transport: transport, fallbackCatalog: ArtworkFallbackCatalog(transport: transport)),
            metadata: metadata, directory: folder.appendingPathComponent("identities"))
        let identities = contracts.map { TokenArtworkIdentity(networkID: "ethereum", reference: $0)! }
        let results = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for identity in identities {
                group.addTask { await resolver.image(for: identity, sources: [self.source(identity.reference)]) != nil }
            }
            var count = 0; for await found in group { if found { count += 1 } }; return count
        }
        XCTAssertEqual(results, identities.count)
        let calls = await transport.calls, metadataRequests = await metadata.requests
        XCTAssertEqual(calls[catalog], 1, "All results on the same network share one published list")
        XCTAssertEqual(calls[logo], 1, "The published image is shared and decoded once")
        XCTAssertEqual(metadataRequests, 0, "Scrolling results must not issue one CoinGecko detail request per token")
        for contract in contracts { XCTAssertNil(calls[source(contract)], "Never download a guess when the exact logo is published") }
        let offline = CatalogImageTransport([:])
        let relaunched = TokenArtworkResolver(loader: ArtworkLoader(directory: folder.appendingPathComponent("images"),
            transport: offline, fallbackCatalog: ArtworkFallbackCatalog(transport: offline)),
            metadata: UnavailableTokenArtworkMetadata(), directory: folder.appendingPathComponent("identities"))
        for identity in identities {
            let cached = await relaunched.image(for: identity, sources: [])
            XCTAssertNotNil(cached)
        }
        let offlineCalls = await offline.calls; XCTAssertTrue(offlineCalls.isEmpty)
    }

    func testProactiveCatalogRejectsMismatchedTokenIdentityWithoutRequests() async throws {
        let transport = CatalogImageTransport([catalog: .data(try list([token(contract)]))])
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let loader = ArtworkLoader(directory: folder, transport: transport,
            fallbackCatalog: ArtworkFallbackCatalog(transport: transport))
        for identity in [TokenArtworkIdentity(networkID: "base", reference: contract)!,
                         TokenArtworkIdentity(networkID: "ethereum", reference: "0x1111111111111111111111111111111111111111")!] {
            let sources = await loader.catalogSources(for: identity, sources: [source])
            XCTAssertTrue(sources.isEmpty)
        }
        let calls = await transport.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testTaikoUsesPublishedRegistryAndCoalescesConcurrentContracts() async throws {
        let url = "https://raw.githubusercontent.com/gluexprotocol/tokens_registry/main/registry/167000.json"
        let contracts = (1...12).map { "0x" + String(format: "%040x", $0) }
        let rows = contracts.map { token($0, chain: 167000) } + [token(contracts[0], chain: 1, logo: "https://cdn.example.org/wrong-chain.png")]
        let transport = CatalogImageTransport([url: .data(try JSONSerialization.data(withJSONObject: rows))])
        let resolver = ArtworkFallbackCatalog(transport: transport)
        let results = await withTaskGroup(of: [String].self, returning: [[String]].self) { group in
            for contract in contracts { group.addTask { await resolver.sources(for: self.source(contract, network: "taiko")) } }
            var results: [[String]] = []; for await value in group { results.append(value) }; return results
        }
        XCTAssertEqual(results.count, 12)
        XCTAssertTrue(results.allSatisfy { $0 == [logo] }, "Match both chain ID and contract; never a symbol")
        let again = await resolver.sources(for: source(contracts[0], network: "taiko"))
        XCTAssertEqual(again, [logo])
        let calls = await transport.calls
        XCTAssertEqual(calls, [url: 1], "Do not request the unavailable CoinGecko Taiko list")
    }

    func testTaikoRegistryRejectsConflictsAndUnsafeLogos() async throws {
        let url = "https://raw.githubusercontent.com/gluexprotocol/tokens_registry/main/registry/167000.json"
        for rows in [
            [token(contract, chain: 167000), token(contract, chain: 167000, logo: "https://cdn.example.org/conflicting.png")],
            [token(contract, chain: 167000, logo: "https://localhost/private.png")],
            [token(contract, chain: 1)]
        ] {
            let transport = CatalogImageTransport([url: .data(try JSONSerialization.data(withJSONObject: rows))])
            let resolver = ArtworkFallbackCatalog(transport: transport)
            let found = await resolver.sources(for: source(contract, network: "taiko"))
            XCTAssertTrue(found.isEmpty)
        }
    }

    func testIndependentCatalogHostsDoNotShareRateLimitCooldown() async throws {
        let taiko = "https://raw.githubusercontent.com/gluexprotocol/tokens_registry/main/registry/167000.json"
        let registry = try JSONSerialization.data(withJSONObject: [token(contract, chain: 167000)])
        for limitedTaiko in [false, true] {
            let transport = CatalogImageTransport([
                taiko: limitedTaiko ? .http(429) : .data(registry),
                catalog: limitedTaiko ? .data(try list([token(contract)])) : .http(429)
            ])
            let resolver = ArtworkFallbackCatalog(transport: transport)
            _ = await resolver.sources(for: limitedTaiko ? source(contract, network: "taiko") : source)
            let independent = await resolver.sources(for: limitedTaiko ? source : source(contract, network: "taiko"))
            XCTAssertEqual(independent, [logo])
            let calls = await transport.calls; XCTAssertEqual(calls, [taiko: 1, catalog: 1])
        }
    }

    func testCrossNetworkSearchRetainsEarlierCatalogsDuringProviderCooldown() async throws {
        let networks = [("ethereum", "ethereum", 1), ("base", "base", 8453),
                        ("arbitrum", "arbitrum-one", 42161), ("optimism", "optimistic-ethereum", 10),
                        ("polygon", "polygon-pos", 137), ("smartchain", "binance-smart-chain", 56)]
        var responses: [String: CatalogImageTransport.Response] = [:]
        for (_, platform, chain) in networks {
            responses["https://tokens.coingecko.com/\(platform)/all.json"] = .data(try list([token(contract, chain: chain)]))
        }
        responses["https://tokens.coingecko.com/linea/all.json"] = .limited("60")
        let transport = CatalogImageTransport(responses)
        let resolver = ArtworkFallbackCatalog(transport: transport)
        for (network, _, _) in networks {
            let found = await resolver.sources(for: source(contract, network: network))
            XCTAssertEqual(found, [logo])
        }
        _ = await resolver.sources(for: source(contract, network: "linea"))
        for (network, _, _) in networks {
            let retained = await resolver.sources(for: source(contract, network: network))
            XCTAssertEqual(retained, [logo], "Cross-network scrolling must not discard a fresh list during cooldown")
        }
        let calls = await transport.calls
        XCTAssertTrue(calls.values.allSatisfy { $0 == 1 })
    }

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

    func testRateLimitStopsCrossNetworkBurst() async throws {
        let networks = ["base", "ethereum", "linea", "fantom", "hyperevm", "optimism",
                        "unichain", "smartchain", "arbitrum", "monad"]
        let sources = networks.map { source(contract, network: $0) }
        let urls = try sources.map { source in
            "https://tokens.coingecko.com/\(try XCTUnwrap(ArtworkFallbackCatalog.identity(source)).platform)/all.json"
        }
        let transport = CatalogImageTransport(Dictionary(uniqueKeysWithValues: urls.map { ($0, .http(429)) }))
        let resolver = ArtworkFallbackCatalog(transport: transport)
        let count = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for source in sources { group.addTask { await resolver.sources(for: source).count } }
            var count = 0; for await value in group { count += value }; return count
        }
        XCTAssertEqual(count, 0)
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.key.contains("tokens.coingecko.com") }.values.reduce(0, +), 1,
                       "One host's rate limit must stop queued requests for other networks")
        XCTAssertEqual(calls["https://raw.githubusercontent.com/gluexprotocol/tokens_registry/main/registry/8453.json"], 1,
                       "Base may try its independent registry once")
    }

    func testRateLimitStillServesCachedNetworkArtwork() async throws {
        let base = "https://tokens.coingecko.com/base/all.json"
        let transport = CatalogImageTransport([catalog: .data(try list([token(contract)])), base: .http(429)])
        let resolver = ArtworkFallbackCatalog(transport: transport)
        let initial = await resolver.sources(for: source)
        XCTAssertEqual(initial, [logo])
        _ = await resolver.sources(for: source(contract, network: "base"))
        let cached = await resolver.sources(for: source)
        _ = await resolver.sources(for: source(contract, network: "arbitrum"))
        XCTAssertEqual(cached, [logo])
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0.key.contains("tokens.coingecko.com") }.values.reduce(0, +), 2,
                       "The cooldown must not turn another network into a fresh request")
        XCTAssertEqual(calls["https://raw.githubusercontent.com/gluexprotocol/tokens_registry/main/registry/8453.json"], 1)
    }

    func testRateLimitHonorsRetryAfterAndResumesDeferredNetworks() async throws {
        let base = "https://tokens.coingecko.com/base/all.json", clock = ArtworkTestClock()
        let transport = CatalogImageTransport([catalog: .limited("120"), base: .data(try list([token(contract, chain: 8453)]))])
        let resolver = ArtworkFallbackCatalog(transport: transport, now: { clock.read() })
        _ = await resolver.sources(for: source)
        clock.advance(61)
        let deferred = await resolver.sources(for: source(contract, network: "base"))
        XCTAssertTrue(deferred.isEmpty)
        let during = await transport.calls
        XCTAssertNil(during[base])
        clock.advance(60)
        let recovered = await resolver.sources(for: source(contract, network: "base"))
        XCTAssertEqual(recovered, [logo])
        await transport.set(.data(try list([token(contract)])), for: catalog)
        let original = await resolver.sources(for: source)
        XCTAssertEqual(original, [logo], "The initially limited network can recover too")
        let final = await transport.calls
        XCTAssertEqual(final[base], 1); XCTAssertEqual(final[catalog], 2)
    }

    func testForbiddenCatalogDoesNotDisableOtherNetworks() async throws {
        let base = "https://tokens.coingecko.com/base/all.json"
        let transport = CatalogImageTransport([catalog: .http(403), base: .data(try list([token(contract, chain: 8453)]))])
        let resolver = ArtworkFallbackCatalog(transport: transport)
        _ = await resolver.sources(for: source)
        let other = await resolver.sources(for: source(contract, network: "base"))
        XCTAssertEqual(other, [logo])
        let calls = await transport.calls; XCTAssertEqual(calls.values.reduce(0, +), 2)
    }

    func testRetryAfterIsBoundedAndDoesNotRetainHeaderText() throws {
        for header in [nil, "garbage", "nan", "inf", "-5", "0"] as [String?] {
            XCTAssertEqual(ArtworkRateLimit(retryAfter: header).delay, 60)
        }
        XCTAssertEqual(ArtworkRateLimit(retryAfter: "120").delay, 120)
        XCTAssertEqual(ArtworkRateLimit(retryAfter: "99999999").delay, 3600)
        XCTAssertEqual(ArtworkRateLimit(retryAfter: "Thu, 01 Jan 1970 00:02:00 GMT", now: .init(timeIntervalSince1970: 0)).delay, 120)
        let invalid = ArtworkRateLimit(retryAfter: "private-header-marker") as NSError
        XCTAssertEqual(invalid.code, 429)
        XCTAssertFalse(invalid.localizedDescription.contains("private-header-marker"))
    }

    func testOptionalAbsenceKeepsActualFallbackFailuresAndPrivateDiagnostics() async throws {
        let capture = ArtworkDiagnosticCapture.shared, started = Date()
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        OathDiagnostics.configure(file: ArtworkDiagnosticCapture.file, transport: capture)
        let transport = CatalogImageTransport([source: .http(404), catalog: .http(403)])
        let loader = ArtworkLoader(directory: folder.appendingPathComponent("images"), transport: transport,
            fallbackCatalog: ArtworkFallbackCatalog(transport: transport))
        let result = await OathDiagnostics.$chain.withValue("ethereum") { await loader.image(for: [source]) }
        XCTAssertNil(result)
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            let captured = await capture.since(started)
            if captured.contains(where: { $0.operation == "fallback_catalog" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.since(started)
        XCTAssertFalse(events.contains { $0.operation == "download_decode" }, "Optional absence is not a failed download")
        let fallback = try XCTUnwrap(events.first { $0.operation == "fallback_catalog" })
        XCTAssertEqual(fallback.error.message, "http(403)")
        XCTAssertNotNil(fallback.operationID)
        XCTAssertEqual(fallback.context["chain"], "ethereum")
        let report = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(report.contains(contract)); XCTAssertFalse(report.contains("https://"))
        XCTAssertFalse(report.contains("/all.json")); XCTAssertFalse(report.contains("logo.png"))
        let operationID = UUID()
        let limitedTransport = CatalogImageTransport([catalog: .limited("120")])
        let limited = ArtworkFallbackCatalog(transport: limitedTransport)
        await OathDiagnostics.$operationID.withValue(operationID) {
            _ = await limited.sources(for: source)
            _ = await limited.sources(for: source(contract, network: "linea"))
            _ = await limited.sources(for: source(contract, network: "arbitrum"))
        }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.since(started).contains(where: { $0.operationID == operationID }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let rateEvents = await capture.since(started).filter { $0.operationID == operationID }
        XCTAssertEqual(rateEvents.count, 1, "Keep the actual provider failure; deferred work is not another failure")
        XCTAssertEqual(rateEvents.first?.error.code, 429)
        XCTAssertEqual(rateEvents.first?.context["chain"], "ethereum")

        let recoveryID = UUID()
        let base = "https://tokens.coingecko.com/base/all.json"
        let registry = "https://raw.githubusercontent.com/gluexprotocol/tokens_registry/main/registry/8453.json"
        let recoveryTransport = CatalogImageTransport([base: .limited("120"),
            registry: .data(try JSONSerialization.data(withJSONObject: [token(contract, chain: 8453)]))])
        let recovered = ArtworkFallbackCatalog(transport: recoveryTransport)
        await OathDiagnostics.$operationID.withValue(recoveryID) {
            for _ in 0..<3 {
                let sources = await recovered.sources(for: source(contract, network: "base"))
                XCTAssertEqual(sources, [logo])
            }
        }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.since(started).contains(where: { $0.operationID == recoveryID }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let recoveredEvents = await capture.since(started).filter { $0.operationID == recoveryID }
        XCTAssertEqual(recoveredEvents.count, 1, "Successful failover retains the original failure without duplicating it on cache reads")
        XCTAssertEqual(recoveredEvents.first?.error.code, 429)
        XCTAssertEqual(recoveredEvents.first?.context["chain"], "base")
        XCTAssertEqual(recoveredEvents.first?.context["host"], "tokens.coingecko.com")
        let recoveredReport = String(decoding: try JSONEncoder().encode(recoveredEvents), as: UTF8.self)
        XCTAssertFalse(recoveredReport.contains(contract)); XCTAssertFalse(recoveredReport.contains("https://"))
    }
}
