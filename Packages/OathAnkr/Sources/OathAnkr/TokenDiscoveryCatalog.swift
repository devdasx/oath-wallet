import Foundation
import OathDiagnostics

/// Discovery metadata, not a safety endorsement, balance, or permission to sign.
/// Identity always includes the network and its canonical contract/issuer/mint.
public struct TokenDiscoveryEntry: Codable, Sendable, Equatable, Identifiable {
    public let network: String
    public let reference: String
    public let coinID: String
    public let name: String
    public let symbol: String
    public let decimals: Int?
    public let logo: String?
    public var id: String { network + ":" + reference }
}

public enum TokenDiscoveryError: Error, Equatable, Sendable { case malformed, unavailable, metadataMissing, http(Int) }

public enum TokenDiscoveryNetworks {
    /// Native-only networks are searched through the portfolio, not fabricated
    /// token contracts. BCH token-bearing UTXOs are not spendable token assets.
    public static let nativeOnly: Set<String> = ["bitcoin", "bitcoincash", "dogecoin", "litecoin"]
    public static let platforms: [String: String] = [
        "ethereum": "ethereum", "arbitrum": "arbitrum-one", "arc": "arc",
        "avalanche": "avalanche", "base": "base", "bnb": "binance-smart-chain",
        "fantom": "fantom", "flare": "flare-network", "gnosis": "xdai", "linea": "linea",
        "optimism": "optimistic-ethereum", "polygon": "polygon-pos", "monad": "monad",
        "unichain": "unichain", "iotex": "iotex", "zerog": "0g", "sei": "sei-v2", "filecoin": "filecoin", "chiliz": "chiliz", "celo": "celo", "hyperevm": "hyperevm", "robinhood": "robinhood",
        "scroll": "scroll", "somnia": "somnia", "story": "story", "taiko": "taiko",
        "telos": "telos", "xlayer": "x-layer", "tron": "tron", "solana": "solana",
        "aptos": "aptos", "near": "near-protocol", "polkadot": "polkadot", "stellar": "stellar", "sui": "sui",
        "ton": "the-open-network", "xrpl": "xrp", "thorchain": "thorchain"
    ]
    static let networksByPlatform = Dictionary(uniqueKeysWithValues: platforms.map { ($0.value, $0.key) })

    /// These ERC-20 interfaces expose the coin already shown by the portfolio.
    /// Match exact chain/contract identity, never a token's name or symbol.
    public static func isNativeRepresentation(_ reference: String, network: String) -> Bool {
        let address = reference.lowercased()
        return (network == "arc" && address == "0x3600000000000000000000000000000000000000") ||
            (network == "celo" && address == IndexedEVMChain.celo.nativeERC20)
    }

    public static func canonical(_ value: String, network: String) throws -> String {
        guard value.utf8.count <= 4096 else { throw TokenDiscoveryError.malformed }
        switch network {
        case "iotex": return try IoTeXIdentity.ethereum(value)
        case "filecoin": return try FilecoinIdentity.ethereum(value)
        case "polkadot": return try PolkadotIdentity.reference(value)
        case "aptos": return try AptosIdentity.reference(value)
        case "near": return try NearIdentity.reference(value)
        case "sui": return try SuiIdentity.reference(value)
        case "ton": return try TonIdentity.raw(value)
        case "tron": return try TronIdentity.address(value)
        case "solana":
            guard SolanaIdentity.isAddress(value) else { throw TokenDiscoveryError.malformed }
            return value
        case "stellar":
            if let ref = try? StellarIdentity.reference(value) { return ref }
            let parts = value.replacingOccurrences(of: ":", with: "-").split(separator: "-")
            guard parts.count == 2 else { throw TokenDiscoveryError.malformed }
            return try StellarIdentity.contract(code: String(parts[0]), issuer: String(parts[1]))
        case "xrpl":
            if let ref = try? XrplIdentity.reference(value) { return ref }
            guard let dot = value.lastIndex(of: ".") else { throw TokenDiscoveryError.malformed }
            let bytes = Array(value[..<dot].utf8)
            guard (4...20).contains(bytes.count) else { throw TokenDiscoveryError.malformed }
            let code = (bytes + Array(repeating: 0, count: 20 - bytes.count)).map { String(format: "%02X", $0) }.joined()
            return try XrplIdentity.reference(code + value[dot...])
        case "thorchain": return try ThorchainIdentity.reference(value)
        default:
            guard platforms[network] != nil else { throw TokenDiscoveryError.malformed }
            let address = try EVMSendIdentity.address(value)
            return isNativeRepresentation(address, network: network) ? "native" : address
        }
    }
}

