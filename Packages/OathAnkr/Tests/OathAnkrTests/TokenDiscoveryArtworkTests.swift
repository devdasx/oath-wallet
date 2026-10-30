import XCTest
import OathDiagnostics
import OathTokenImages
import OathArtworkSource
@testable import OathAnkr

private actor ArtworkDirectoryTransport: AnkrTransport {
    let response: Data
    let status: Int
    var calls = 0
    init(_ response: Data, status: Int = 200) { self.response = response; self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        try await Task.sleep(for: .milliseconds(15))
        return (response, status)
    }
}
private actor PublicImageProbe: ArtworkTransport {
    var urls: [String] = []
    var failures: [String: Int] = [:]
    func data(from url: URL) async throws -> Data {
        urls.append(url.absoluteString)
        do { return try await ArtworkURLTransport().data(from: url) }
        catch {
            // Public provider/HTTP category only; never response bodies or URLs.
            let kind: String
            if case ArtworkError.http(let status) = error { kind = "http_\(status)" }
            else { kind = String((error as NSError).code) }
            failures[(url.host ?? "unknown") + ":" + kind, default: 0] += 1
            throw error
        }
    }
}

private actor PublicArtworkMetadataProbe: AnkrTransport {
    var statuses: [Int: Int] = [:]
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let response = try await AnkrHTTPTransport().send(request)
        statuses[response.1, default: 0] += 1
        return response
    }
}

private actor ArtworkDiagnosticsCapture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ values: [DiagnosticEvent]) async throws { events += values }
}

