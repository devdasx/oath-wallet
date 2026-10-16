import XCTest
import ImageIO
import SwiftDraw
import OathArtworkSource
import OathDiagnostics
@testable import OathTokenImages

private actor ImageTransport: ArtworkTransport {
    var values: [String: Data]
    var calls: [String: Int] = [:]
    var active = 0
    var peak = 0
    init(_ values: [String: Data]) { self.values = values }
    func set(_ value: Data, for source: String) { values[source] = value }
    func data(from url: URL) async throws -> Data {
        calls[url.absoluteString, default: 0] += 1
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(15))
        guard let value = values[url.absoluteString] else { throw ArtworkError.unavailable }
        return value
    }
}

final class ArtworkTests: XCTestCase, @unchecked Sendable {
    private let source = "https://assets.panora.exchange/tokens/aptos/USD1.png"
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("OathArtwork-" + UUID().uuidString) }
    private func svg(_ body: String = "<path fill='#00aaee' d='M0 0h20v20H0z'/>") -> Data {
        Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'>\(body)</svg>".utf8)
    }

    func testProviderSchemesAndHostsWithoutChainAllowlist() {
        for host in ["assets.panora.exchange", "cache.tonapi.io", "raw.githubusercontent.com", "cdn.suiet.app", "arweave.net", "assets.coingecko.com"] {
            XCTAssertEqual(ArtworkSource.normalized("https://\(host)/icon.svg"), "https://\(host)/icon.svg")
        }
        XCTAssertEqual(ArtworkSource.normalized("http://cdn.example.org/logo.png"), "https://cdn.example.org/logo.png")
        XCTAssertEqual(ArtworkSource.normalized("ipfs://bafyPublicFixture/logo.png"), "https://ipfs.io/ipfs/bafyPublicFixture/logo.png")
        XCTAssertEqual(ArtworkSource.normalized("ipfs://ipfs/bafyPublicFixture/logo.png"), "https://ipfs.io/ipfs/bafyPublicFixture/logo.png")
        XCTAssertEqual(ArtworkSource.normalized("ar://publicFixture"), "https://arweave.net/publicFixture")
    }
    func testUnsafeSourcesAreNotRequested() {
        for value in ["file:///etc/passwd", "javascript:alert(1)", "https://127.0.0.1/a", "https://192.168.1.1/a", "https://[::1]/a", "https://router.local/a", "https://localhost/a", "https://user:password@cdn.example.org/a", "https://cdn.example.org:8443/a", "data:text/html,<html/>"] {
            XCTAssertNil(ArtworkSource.normalized(value), value)
        }
    }
    func testLargeArtworkPreferredWithOriginalFallbackAndDistinctIdentities() {
        let small = "https://coin-images.coingecko.com/coins/images/1/small/bitcoin.png?1"
        XCTAssertEqual(ArtworkSource.candidates([small, small]), [small.replacingOccurrences(of: "/small/", with: "/large/"), small])
        XCTAssertNotEqual(ArtworkSource.key(source), ArtworkSource.key(source + "?revision=2"))
        XCTAssertNotEqual(ArtworkSource.key("https://one.example/TOKEN.png"), ArtworkSource.key("https://two.example/TOKEN.png"))
    }
    func testTonThumbnailUsesOriginalAndKeepsSignedFallback() {
        let origin = "https://tether.to/images/logoCircle.png"
        let encoded = Data(origin.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let proxy = "https://cache.tonapi.io/imgproxy/signature/rs:fill:200:200:1/g:no/" + encoded + ".webp"
        XCTAssertEqual(ArtworkSource.candidates([proxy]), [origin, proxy])
        let forbidden = Data("https://127.0.0.1/private".utf8).base64EncodedString()
        let unsafe = "https://cache.tonapi.io/imgproxy/signature/" + forbidden + ".webp"
        XCTAssertEqual(ArtworkSource.candidates([unsafe]), [unsafe])
    }
    func testOriginalRasterResolutionAndNativeVectorDecoding() throws {
        let data = try fixture("aptos-usd1.png")
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        guard case .raster(let image) = try ArtworkImage.decode(data) else { return XCTFail("Expected original raster") }
        XCTAssertEqual(image.width, properties[kCGImagePropertyPixelWidth] as? Int)
        XCTAssertEqual(image.height, properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertGreaterThanOrEqual(image.width, 100)
        guard case .vector(let vector) = try ArtworkImage.decode(fixture("aptos-usdc.svg")) else { return XCTFail("SVG must remain vector") }
        XCTAssertGreaterThan(vector.size.width, 0)
        // Host CoreGraphics rendering verifies actual color/shape output, not
        // merely that a parser accepted the file. No simulator/window required.
        let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(vector, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan((0..<(512 * 512)).filter { pixels[$0 * 4 + 3] > 0 }.count, 100_000)
        XCTAssertGreaterThan((0..<(512 * 512)).filter { pixels[$0 * 4 + 2] > pixels[$0 * 4] }.count, 50_000, "USDC retains blue artwork")
    }

    func testReportedAptosLogosDecodeFromDiskWithoutNetworkAfterRelaunch() async throws {
        for symbol in ["USDC", "USDT"] {
            let source = "https://assets.panora.exchange/tokens/aptos/\(symbol).svg"
            let expectedHash = symbol == "USDC" ? "321c667b93b3" : "7b294dde57fb"
            XCTAssertEqual(String(ArtworkSource.key(source).prefix(12)), expectedHash)
            let original = try fixture("aptos-\(symbol.lowercased()).svg")
            let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
            let first = ArtworkLoader(directory: dir, transport: ImageTransport([source: original]))
            guard case .vector = await first.image(for: [source]) else { return XCTFail("Public SVG must decode") }
            // Exercise the same stored() decode boundary as the production
            // reports, repeatedly without downloading replacement bytes.
            let offline = ImageTransport([:])
            for _ in 0..<5 {
                let relaunched = ArtworkLoader(directory: dir, transport: offline)
                guard case .vector = await relaunched.image(for: [source]) else { return XCTFail("Saved SVG must decode") }
            }
            let calls = await offline.calls
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testDecodeDiagnosticsDistinguishDocumentSafetyAndDimensionsWithoutContents() throws {
        let marker = "private-document-marker"
        let cases: [(Data, ArtworkDecodeFailure.Stage)] = [
            (Data("<html>\(marker)</html>".utf8), .svgDocument),
            (svg("<script>\(marker)</script>"), .svgSafety),
            (Data("<svg xmlns='http://www.w3.org/2000/svg' width='20000' height='20'/>".utf8), .svgDimensions)
        ]
        var codes = Set<Int>()
        for (data, expected) in cases {
            XCTAssertThrowsError(try ArtworkImage.decode(data)) { error in
                XCTAssertEqual((error as? ArtworkDecodeFailure)?.stage, expected)
                let report = DiagnosticError(error)
                codes.insert(report.code)
                XCTAssertEqual(report.message, expected.rawValue)
                XCTAssertEqual(report.underlying.first?.message, "invalidImage")
                let encoded = try? JSONEncoder().encode(report)
                XCTAssertFalse(String(decoding: encoded ?? Data(), as: UTF8.self).contains(marker))
            }
        }
        XCTAssertEqual(codes.count, cases.count, "Different decode failures must not share a diagnostic fingerprint")
    }
    func testInlineNearStyleArtwork() async throws {
        let data = svg(), uri = "data:image/svg+xml;base64," + data.base64EncodedString()
        XCTAssertEqual(ArtworkSource.inlineData(uri), data)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8)?.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        XCTAssertEqual(ArtworkSource.inlineData("data:image/svg+xml," + encoded), data)
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = ImageTransport([:]), loader = ArtworkLoader(directory: dir, transport: transport)
        let image = await loader.image(for: [uri]), calls = await transport.calls
        XCTAssertNotNil(image); XCTAssertTrue(calls.isEmpty)
    }
    func testUntrustedSVGAndMalformedImagesAreRejected() {
        let invalid = [Data("<html>not an image</html>".utf8), svg("<script>alert(1)</script>"),
            svg("<use href='https://example.org/a.svg'/ >"), svg("<g id='cycle'><use href='#cycle'/></g>"),
            svg("<rect onclick='bad()' width='2' height='2'/>"),
            svg("<style>@import url(https://example.org/a.css)</style>"),
            Data("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg>&x;</svg>".utf8),
            Data(repeating: 0, count: ArtworkSource.byteLimit + 1)]
        for data in invalid { XCTAssertThrowsError(try ArtworkImage.decode(data)) }
        XCTAssertNoThrow(try ArtworkImage.decode(svg("<defs><linearGradient id='g'><stop offset='0' stop-color='red'/></linearGradient></defs><rect width='20' height='20' fill='url(#g)'/>")))
        var expansion = "<g id='n0'><rect width='1' height='1'/></g>"
        for n in 1...20 { expansion += "<g id='n\(n)'><use href='#n\(n-1)'/><use href='#n\(n-1)'/></g>" }
        XCTAssertThrowsError(try ArtworkImage.decode(svg(expansion)))
    }
    func testConcurrentRowsShareOneDownload() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = ImageTransport([source: try fixture("aptos-usd1.png")])
        let loader = ArtworkLoader(directory: dir, transport: transport)
        let success = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<30 { group.addTask { await loader.image(for: [self.source]) != nil } }
            var count = 0; for await value in group { if value { count += 1 } }; return count
        }
        let calls = await transport.calls
        XCTAssertEqual(success, 30); XCTAssertEqual(calls[source], 1)
    }
    func testDownloadsAreBoundedAcrossDifferentIcons() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = svg(), urls = (0..<20).map { "https://cdn.example.org/\($0).svg" }
        let transport = ImageTransport(Dictionary(uniqueKeysWithValues: urls.map { ($0, data) }))
        let loader = ArtworkLoader(directory: dir, transport: transport)
        await withTaskGroup(of: Void.self) { group in
            for url in urls { group.addTask { _ = await loader.image(for: [url]) } }
        }
        let peak = await transport.peak
        XCTAssertLessThanOrEqual(peak, 6); XCTAssertGreaterThan(peak, 1)
    }
    func testPersistentOriginalSurvivesRelaunchAndOfflineRefresh() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try fixture("aptos-usd1.png")
        let first = ArtworkLoader(directory: dir, transport: ImageTransport([source: original]))
        let downloaded = await first.image(for: [source]); XCTAssertNotNil(downloaded)
        let file = dir.appendingPathComponent(ArtworkSource.key(source) + ".artwork")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        XCTAssertEqual(plist["data"] as? Data, original, "Never persist a thumbnail or recompressed image")
        let offline = ImageTransport([:]), second = ArtworkLoader(directory: dir, transport: offline, freshFor: -1)
        let immediate = await second.cached(for: [source]), refreshed = await second.image(for: [source])
        XCTAssertNotNil(immediate); XCTAssertNotNil(refreshed)
        let attempts = await offline.calls; XCTAssertEqual(attempts[source], 1)
    }
    func testFailedDownloadsRetryAndBadPreferredURLFallsBack() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = ImageTransport([:]), loader = ArtworkLoader(directory: dir, transport: transport, retryAfter: 0)
        let first = await loader.image(for: [source]); XCTAssertNil(first)
        await transport.set(try fixture("aptos-usd1.png"), for: source)
        let retry = await loader.image(for: [source]); XCTAssertNotNil(retry)
        let fallback = await loader.image(for: ["https://cdn.example.org/broken.png", source]); XCTAssertNotNil(fallback)
        let calls = await transport.calls; XCTAssertEqual(calls[source], 2)
    }
    func testVectorStaysVectorAfterRelaunchAndCanceledConsumerDoesNotCancelSharedDownload() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = "https://assets.panora.exchange/tokens/aptos/USDC.svg"
        let transport = ImageTransport([url: try fixture("aptos-usdc.svg")])
        let loader = ArtworkLoader(directory: dir, transport: transport)
        let first = Task { await loader.image(for: [url]) }
        try await Task.sleep(for: .milliseconds(2))
        first.cancel()
        let visible = await loader.image(for: [url])
        guard case .vector = visible else { return XCTFail("Shared download must finish for the visible consumer") }
        _ = await first.value
        let calls = await transport.calls; XCTAssertEqual(calls[url], 1)
        let offline = ArtworkLoader(directory: dir, transport: ImageTransport([:]))
        let saved = await offline.cached(for: [url])
        guard case .vector = saved else { return XCTFail("Disk cache must preserve vector artwork") }
    }
    func testCorruptCacheIsRepairedAndOversizedDiskCacheIsPruned() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(ArtworkSource.key(source) + ".artwork")
        try Data("broken".utf8).write(to: file)
        let transport = ImageTransport([source: try fixture("aptos-usd1.png")])
        let loader = ArtworkLoader(directory: dir, transport: transport, diskLimit: 1)
        let result = await loader.image(for: [source]); XCTAssertNotNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let memory = await loader.cached(for: [source]); XCTAssertNotNil(memory)
    }
    func testCooldownAvoidsRepeatedBrokenRequests() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = ImageTransport([source: Data("bad image".utf8)])
        let loader = ArtworkLoader(directory: dir, transport: transport)
        for _ in 0..<10 { let result = await loader.image(for: [source]); XCTAssertNil(result) }
        let calls = await transport.calls; XCTAssertEqual(calls[source], 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(ArtworkSource.key(source) + ".artwork").path))
    }

    func testValidCacheEnvelopeWithInvalidImageIsReplacedAndSurvivesRelaunch() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(ArtworkSource.key(source) + ".artwork")
        // Reproduce cache_read/invalidImage, not just an undecodable plist.
        let corrupt = try PropertyListSerialization.data(fromPropertyList: [
            "data": Data("not an image".utf8), "fetched": Date()
        ], format: .binary, options: 0)
        try corrupt.write(to: file)
        let original = try fixture("aptos-usd1.png")
        let transport = ImageTransport([source: original])
        let loader = ArtworkLoader(directory: dir, transport: transport)
        let cached = await loader.cached(for: [source])
        XCTAssertNil(cached)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let recovered = await loader.image(for: [source])
        XCTAssertNotNil(recovered)
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        XCTAssertEqual(saved["data"] as? Data, original)
        let offline = ImageTransport([:])
        let relaunched = ArtworkLoader(directory: dir, transport: offline)
        let restored = await relaunched.image(for: [source])
        XCTAssertNotNil(restored)
        let calls = await offline.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testInvalidCachedImageAndMissingProviderUseIndependentCandidate() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(ArtworkSource.key(source) + ".artwork")
        try PropertyListSerialization.data(fromPropertyList: [
            "data": Data("not an image".utf8), "fetched": Date()
        ], format: .binary, options: 0).write(to: file)
        let alternative = "https://cdn.example.org/independent.png"
        let transport = ImageTransport([alternative: try fixture("aptos-usd1.png")])
        let loader = ArtworkLoader(directory: dir, transport: transport)
        for _ in 0..<3 {
            let result = await loader.image(for: [source, alternative])
            XCTAssertNotNil(result)
        }
        let calls = await transport.calls
        XCTAssertEqual(calls[source], 1)
        XCTAssertEqual(calls[alternative], 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
