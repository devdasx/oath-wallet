import XCTest
@testable import OathAnkr

private actor BatchArtworkTransport: AnkrTransport {
    var batches: [[String]] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let refs = request.url!.lastPathComponent.split(separator: ",").map(String.init)
        batches.append(refs)
        let rows = refs.map { ref in
            ["id": "sui-network_" + ref, "type": "token", "attributes": ["address": ref, "image_url": "https://cdn.example.org/token.png"]] as [String: Any]
        }
        return (try JSONSerialization.data(withJSONObject: ["data": rows]), status)
    }
}

final class TokenBatchArtworkTests: XCTestCase, @unchecked Sendable {
    private func entry(_ index: Int) throws -> TokenDiscoveryEntry {
        let ref = try TokenDiscoveryNetworks.canonical("0x\(String(index, radix: 16))::coin::TOKEN", network: "sui")
        return .init(network: "sui", reference: ref, coinID: "fixture", name: "Token", symbol: "TKN", decimals: nil, logo: nil)
    }
    func testSearchBatchDeduplicatesChunksAndCachesKnownAndUnknownDecimals() async throws {
        let transport = BatchArtworkTransport()
        let catalog = TokenBatchArtwork(transport: transport, spacing: .zero)
        let entries = try (1...31).map(entry)
        await catalog.prefetch(entries + entries)
        await catalog.prefetch(entries)
        for entry in entries {
            let source = await catalog.source(for: entry, cachedOnly: false)
            XCTAssertEqual(source, "https://cdn.example.org/token.png")
        }
        let requests = await transport.batches
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.count).sorted(), [1, 30])
        let known = TokenDiscoveryEntry(network: entries[0].network, reference: entries[0].reference,
            coinID: "fixture", name: "Token", symbol: "TKN", decimals: 9, logo: nil)
        let cached = await catalog.source(for: known, cachedOnly: true)
        XCTAssertNotNil(cached)
        let after = await transport.batches.count
        XCTAssertEqual(after, 2)
    }
    func testProviderRateLimitStopsQueuedAndNewBatches() async throws {
        let transport = BatchArtworkTransport(status: 429)
        let catalog = TokenBatchArtwork(transport: transport, spacing: .zero)
        let entries = try (1...60).map(entry)
        await catalog.prefetch(entries)
        for entry in entries { _ = await catalog.source(for: entry, cachedOnly: false) }
        let requests = await transport.batches.count
        XCTAssertEqual(requests, 1)
    }
    func testNoWrongNetworkWrongAddressDuplicateOrUnsafeImageCanSupplyArtwork() throws {
        let entry = try entry(1)
        func data(id: String, ref: String, image: String? = "https://cdn.example.org/token.png", duplicate: Bool = false) throws -> Data {
            let row: [String: Any] = ["id": id, "type": "token", "attributes": ["address": ref, "image_url": image as Any? ?? NSNull()]]
            return try JSONSerialization.data(withJSONObject: ["data": duplicate ? [row, row] : [row]])
        }
        let ref = entry.reference
        XCTAssertThrowsError(try TokenBatchArtwork.decode(data(id: "solana_" + ref, ref: ref), network: "sui", requested: [ref]))
        let other = try self.entry(2).reference
        XCTAssertThrowsError(try TokenBatchArtwork.decode(data(id: "sui-network_" + other, ref: other), network: "sui", requested: [ref]))
        XCTAssertThrowsError(try TokenBatchArtwork.decode(data(id: "sui-network_" + ref, ref: ref, duplicate: true), network: "sui", requested: [ref, other]))
        for image: String? in [nil, "http://127.0.0.1/x", "file:///private/file", "https://user:password@cdn.example.org/x"] {
            XCTAssertEqual(try TokenBatchArtwork.decode(data(id: "sui-network_" + ref, ref: ref, image: image), network: "sui", requested: [ref]), [:])
        }
    }
}
