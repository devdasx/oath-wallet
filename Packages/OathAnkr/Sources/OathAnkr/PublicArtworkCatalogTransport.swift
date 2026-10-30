import Foundation
import OathArtworkSource
import OathTokenImages

/// Token lists use the same anonymous provider budget as discovery and prices.
/// Keep ArtworkURLTransport's URL/redirect and byte-limit checks. Image CDN
/// downloads retain the image pipeline's separate concurrency and disk cache.
public struct PublicArtworkCatalogTransport: ArtworkTransport {
    private let transport: any ArtworkTransport
    private let requests: PublicMarketRequests

    public init() {
        transport = ArtworkURLTransport()
        requests = .shared
    }

    init(transport: any ArtworkTransport, requests: PublicMarketRequests) {
        self.transport = transport
        self.requests = requests
    }

    public func data(from url: URL) async throws -> Data {
        guard ArtworkSource.permits(url) else { throw ArtworkError.invalidSource }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let transport = transport
        let response = try await requests.send(request) {
            do {
                return .init(data: try await transport.data(from: url), status: 200)
            } catch let limited as ArtworkRateLimit {
                // diagnostics: artwork-http-envelope
                // The raw transport reports HTTP; the catalog records this
                // original typed error after it is restored below. The shared
                // pool must see 429 before releasing queued requests.
                return .init(data: Data(), status: 429, retryAfter: String(limited.delay))
            } catch ArtworkError.http(let status) {
                // diagnostics: artwork-http-envelope
                // Preserve the HTTP code across the common response envelope;
                // raw transport and catalog boundaries retain diagnostics.
                return .init(data: Data(), status: status)
            }
        }
        switch response.status {
        case 200:
            // Another client may have cached this public list under a larger
            // transport budget. Cache reuse must still honor the artwork limit.
            guard response.data.count <= ArtworkSource.byteLimit else { throw ArtworkError.oversized }
            return response.data
        case 429: throw ArtworkRateLimit(retryAfter: response.retryAfter)
        default: throw ArtworkError.http(response.status)
        }
    }
}
