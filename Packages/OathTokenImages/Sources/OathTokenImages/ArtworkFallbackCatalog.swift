import Foundation
import OathArtworkSource
import OathDiagnostics

/// Recovers a missing Trust Wallet image using a published token list. The
/// lookup uses both chain ID and contract, never a ticker or a wallet address.
public actor ArtworkFallbackCatalog {
    public static let shared = ArtworkFallbackCatalog()
    struct Identity: Equatable, Sendable {
        let platform: String
        let chainID: Int
        let networkID: String
        let contract: String
    }
    private struct Entry: Sendable {
        let images: [String: String]
        let fetched: Date
    }
    private let transport: any ArtworkTransport
    private var saved: [String: Entry] = [:]
    private var inflight: [String: Task<Entry?, Never>] = [:]
    private var failed: [String: Date] = [:]

    public init(transport: any ArtworkTransport = ArtworkURLTransport()) {
        self.transport = transport
    }

    func sources(for source: String) async -> [String] {
        guard let identity = Self.identity(source) else { return [] }
        let platform = identity.platform
        if let entry = saved[platform], Date().timeIntervalSince(entry.fetched) < 24 * 3600 {
            return entry.images[identity.contract].map { [$0] } ?? []
        }
        if let failure = failed[platform], Date().timeIntervalSince(failure) < 60 {
            // A known retry cooldown/absent optional logo is not a new failure.
            return saved[platform]?.images[identity.contract].map { [$0] } ?? []
        }
        let task: Task<Entry?, Never>
        if let existing = inflight[platform] { task = existing }
        else {
            let transport = transport
            task = Task {
                await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                    await OathDiagnostics.$chain.withValue(identity.networkID) {
                        do {
                            let url = URL(string: "https://tokens.coingecko.com/\(platform)/all.json")!
                            let data = try await transport.data(from: url)
                            let images = try Self.decode(data, chainID: identity.chainID)
                            return Entry(images: images, fetched: Date())
                        } catch {
                            OathDiagnostics.record(error, component: "artwork", operation: "fallback_catalog",
                                context: ["host": "tokens.coingecko.com"])
                            return nil
                        }
                    }
                }
            }
            inflight[platform] = task
        }
        let entry = await task.value
        inflight[platform] = nil
        if let entry {
            if saved[platform] == nil, saved.count >= 4,
               let oldest = saved.min(by: { $0.value.fetched < $1.value.fetched })?.key {
                saved[oldest] = nil
            }
            saved[platform] = entry
            failed[platform] = nil
        } else { failed[platform] = Date() }
        return saved[platform]?.images[identity.contract].map { [$0] } ?? []
    }

    static func identity(_ source: String) -> Identity? {
        guard let url = URLComponents(string: source), url.scheme == "https",
              url.host == "raw.githubusercontent.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        guard path.count == 8, path[0] == "trustwallet", path[1] == "assets",
              ["master", "main"].contains(path[2]), path[3] == "blockchains",
              path[5] == "assets", path[7] == "logo.png", validContract(path[6]) else { return nil }
        let network: (String, Int, String)
        switch path[4] {
        case "ethereum": network = ("ethereum", 1, "ethereum")
        case "arbitrum": network = ("arbitrum-one", 42161, "arbitrum")
        case "arc": network = ("arc", 5042, "arc")
        case "avalanchec": network = ("avalanche", 43114, "avalanche")
        case "base": network = ("base", 8453, "base")
        case "smartchain": network = ("binance-smart-chain", 56, "bnb")
        case "fantom": network = ("fantom", 250, "fantom")
        case "flare": network = ("flare-network", 14, "flare")
        case "xdai": network = ("xdai", 100, "gnosis")
        case "linea": network = ("linea", 59144, "linea")
        case "optimism": network = ("optimistic-ethereum", 10, "optimism")
        case "monad": network = ("monad", 143, "monad")
        case "unichain": network = ("unichain", 130, "unichain")
        case "hyperevm": network = ("hyperevm", 999, "hyperevm")
        case "robinhood": network = ("robinhood", 4663, "robinhood")
        case "polygon": network = ("polygon-pos", 137, "polygon")
        case "scroll": network = ("scroll", 534352, "scroll")
        case "somnia": network = ("somnia", 5031, "somnia")
        case "story": network = ("story", 1514, "story")
        case "taiko": network = ("taiko", 167000, "taiko")
        case "telos": network = ("telos", 40, "telos")
        case "xlayer": network = ("x-layer", 196, "xlayer")
        default: return nil
        }
        return .init(platform: network.0, chainID: network.1, networkID: network.2,
            contract: path[6].lowercased())
    }

    static func decode(_ data: Data, chainID: Int) throws -> [String: String] {
        struct List: Decodable {
            struct Token: Decodable { let chainId: Int; let address: String; let logoURI: String? }
            let tokens: [Token]
        }
        guard data.count <= ArtworkSource.byteLimit else { throw ArtworkError.oversized }
        let list = try JSONDecoder().decode(List.self, from: data)
        guard !list.tokens.isEmpty, list.tokens.count <= 25_000 else { throw ArtworkError.invalidSource }
        var images: [String: String] = [:]
        for token in list.tokens where token.chainId == chainID {
            guard validContract(token.address) else { throw ArtworkError.invalidSource }
            // Missing/unsafe optional metadata is not evidence of a logo.
            guard let logo = ArtworkSource.normalized(token.logoURI), logo.hasPrefix("https://") else { continue }
            let contract = token.address.lowercased()
            if let existing = images[contract], existing != logo { throw ArtworkError.invalidSource }
            images[contract] = logo
        }
        return images
    }

    private static func validContract(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x") && value.dropFirst(2).utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}