/// All I/O, decoding, normalization and searching execute on this actor, never
/// MainActor. Search reads local data only. Refresh is independent of navigation.
public actor TokenDiscoveryCatalog {
    public static let shared = TokenDiscoveryCatalog()
    public static let refreshInterval: TimeInterval = 86_400
    private struct Coin: Decodable {
        let id: String, name: String, symbol: String
        let platforms: [String: String?]?
    }
    private struct IndexRow: Sendable {
        let entry: TokenDiscoveryEntry
        let name: String, symbol: String
    }
    private struct PreparedSnapshot: Codable {
        let format: Int
        let entries: [TokenDiscoveryEntry]
    }
    private struct Disk: Codable {
        let version: Int
        let fetchedAt: Date
        let retryAt: Date
        let data: Data
    }
    private struct Detail: Codable, Sendable {
        struct Platform: Codable, Sendable { let decimal_place: Int?; let contract_address: String? }
        struct Image: Codable, Sendable { let small: String? }
        let id: String
        let detail_platforms: [String: Platform]?
        let image: Image?
    }
    private struct CachedDetail: Codable { let date: Date; let detail: Detail }
    private static func boundedDetail(_ detail: Detail) throws -> Detail {
        guard validCoinID(detail.id) else { throw TokenDiscoveryError.malformed }
        var platforms: [String: Detail.Platform] = [:]
        // Never retain the complete provider object for every cached coin.
        // Only the app's supported platforms and bounded public metadata are needed.
        for platform in TokenDiscoveryNetworks.platforms.values {
            guard let row = detail.detail_platforms?[platform],
                  let address = row.contract_address, !address.isEmpty, address.utf8.count <= 4096 else { continue }
            platforms[platform] = .init(decimal_place: row.decimal_place.flatMap { (0...255).contains($0) ? $0 : nil },
                contract_address: address)
        }
        let image = detail.image?.small.flatMap { value -> String? in
            value.utf8.count <= 2048 && URL(string: value)?.scheme == "https" ? value : nil
        }
        return .init(id: detail.id, detail_platforms: platforms, image: .init(small: image))
    }
    private let transport: any AnkrTransport
    private let directory: URL?
    private let seed: Data?
    private let batchArtwork: TokenBatchArtwork?
    private var loaded = false
    private var rows: [IndexRow] = []
    private var identities: [String: TokenDiscoveryEntry] = [:]
    private var assetHubEntries: [TokenDiscoveryEntry] = []
    private var sourceData = Data()
    private var fetchedAt = Date.distantPast
    private var retryAt = Date.distantPast
    private var refreshFlight: Task<Bool, Never>?
    private var detailFlights: [String: Task<Data, Error>] = [:]
    private var details: [String: (Date, Detail)] = [:]
    private var detailRetryAt = Date.distantPast

    public init(transport: any AnkrTransport = AnkrHTTPTransport(), directory: URL? = nil, seed: Data? = nil) {
        self.transport = transport
        self.directory = directory
        self.seed = seed
        batchArtwork = seed == nil ? TokenBatchArtwork(transport: transport) : nil
    }

    private var cacheURL: URL? {
        let folder = directory ?? (seed == nil ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("OathTokenDiscovery", isDirectory: true) : nil)
        return folder?.appendingPathComponent("catalog-v1.json")
    }
    private var metadataURL: URL? { cacheURL?.deletingLastPathComponent().appendingPathComponent("metadata-v1.json") }

    public static func decode(_ data: Data) throws -> [TokenDiscoveryEntry] {
        guard data.count <= 16_000_000 else { throw TokenDiscoveryError.malformed }
        let coins = try JSONDecoder().decode([Coin].self, from: data)
        guard !coins.isEmpty, coins.count <= 100_000 else { throw TokenDiscoveryError.malformed }
        var entries: [String: TokenDiscoveryEntry] = [:], ambiguous = Set<String>()
        for coin in coins {
            guard validCoinID(coin.id), let name = ContractIdentity.clean(coin.name),
                  let symbol = ContractIdentity.clean(coin.symbol), symbol.utf8.count <= 64 else { continue }
            for (platform, optionalAddress) in coin.platforms ?? [:] {
                // diagnostics: discovery-optional-listing. Unsupported platforms,
                // missing contracts and invalid optional listings are not RPC failures.
                guard let network = TokenDiscoveryNetworks.networksByPlatform[platform],
                      let address = optionalAddress, !address.isEmpty,
                      let ref = try? TokenDiscoveryNetworks.canonical(address, network: network), ref != "native" else { continue }
                let entry = TokenDiscoveryEntry(network: network, reference: ref, coinID: coin.id,
                    name: name, symbol: symbol.uppercased(), decimals: protocolDecimals(network, address), logo: nil)
                if let old = entries[entry.id], old.coinID != coin.id { ambiguous.insert(entry.id) }
                else { entries[entry.id] = entry }
            }
        }
        // A provider conflict must not pick an arbitrary coin's metadata.
        for id in ambiguous { entries.removeValue(forKey: id) }
        guard !entries.isEmpty, entries.count <= 100_000 else { throw TokenDiscoveryError.malformed }
        return entries.values.sorted { $0.id < $1.id }
    }

    /// Build tooling and successful refreshes canonicalize the full directory
    /// once. Cold launches decode these already-normalized public identities,
    /// instead of redoing thousands of Base58/issuer/Move conversions.
    public static func prepareSnapshot(_ data: Data) throws -> Data {
        try JSONEncoder().encode(PreparedSnapshot(format: 1, entries: decode(data)))
    }

    private static func readPrepared(_ data: Data) throws -> [TokenDiscoveryEntry] {
        guard data.count <= 16_000_000 else { throw TokenDiscoveryError.malformed }
        let snapshot = try JSONDecoder().decode(PreparedSnapshot.self, from: data)
        guard snapshot.format == 1, !snapshot.entries.isEmpty, snapshot.entries.count <= 100_000 else { throw TokenDiscoveryError.malformed }
        var seen: Set<String> = []
        for entry in snapshot.entries {
            guard TokenDiscoveryNetworks.platforms[entry.network] != nil, validCoinID(entry.coinID),
                  !entry.reference.isEmpty, entry.reference != "native", entry.reference.utf8.count <= 4096,
                  ContractIdentity.clean(entry.name) == entry.name,
                  ContractIdentity.clean(entry.symbol) == entry.symbol, entry.symbol.utf8.count <= 64,
                  entry.decimals == nil || (0...255).contains(entry.decimals!), seen.insert(entry.id).inserted else { throw TokenDiscoveryError.malformed }
        }
        // Old bundled/downloaded snapshots were normalized before Celo support.
        // Native aliases are expected duplicate metadata, not provider failures.
        return snapshot.entries.filter {
            !TokenDiscoveryNetworks.isNativeRepresentation($0.reference, network: $0.network)
        }
    }

    private static func validCoinID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200 && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    private static func protocolDecimals(_ network: String, _ reference: String) -> Int? {
        if network == "xrpl", reference.contains(".") { return XrplIdentity.issuedScale }
        if network == "stellar", reference.contains("-") || reference.contains(":") { return 7 }
        if network == "thorchain", ThorchainIdentity.hasProtocolDecimals(reference) { return 8 }
        return nil
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func install(_ data: Data) throws {
        let prepared = data.first == 123
        var entries = try prepared ? Self.readPrepared(data) : Self.decode(data)
        // Asset Hub's issuer-registered assets are independent of CoinGecko's
        // directory coverage. Preserve these exact bundled pallet identities
        // when a successful directory refresh omits one of them.
        let supplied = Set(entries.map(\.id))
        let registered = Dictionary(uniqueKeysWithValues: assetHubEntries.map { ($0.id, $0) })
        entries = entries.map { entry in
            guard let known = registered[entry.id], known.coinID == entry.coinID else { return entry }
            return .init(network: entry.network, reference: entry.reference, coinID: entry.coinID,
                name: entry.name, symbol: entry.symbol, decimals: entry.decimals ?? known.decimals,
                logo: entry.logo ?? known.logo)
        }
        entries += assetHubEntries.filter { !supplied.contains($0.id) }
        entries.sort { $0.id < $1.id }
        rows = entries.map { IndexRow(entry: $0, name: Self.fold($0.name), symbol: Self.fold($0.symbol)) }
        identities = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        sourceData = try JSONEncoder().encode(PreparedSnapshot(format: 1, entries: entries))
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        var bundledData: Data?
        do {
            if let seed { bundledData = seed }
            else {
                guard let url = Bundle.module.url(forResource: "TokenDiscoverySeed", withExtension: "json") else { throw TokenDiscoveryError.unavailable }
                bundledData = try Data(contentsOf: url)
            }
            if let data = bundledData {
                let bundled = try data.first == 123 ? Self.readPrepared(data) : Self.decode(data)
                assetHubEntries = bundled.filter { $0.network == "polkadot" && ["assets:1337", "assets:1984"].contains($0.reference) }
            }
        } catch { OathDiagnostics.record(error, component: "token_discovery", operation: "seed_read") }
        if let url = cacheURL, FileManager.default.fileExists(atPath: url.path) {
            do {
                guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 24_000_000 else { throw TokenDiscoveryError.malformed }
                let disk = try JSONDecoder().decode(Disk.self, from: Data(contentsOf: url))
                guard disk.version == 1, disk.fetchedAt <= Date().addingTimeInterval(300), disk.retryAt <= Date().addingTimeInterval(Self.refreshInterval) else { throw TokenDiscoveryError.malformed }
                try install(disk.data); fetchedAt = disk.fetchedAt; retryAt = disk.retryAt
            } catch { OathDiagnostics.record(error, component: "token_discovery", operation: "cache_read") }
        }
        // A valid cache from an older release can predate a newly supported
        // network. Supplement only absent networks; never resurrect removed
        // listings or replace fresher metadata on networks already cached.
        let missingNetworks = Set(TokenDiscoveryNetworks.platforms.keys)
            .subtracting(identities.values.map(\.network))
        if !missingNetworks.isEmpty {
            do {
                guard let data = bundledData else { return }
                if rows.isEmpty {
                    try install(data)
                } else {
                    let bundled = try data.first == 123 ? Self.readPrepared(data) : Self.decode(data)
                    let additions = bundled.filter { missingNetworks.contains($0.network) }
                    if !additions.isEmpty {
                        let entries = (Array(identities.values) + additions).sorted { $0.id < $1.id }
                        try install(JSONEncoder().encode(PreparedSnapshot(format: 1, entries: entries)))
                        fetchedAt = .distantPast
                        persist()
                    }
                }
            } catch { OathDiagnostics.record(error, component: "token_discovery", operation: "seed_read") }
        }
        // Common-token metadata keeps first-use adding available offline too.
        if seed == nil {
            do {
                guard let url = Bundle.module.url(forResource: "TokenDiscoveryDetails", withExtension: "json") else { throw TokenDiscoveryError.unavailable }
                for detail in try JSONDecoder().decode([Detail].self, from: Data(contentsOf: url)) {
                    details[detail.id] = (.distantPast, try Self.boundedDetail(detail))
                }
            } catch { OathDiagnostics.record(error, component: "token_discovery", operation: "seed_metadata") }
        }
        if let url = metadataURL, FileManager.default.fileExists(atPath: url.path) {
            do {
                guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 4_000_000 else { throw TokenDiscoveryError.malformed }
                let saved = try JSONDecoder().decode([CachedDetail].self, from: Data(contentsOf: url))
                guard saved.count <= 256 else { throw TokenDiscoveryError.malformed }
                for row in saved where row.date <= Date().addingTimeInterval(300) && Date().timeIntervalSince(row.date) < 30 * Self.refreshInterval {
                    if Self.validCoinID(row.detail.id) { details[row.detail.id] = (row.date, try Self.boundedDetail(row.detail)) }
                }
            } catch { OathDiagnostics.record(error, component: "token_discovery", operation: "metadata_cache_read") }
        }
    }

    /// Bounded result count with a best match reserved for every matching network.
    /// Saved-token filtering uses full identities, never hides an entire network.
    public func search(_ raw: String, networks: Set<String>, excluding: Set<String> = [], limit: Int = 200) -> [TokenDiscoveryEntry] {
        load()
        let query = Self.fold(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty, query.utf8.count <= 4096 else { return [] }
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let references = Dictionary(uniqueKeysWithValues: networks.compactMap { network -> (String, String)? in
            guard let ref = try? TokenDiscoveryNetworks.canonical(raw, network: network) else { return nil }
            return (network, ref)
        })
        var matches: [(Int, IndexRow)] = []
        for row in rows where networks.contains(row.entry.network) && !excluding.contains(row.entry.id) {
            let exactAddress = references[row.entry.network] == row.entry.reference
            let rank: Int
            if exactAddress { rank = 0 }
            else if row.symbol == query { rank = 1 }
            else if row.name == query { rank = 2 }
            else if row.symbol.hasPrefix(query) { rank = 3 }
            else if words.allSatisfy({ row.name.contains($0) || row.symbol.contains($0) || row.entry.network.contains($0) }) { rank = 4 }
            else { continue }
            matches.append((rank, row))
        }
        matches.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.name != b.1.name { return a.1.name < b.1.name }
            return a.1.entry.id < b.1.entry.id
        }
        var selected: Set<String> = [], seenNetworks: Set<String> = []
        for (_, row) in matches where seenNetworks.insert(row.entry.network).inserted { selected.insert(row.entry.id) }
        let cap = max(selected.count, min(max(limit, 1), 500))
        for (_, row) in matches where selected.count < cap { selected.insert(row.entry.id) }
        let results = matches.filter { selected.contains($0.1.entry.id) }.map { enriched($0.1.entry) }
        // Search/navigation never waits for artwork. Reserve whole batches so
        // visible rows share one response rather than one coin API call each.
        if let batchArtwork {
            let missing = results.filter { $0.logo == nil }
            Task(priority: .utility) { await batchArtwork.prefetch(missing) }
        }
        return results
    }

    /// Returns whether a fresh index was installed. Cancellation of a search
    /// waiter does not cancel the shared catalog download or other consumers.
    public func refreshIfNeeded() async -> Bool {
        load()
        if let flight = refreshFlight { return await flight.value }
        guard Date().timeIntervalSince(fetchedAt) >= Self.refreshInterval, Date() >= retryAt else { return false }
        let flight = Task(priority: .utility) { await self.refresh() }
        refreshFlight = flight
        return await flight.value
    }

    /// Reused by source-level integration checks without opening a screen.
    /// Prefetch only identities already present in the catalog.
    func prefetchArtwork(_ entries: [TokenDiscoveryEntry]) async {
        load()
        let known = entries.prefix(500).compactMap { identities[$0.id] }.map(enriched).filter { $0.logo == nil }
        await batchArtwork?.prefetch(known)
    }

    private func refresh() async -> Bool {
        defer { refreshFlight = nil }
        return await OathDiagnostics.$operationID.withValue(UUID()) {
            do {
                let data = try await read("https://api.coingecko.com/api/v3/coins/list?include_platform=true")
                try install(data); fetchedAt = .now; retryAt = .distantPast
                persist(); return true
            } catch {
                OathDiagnostics.record(error, component: "token_discovery", operation: "catalog_refresh")
                retryAt = Date().addingTimeInterval(1800); persist(); return false
            }
        }
    }

    private func persist() {
        guard let url = cacheURL, !sourceData.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Disk(version: 1, fetchedAt: fetchedAt, retryAt: retryAt, data: sourceData)).write(to: url, options: .atomic)
        } catch { OathDiagnostics.record(error, component: "token_discovery", operation: "cache_write") }
    }

    private func enriched(_ entry: TokenDiscoveryEntry) -> TokenDiscoveryEntry {
        guard let detail = details[entry.coinID]?.1,
              let platform = TokenDiscoveryNetworks.platforms[entry.network], let row = detail.detail_platforms?[platform],
              let address = row.contract_address,
              (try? TokenDiscoveryNetworks.canonical(address, network: entry.network)) == entry.reference else { return entry }
        let decimals = entry.decimals ?? row.decimal_place.flatMap { (0...255).contains($0) ? $0 : nil }
        return .init(network: entry.network, reference: entry.reference, coinID: entry.coinID,
            name: entry.name, symbol: entry.symbol, decimals: decimals,
            logo: detail.image?.small.flatMap { URL(string: $0)?.scheme == "https" ? $0 : nil } ?? entry.logo)
    }

    /// Only selected-token metadata is requested; one coin response covers its
    /// deployments on every network. No wallet address or search text is sent.
    public func resolve(network: String, reference: String) async throws -> TokenDiscoveryEntry {
        load()
        let ref = try TokenDiscoveryNetworks.canonical(reference, network: network)
        guard let entry = identities[network + ":" + ref] else { throw TokenDiscoveryError.metadataMissing }
        let cached = enriched(entry)
        if cached.decimals != nil { return cached }
        try await loadDetail(for: entry)
        let result = enriched(entry)
        guard result.decimals != nil else { throw TokenDiscoveryError.metadataMissing }
        return result
    }

    /// Exact catalog identity is sufficient for artwork. Missing decimals remain
    /// unknown; this method cannot add a token or construct market/send metadata.
    public func artworkSource(network: String, reference: String, cachedOnly: Bool) async throws -> String? {
        load()
        let ref = try TokenDiscoveryNetworks.canonical(reference, network: network)
        guard let entry = identities[network + ":" + ref] else { return nil }
        if let logo = enriched(entry).logo { return logo }
        if let logo = await batchArtwork?.source(for: entry, cachedOnly: cachedOnly) { return logo }
        guard !cachedOnly else { return nil }
        try await loadDetail(for: entry)
        return enriched(entry).logo
    }

    private func loadDetail(for entry: TokenDiscoveryEntry) async throws {
        // A successful response without optional decimals is a cached absence,
        // not a reason to repeat the same request on every tap.
        if let checked = details[entry.coinID]?.0, Date().timeIntervalSince(checked) < Self.refreshInterval {
            return
        }
        guard Date() >= detailRetryAt else { throw DiagnosticDeferral.tokenMetadataCooldown }
        let task: Task<Data, Error>
        if let flight = detailFlights[entry.coinID] { task = flight }
        else {
            guard detailFlights.count < 4 else { throw DiagnosticDeferral.tokenMetadataCapacity }
            task = Task { try await self.read("https://api.coingecko.com/api/v3/coins/" + entry.coinID + "?localization=false&tickers=false&market_data=false&community_data=false&developer_data=false") }
            detailFlights[entry.coinID] = task
        }
        do {
            let data = try await task.value
            let detail = try Self.boundedDetail(JSONDecoder().decode(Detail.self, from: data))
            guard detail.id == entry.coinID else { throw TokenDiscoveryError.malformed }
            details[entry.coinID] = (.now, detail); detailFlights[entry.coinID] = nil
            if details.count > 256, let oldest = details.min(by: { $0.value.0 < $1.value.0 })?.key { details.removeValue(forKey: oldest) }
            persistMetadata()
            return
        } catch {
            detailFlights[entry.coinID] = nil
            if case TokenDiscoveryError.metadataMissing = error {
                // Successful optional-metadata absence is cached above. Other
                // tokens remain resolvable; no provider-wide penalty applies.
            } else { detailRetryAt = Date().addingTimeInterval(60) }
            if case TokenDiscoveryError.metadataMissing = error {
                // diagnostics: discovery-optional-listing. Missing optional
                // directory decimals fall through to the selected chain client.
            } else { OathDiagnostics.record(error, component: "token_discovery", operation: "token_metadata", context: ["chain": entry.network]) }
            throw error
        }
    }

    private func persistMetadata() {
        guard let url = metadataURL else { return }
        do {
            let values = details.values.map { CachedDetail(date: $0.0, detail: $0.1) }
            let data = try JSONEncoder().encode(values)
            guard data.count <= 4_000_000 else { throw TokenDiscoveryError.malformed }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { OathDiagnostics.record(error, component: "token_discovery", operation: "metadata_cache_write") }
    }

    private func read(_ value: String) async throws -> Data {
        var request = URLRequest(url: URL(string: value)!); request.timeoutInterval = 15
        let (data, status) = try await transport.send(request)
        DiagnosticHTTP.response(data, status: status, request: request)
        guard status == 200 else { throw TokenDiscoveryError.http(status) }
        guard data.count <= 16_000_000 else { throw TokenDiscoveryError.malformed }
        return data
    }
}