final class TokenDiscoveryArtworkTests: XCTestCase, @unchecked Sendable {
    private let reference = "bridge.near"
    private let source = "https://cdn.example.org/exact-token.png"
    private var seed: Data { Data(#"[{"id":"fixture-token","name":"Token","symbol":"TKN","platforms":{"near-protocol":"bridge.near"}}]"#.utf8) }
    private func metadata(reference: String = "bridge.near", platform: String = "near-protocol", id: String = "fixture-token") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id,
            "detail_platforms": [platform: ["contract_address": reference, "decimal_place": NSNull()]],
            "image": ["small": source]])
    }

    func testArtworkWithoutDecimalsIsVerifiedCoalescedAndPersistsWithoutInventingScale() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ArtworkDirectoryTransport(try metadata())
        let catalog = TokenDiscoveryCatalog(transport: transport, directory: directory, seed: seed)
        let identity = TokenArtworkIdentity(networkID: "near", reference: reference)!
        let before = await catalog.sources(for: identity, cachedOnly: true)
        XCTAssertTrue(before.isEmpty)
        let beforeCount = await transport.calls; XCTAssertEqual(beforeCount, 0)
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<12 { group.addTask { await catalog.sources(for: identity, cachedOnly: false) == [self.source] } }
            var total = 0; for await ok in group { if ok { total += 1 } }; return total
        }
        XCTAssertEqual(count, 12)
        do { _ = try await catalog.resolve(network: "near", reference: reference); XCTFail("Artwork invented decimals") }
        catch { XCTAssertEqual(error as? TokenDiscoveryError, .metadataMissing) }
        let calls = await transport.calls; XCTAssertEqual(calls, 1)
        let offlineTransport = ArtworkDirectoryTransport(Data(), status: 503)
        let reopened = TokenDiscoveryCatalog(transport: offlineTransport, directory: directory, seed: seed)
        let saved = await reopened.sources(for: identity, cachedOnly: true)
        XCTAssertEqual(saved, [source])
        let offlineCount = await offlineTransport.calls; XCTAssertEqual(offlineCount, 0)
    }

    func testWrongNetworkContractAndCoinIDCannotSupplyArtwork() async throws {
        for bytes in [try metadata(reference: "different.near"), try metadata(platform: "ethereum"), try metadata(id: "impostor")] {
            let transport = ArtworkDirectoryTransport(bytes)
            let catalog = TokenDiscoveryCatalog(transport: transport, seed: seed)
            let identity = TokenArtworkIdentity(networkID: "near", reference: reference)!
            let result = await catalog.sources(for: identity, cachedOnly: false)
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testArtworkFailureRetainsCooldownAndOptionalAbsenceDoesNotRetry() async throws {
        for transport in [ArtworkDirectoryTransport(Data(), status: 429),
            ArtworkDirectoryTransport(Data(#"{"id":"fixture-token","detail_platforms":{"near-protocol":{"contract_address":"bridge.near"}}}"#.utf8))] {
            let catalog = TokenDiscoveryCatalog(transport: transport, seed: seed)
            let identity = TokenArtworkIdentity(networkID: "near", reference: reference)!
            for _ in 0..<5 {
                let result = await catalog.sources(for: identity, cachedOnly: false)
                XCTAssertTrue(result.isEmpty)
            }
            let calls = await transport.calls; XCTAssertEqual(calls, 1)
        }
    }

    func testArtworkDiagnosticsPreserveFailureAndCorrelationWithoutBodyOrContract() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = ArtworkDiagnosticsCapture(), operation = UUID()
        OathDiagnostics.configure(file: directory.appendingPathComponent("events.json"), transport: capture)
        // Authentication errors remain reportable; 5xx availability errors are
        // deliberately excluded by the shared diagnostics policy.
        let transport = ArtworkDirectoryTransport(Data("private-response-body-fixture".utf8), status: 401)
        let catalog = TokenDiscoveryCatalog(transport: transport, seed: seed)
        let identity = TokenArtworkIdentity(networkID: "near", reference: reference)!
        await OathDiagnostics.$chain.withValue("near") {
            await OathDiagnostics.$operationID.withValue(operation) {
                _ = await catalog.sources(for: identity, cachedOnly: false)
            }
        }
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.operation == "catalog_metadata" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events
        let failure = try XCTUnwrap(events.first { $0.operation == "catalog_metadata" })
        XCTAssertEqual(failure.operationID, operation)
        XCTAssertEqual(failure.context["chain"], "near")
        XCTAssertEqual(failure.context["stage"], "refresh")
        XCTAssertTrue(events.contains { $0.context["http_status"] == "401" })
        let encoded = String(describing: events)
        XCTAssertFalse(encoded.contains(reference)); XCTAssertFalse(encoded.contains("private-response-body-fixture"))
    }

    func testLiveReportedDiscoveryArtworkAndOfflineRelaunch() async throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_REPORTED_DISCOVERY_ARTWORK"] else {
            throw XCTSkip("Opt-in exact public token identities from privacy-filtered source hashes")
        }
        struct Sample: Decodable { let network: String, reference: String, coinID: String, source: String }
        let samples = try JSONDecoder().decode([String: Sample].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(samples.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = PublicArtworkMetadataProbe()
        let catalog = TokenDiscoveryCatalog(transport: metadata, directory: directory.appendingPathComponent("catalog"))
        let images = PublicImageProbe()
        let loader = ArtworkLoader(directory: directory.appendingPathComponent("images"), transport: images,
            fallbackCatalog: ArtworkFallbackCatalog(transport: images))
        let resolver = TokenArtworkResolver(loader: loader, metadata: catalog, directory: directory.appendingPathComponent("identities"))
        await catalog.prefetchArtwork(samples.values.map {
            TokenDiscoveryEntry(network: $0.network, reference: $0.reference, coinID: $0.coinID,
                name: "Public fixture", symbol: "FIXTURE", decimals: nil, logo: nil)
        })
        for (hash, sample) in samples.sorted(by: { $0.value.coinID < $1.value.coinID }) {
            XCTAssertEqual(String(ArtworkSource.key(sample.source).prefix(12)), hash)
            let token = try XCTUnwrap(TokenArtworkIdentity(networkID: sample.network, reference: sample.reference, decimals: 8))
            let image = await resolver.image(for: token, sources: [sample.source])
            let reopened = TokenArtworkResolver(loader: ArtworkLoader(directory: directory.appendingPathComponent("images")),
                metadata: TokenDiscoveryCatalog(transport: ArtworkDirectoryTransport(Data(), status: 503),
                    directory: directory.appendingPathComponent("catalog")), directory: directory.appendingPathComponent("identities"))
            let saved = await reopened.cached(for: token, sources: [])
            let used = await images.urls
            let avoided = !used.contains(sample.source)
            print("REPORTED_ARTWORK \(hash) \(sample.network): decoded=\(image != nil) offline=\(saved != nil) avoided_guess=\(avoided)")
            XCTAssertNotNil(image, hash); XCTAssertNotNil(saved, hash); XCTAssertTrue(avoided, hash)
        }
        print("REPORTED_ARTWORK_PROVIDER_FAILURES \(await images.failures)")
        print("REPORTED_ARTWORK_METADATA_HTTP \(await metadata.statuses)")
    }
}
