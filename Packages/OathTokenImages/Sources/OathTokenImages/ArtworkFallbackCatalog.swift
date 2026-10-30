import Foundation
import OathArtworkSource
import OathDiagnostics

/// Recovers a missing Trust Wallet image using a published token list. The
/// lookup uses both chain ID and contract, never a ticker or a wallet address.
public actor ArtworkFallbackCatalog {
    public static let shared = ArtworkFallbackCatalog()
    struct Identity: Equatable, Sendable {
        let platform: String
        let chainID: Int?
        let networkID: String
        let contract: String
    }
    private struct Entry: Sendable {
        let images: [String: String]
        let fetched: Date
        // Conservative string storage plus per-entry dictionary overhead.
        // Budget decoded data, not just a fixed number of networks.
        let memoryCost: Int
        init(images: [String: String], fetched: Date) {
            self.images = images; self.fetched = fetched
            memoryCost = images.reduce(0) { $0 + ($1.key.utf8.count + $1.value.utf8.count) * 2 + 128 }
        }
    }
    private let transport: any ArtworkTransport
    private var saved: [String: Entry] = [:]
    private var inflight: [String: Task<Entry?, Never>] = [:]
    private var failed: [String: Date] = [:]
    private let now: @Sendable () -> Date
    private var providerRetryAt: [String: Date] = [:]
    private var requesting = false
    // One waiter per supported platform at most; same-platform work coalesces.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(transport: any ArtworkTransport = ArtworkURLTransport(),
                now: @escaping @Sendable () -> Date = { .now }) {
        self.transport = transport; self.now = now
    }

    func sources(for source: String) async -> [String] {
        guard let identity = Self.identity(source) else { return [] }
        return await sources(for: identity) ?? []
    }

    /// Artwork-only recovery when the caller knows the token but has no image
    /// URL. nil means unsupported/unavailable; [] means a valid published list
    /// has no image for this identity. Never supplies financial token metadata.
    public func sources(for token: TokenArtworkIdentity) async -> [String]? {
        let directory: String
        switch token.networkID {
        case "bnb": directory = "smartchain"
        case "gnosis": directory = "xdai"
        case "avalanche": directory = "avalanchec"
        default: directory = token.networkID
        }
        // Reuse the existing strict chain/reference parser. This is a lookup
        // key only: no guessed image URL is downloaded or returned to callers.
        let key = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/\(directory)/assets/\(token.reference)/logo.png"
        guard let identity = Self.identity(key), identity.networkID == token.networkID,
              identity.contract == token.reference else { return nil }
        return await sources(for: identity)
    }

    private func sources(for identity: Identity) async -> [String]? {
        let platform = identity.platform
        if let entry = saved[platform], now().timeIntervalSince(entry.fetched) < 24 * 3600 {
            return entry.images[identity.contract].map { [$0] } ?? []
        }
        if failed[platform].map({ now().timeIntervalSince($0) < 60 }) == true {
            // A known retry cooldown/absent optional logo is not a new failure.
            return saved[platform].map { $0.images[identity.contract].map { [$0] } ?? [] }
        }
        let task: Task<Entry?, Never>
        if let existing = inflight[platform] { task = existing }
        else {
            task = Task {
                // Only the task owner clears the flight. Waiters cannot erase a
                // later request after actor reentrancy or cache eviction.
                defer { inflight[platform] = nil }
                return await OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                    await OathDiagnostics.$chain.withValue(identity.networkID) {
                        await load(identity)
                    }
                }
            }
            inflight[platform] = task
        }
        let entry = await task.value
        return entry.map { $0.images[identity.contract].map { [$0] } ?? [] }
    }

    private func load(_ identity: Identity) async -> Entry? {
        await acquireRequest()
        defer { releaseRequest() }
        let platform = identity.platform
        var attempted = false
        for catalog in Self.catalogs(identity) {
            let host = catalog.url.host!
            // A provider cooldown does not block a separately hosted registry.
            // Recheck after the gate; queued networks must not burst at a limited
            // provider. A skipped request is not another diagnostic failure.
            guard now() >= (providerRetryAt[host] ?? .distantPast) else { continue }
            do {
                try Task.checkCancellation()
                attempted = true
                let data = try await transport.data(from: catalog.url)
                try Task.checkCancellation()
                let entry = Entry(images: try Self.decode(data, chainID: identity.chainID,
                    registry: catalog.registry, networkID: identity.networkID), fetched: now())
                retain(entry, platform: platform)
                failed[platform] = nil
                return entry
            } catch {
                // Cancellation is teardown, not a failed provider or permission
                // to start another request. It must not poison the next lookup.
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return saved[platform]
                }
                OathDiagnostics.record(error, component: "artwork", operation: "fallback_catalog",
                    context: ["host": host])
                if let limited = error as? ArtworkRateLimit {
                    providerRetryAt[host] = now().addingTimeInterval(limited.delay)
                } else if error as? ArtworkError == .http(429) {
                    providerRetryAt[host] = now().addingTimeInterval(60)
                }
            }
        }
        if attempted { failed[platform] = now() }
        return saved[platform]
    }

    private static func catalogs(_ identity: Identity) -> [(url: URL, registry: Bool)] {
        // CoinGecko's platform directory does not imply a published free token
        // list: /taiko/all.json returns 403. GlueX publishes an anonymous list
        // keyed by chain ID and contract. Use it only for artwork; its symbols,
        // decimals and verification tags never enter balances or signing.
        if identity.networkID == "taiko" {
            return [(URL(string: "https://raw.githubusercontent.com/gluexprotocol/tokens_registry/main/registry/167000.json")!, true)]
        }
        let primary = (URL(string: "https://tokens.coingecko.com/\(identity.platform)/all.json")!, false)
        // Base has a separately published, contract-keyed artwork registry. Use
        // it only when the primary request fails or is in a host-wide cooldown.
        // No per-token API calls, symbol matching, or wallet metadata is needed.
        if identity.networkID == "base" {
            return [primary, (URL(string: "https://raw.githubusercontent.com/gluexprotocol/tokens_registry/main/registry/8453.json")!, true)]
        }
        return [primary]
    }

    private func retain(_ entry: Entry, platform: String) {
        // Cross-network searches need cached lists from multiple networks.
        // Evict by memory usage rather than network count to retain fresh lists
        // and keep cached logo lookups available during rate limiting.
        // Keep all supported networks while bounding estimated memory to 24 MiB.
        let limit = 24 * 1024 * 1024
        guard entry.memoryCost <= limit else { return } // Valid but too large to retain; not a download failure.
        saved[platform] = nil
        while saved.values.reduce(0, { $0 + $1.memoryCost }) + entry.memoryCost > limit,
              let oldest = saved.min(by: { $0.value.fetched < $1.value.fetched })?.key {
            saved[oldest] = nil
        }
        saved[platform] = entry
    }

    private func acquireRequest() async {
        if !requesting { requesting = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func releaseRequest() {
        if waiting.isEmpty { requesting = false }
        else { waiting.removeFirst().resume() }
    }

    static func identity(_ source: String) -> Identity? {
        guard let url = URLComponents(string: source), url.scheme == "https",
              url.host == "raw.githubusercontent.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        guard path.count == 8, path[0] == "trustwallet", path[1] == "assets",
              ["master", "main"].contains(path[2]), path[3] == "blockchains",
              path[5] == "assets", path[7] == "logo.png" else { return nil }
        let network: (String, Int?, String)
        switch path[4] {
        case "solana": network = ("solana", nil, "solana")
        case "near": network = ("near-protocol", nil, "near")
        case "stellar": network = ("stellar", nil, "stellar")
        case "sui": network = ("sui", nil, "sui")
        case "tron": network = ("tron", nil, "tron")
        case "ton": network = ("the-open-network", nil, "ton")
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
        case "chiliz": network = ("chiliz", 88888, "chiliz")
        case "iotex": network = ("iotex", 4689, "iotex")
        case "zerog": network = ("0g", 16661, "zerog")
        case "sei": network = ("sei-v2", 1329, "sei")
        case "filecoin": network = ("filecoin", 314, "filecoin")
        case "celo": network = ("celo", 42220, "celo")
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
        guard let reference = canonicalReference(path[6], chainID: network.1, networkID: network.2) else { return nil }
        return .init(platform: network.0, chainID: network.1, networkID: network.2, contract: reference)
    }

    static func decode(_ data: Data, chainID: Int?, registry: Bool = false, networkID: String = "solana") throws -> [String: String] {
        struct List: Decodable {
            struct Token: Decodable { let chainId: Int?; let address: String; let logoURI: String? }
            let tokens: [Token]
        }
        guard data.count <= ArtworkSource.byteLimit else { throw ArtworkError.oversized }
        guard !registry || chainID != nil else { throw ArtworkError.invalidSource }
        // The selected provider determines the envelope. Do not reinterpret a
        // malformed response as an alternate format and silently accept it.
        let tokens = try registry ? JSONDecoder().decode([List.Token].self, from: data)
            : JSONDecoder().decode(List.self, from: data).tokens
        guard !tokens.isEmpty, tokens.count <= 25_000 else { throw ArtworkError.invalidSource }
        var images: [String: String] = [:]
        for token in tokens where token.chainId == chainID {
            guard let contract = canonicalReference(token.address, chainID: chainID, networkID: networkID) else {
                // A published non-EVM list can include unsupported optional
                // representations (such as a Sui object rather than a coin type).
                // Never infer their identity or discard valid rows alongside them.
                if chainID == nil, networkID != "solana" { continue }
                throw ArtworkError.invalidSource
            }
            // Missing/unsafe optional metadata is not evidence of a logo.
            guard let logo = ArtworkSource.normalized(token.logoURI), logo.hasPrefix("https://") else { continue }
            if let existing = images[contract], existing != logo { throw ArtworkError.invalidSource }
            images[contract] = logo
        }
        return images
    }

    /// Null chain IDs belong only to an explicitly selected non-EVM catalog.
    /// These public identifiers select artwork only; no scale, balance, address
    /// ownership or signing input is taken from a list. Preserve case wherever
    /// the chain's token identity is case-sensitive.
    private static func canonicalReference(_ value: String, chainID: Int?, networkID: String) -> String? {
        if chainID != nil { return validContract(value) ? value.lowercased() : nil }
        guard value.utf8.count <= 512 else { return nil }
        switch networkID {
        case "solana": return validSolanaMint(value) ? value : nil
        case "ton": return TonArtworkAddress.raw(value)
        case "near":
            return (2...64).contains(value.utf8.count) && matches(value, "[a-z0-9]+(?:[._-][a-z0-9]+)*") ? value : nil
        case "stellar":
            return matches(value, "(?:C[A-Z2-7]{55}|[a-zA-Z0-9]{1,12}-G[A-Z2-7]{55})") ? value : nil
        case "tron":
            return matches(value, "(?:T[1-9A-HJ-NP-Za-km-z]{33}|[1-9][0-9]{5,9})") ? value : nil
        case "sui":
            guard matches(value, "0x[0-9a-fA-F]{1,64}::[a-zA-Z_][a-zA-Z0-9_]*::[a-zA-Z_][a-zA-Z0-9_]*") else { return nil }
            let parts = value.components(separatedBy: "::")
            let hex = String(parts[0].dropFirst(2)).lowercased()
            return "0x" + String(repeating: "0", count: 64 - hex.count) + hex + "::" + parts[1] + "::" + parts[2]
        default: return nil
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }

    private static func validSolanaMint(_ value: String) -> Bool {
        guard (32...44).contains(value.utf8.count) else { return false }
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
        var bytes = [UInt8]()
        for character in value.utf8 {
            guard let digit = alphabet.firstIndex(of: character) else { return false }
            var carry = digit
            for index in bytes.indices {
                carry += Int(bytes[index]) * 58
                bytes[index] = UInt8(carry & 255)
                carry >>= 8
            }
            while carry > 0 { bytes.append(UInt8(carry & 255)); carry >>= 8 }
            guard bytes.count <= 32 else { return false }
        }
        return bytes.count + value.utf8.prefix(while: { $0 == 49 }).count == 32
    }

    private static func validContract(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x") && value.dropFirst(2).utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}
