import Foundation
import OathArtworkSource
import OathDiagnostics

/// Public token identity, never a wallet/account identity or a ticker match.
public struct TokenArtworkIdentity: Hashable, Sendable {
    public let networkID: String
    public let reference: String
    public let decimals: Int?
    public static let evmNetworks: Set<String> = [
        "ethereum", "arbitrum", "arc", "avalanche", "base", "bnb", "fantom", "flare",
        "gnosis", "linea", "optimism", "polygon", "chiliz", "filecoin", "sei", "zerog", "iotex", "celo", "monad", "unichain", "hyperevm",
        "robinhood", "scroll", "somnia", "story", "taiko", "telos", "xlayer"
    ]
    public init?(networkID: String, reference: String, decimals: Int? = nil) {
        guard !networkID.isEmpty, networkID.count <= 64, !reference.isEmpty,
              reference != "native", reference.utf8.count <= 4096, decimals == nil || (0...255).contains(decimals!) else { return nil }
        self.networkID = networkID
        self.reference = Self.evmNetworks.contains(networkID) ? reference.lowercased() : reference
        self.decimals = decimals
    }
    public var assetID: String { networkID + ":" + reference }
    var cacheKey: String { ArtworkSource.key("token-v1:\(networkID.count):\(networkID):\(reference):\(decimals.map(String.init) ?? "unknown")") }
}

public protocol TokenArtworkMetadata: Sendable {
    /// Return only sources validated against this exact network and token.
    /// cachedOnly must never issue a network request.
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String]
}

/// Shares successful artwork across search, saved holdings and detail screens,
/// even when they supply different metadata URLs (or no URL at all).
/// Image bytes remain in ArtworkLoader's bounded, original-quality cache.
public actor TokenArtworkResolver {
    private struct Entry: Codable { let source: String; let saved: Date }
    private struct Request: Hashable { let token: TokenArtworkIdentity; let sources: [String] }
    private let loader: ArtworkLoader
    private let metadata: any TokenArtworkMetadata
    private let directory: URL
    private var entries: [TokenArtworkIdentity: Entry] = [:]
    private var work: [Request: Task<ArtworkImage?, Never>] = [:]
    private var metadataWork: [TokenArtworkIdentity: Task<[String], Never>] = [:]
    private var retryAfter: [TokenArtworkIdentity: Date] = [:]
    private var observers: [TokenArtworkIdentity: [UUID: AsyncStream<ArtworkImage>.Continuation]] = [:]
    private var activeMetadata = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(loader: ArtworkLoader = .shared, metadata: any TokenArtworkMetadata, directory: URL? = nil) {
        self.loader = loader; self.metadata = metadata
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OathTokenArtworkIdentity-v1", isDirectory: true)
    }

    public func cached(for token: TokenArtworkIdentity, sources: [String]) async -> ArtworkImage? {
        let saved = entry(for: token).map { [$0.source] } ?? []
        return await loader.cached(for: saved + sources)
    }

    /// Visible rows receive a newly resolved detail/search image without needing
    /// a balance change, navigation rebuild, or a periodic polling timer.
    public func updates(for token: TokenArtworkIdentity, observerID id: UUID = UUID()) async -> AsyncStream<ArtworkImage> {
        let (stream, continuation) = AsyncStream<ArtworkImage>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[token, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id, token: token) } }
        if let image = await cached(for: token, sources: []) { continuation.yield(image) }
        return stream
    }
    private func removeObserver(_ id: UUID, token: TokenArtworkIdentity) {
        observers[token]?[id] = nil
        if observers[token]?.isEmpty == true { observers[token] = nil }
    }
    /// Explicitly end observers whose view disappears before it starts iterating
    /// (for example, while a shared network request is still in flight).
    public func stopUpdates(for token: TokenArtworkIdentity, observerID: UUID) {
        observers[token]?[observerID]?.finish()
        removeObserver(observerID, token: token)
    }

    public func image(for token: TokenArtworkIdentity, sources: [String]) async -> ArtworkImage? {
        let request = Request(token: token, sources: ArtworkSource.candidates(sources))
        if let existing = work[request] { return await existing.value }
        let task = Task {
            await OathDiagnostics.$chain.withValue(token.networkID) {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    await self.resolve(request)
                }
            }
        }
        work[request] = task
        let image = await task.value
        work[request] = nil
        return image
    }

    private func resolve(_ request: Request) async -> ArtworkImage? {
        let token = request.token
        let saved = entry(for: token).map { [$0.source] } ?? []
        // Older on-chain metadata still points at Circle's retired website
        // image route (now HTTP403). Keep usable saved bytes, but resolve a
        // current, exact-chain/reference image before requesting that route.
        let retiredCircleIcon = "https://circle.com/usdc-icon"
        if let source = saved.first {
            let image = source == retiredCircleIcon
                ? await loader.cached(for: [source]) : await loader.image(for: [source])
            if let image {
                remember(source, token: token, image: image)
                return image
            }
        }
        // The detail metadata may already be saved from an earlier app version.
        // Read it before retrying a guessed catalog URL which can be absent.
        let cachedMetadata = await metadata.sources(for: token, cachedOnly: true)
        // One published token list covers every visible result on a network.
        // Do not exhaust per-coin metadata limits just to render search logos,
        // then fall through to missing guessed images for the remaining rows.
        let hasRetiredSource = (saved + cachedMetadata + request.sources).contains(retiredCircleIcon)
        let published: [String]
        if hasRetiredSource {
            published = await loader.catalogSources(for: token)
        } else {
            published = cachedMetadata.isEmpty
                ? await loader.catalogSources(for: token, sources: request.sources) : []
        }
        // Discovery knows the public contract before it knows the token scale.
        // Resolve its exact catalog artwork before probing a guessed image path.
        // This never supplies decimals to balances, prices or signing.
        // Saved tokens already have decimals, but their directory-shaped logo
        // is still only a guess. Resolve exact artwork first for those too.
        let hasDirectoryGuess = request.sources.contains { source in
            guard let url = URL(string: source), url.host == "raw.githubusercontent.com" else { return false }
            let path = url.path.split(separator: "/")
            return path.count == 8 && path[0] == "trustwallet" && path[1] == "assets"
                && path[3] == "blockchains" && path[5] == "assets" && path[7] == "logo.png"
        }
        let discoveryMetadata = (token.decimals == nil || hasDirectoryGuess) && cachedMetadata.isEmpty && published.isEmpty
            ? await metadataSources(for: token) : []
        let candidates = ArtworkSource.candidates(hasRetiredSource
            ? published + saved + cachedMetadata + discoveryMetadata + request.sources
            : saved + cachedMetadata + published + discoveryMetadata + request.sources)
        for source in candidates {
            if let image = await loader.image(for: [source]) {
                remember(source, token: token, image: image)
                return image
            }
        }
        let refreshed = await metadataSources(for: token)
        for source in ArtworkSource.candidates(refreshed) where !candidates.contains(source) {
            if let image = await loader.image(for: [source]) {
                remember(source, token: token, image: image)
                return image
            }
        }
        // Missing optional artwork never becomes a persisted placeholder.
        return await cached(for: token, sources: request.sources)
    }

    private func metadataSources(for token: TokenArtworkIdentity) async -> [String] {
        if let task = metadataWork[token] { return await task.value }
        if let date = retryAfter[token], date > Date() { return [] }
        let task = Task {
            await self.acquireMetadataSlot()
            let sources = await self.metadata.sources(for: token, cachedOnly: false)
            self.releaseMetadataSlot()
            return sources
        }
        metadataWork[token] = task
        let sources = await task.value
        metadataWork[token] = nil
        retryAfter = retryAfter.filter { $0.value > Date() }
        if retryAfter.count >= 256, let oldest = retryAfter.min(by: { $0.value < $1.value })?.key { retryAfter[oldest] = nil }
        retryAfter[token] = Date().addingTimeInterval(30)
        return sources
    }
    private func acquireMetadataSlot() async {
        if activeMetadata < 3 { activeMetadata += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func releaseMetadataSlot() {
        if waiting.isEmpty { activeMetadata -= 1 } else { waiting.removeFirst().resume() }
    }

    private func path(_ token: TokenArtworkIdentity) -> URL { directory.appendingPathComponent(token.cacheKey + ".plist") }
    private func entry(for token: TokenArtworkIdentity) -> Entry? {
        if let entry = entries[token] { return entry }
        let file = path(token)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= ArtworkSource.byteLimit * 2 else { throw ArtworkError.oversized }
            let entry = try PropertyListDecoder().decode(Entry.self, from: Data(contentsOf: file))
            guard ArtworkSource.normalized(entry.source) != nil else { throw ArtworkError.invalidSource }
            keep(entry, token: token)
            return entry
        } catch {
            OathDiagnostics.record(error, component: "artwork", operation: "identity_cache_read")
            _ = OathDiagnostics.attempt("remove_invalid_artwork_identity") { try FileManager.default.removeItem(at: file) }
            return nil
        }
    }
    private func keep(_ entry: Entry, token: TokenArtworkIdentity) {
        if entries[token] == nil, entries.count >= 256,
           let oldest = entries.min(by: { $0.value.saved < $1.value.saved })?.key { entries[oldest] = nil }
        entries[token] = entry
    }
    private func remember(_ source: String, token: TokenArtworkIdentity, image: ArtworkImage) {
        // Large inline images already live in the byte cache and their provider
        // metadata; do not duplicate them in the identity index.
        guard source.utf8.count <= 8192 else {
            for observer in observers[token]?.values ?? [:].values { observer.yield(image) }
            return
        }
        let changed = entry(for: token)?.source != source || !FileManager.default.fileExists(atPath: path(token).path)
        let entry = Entry(source: source, saved: Date())
        keep(entry, token: token)
        // The same URL can recover after an outage or cache repair. A row that
        // previously showed a placeholder must receive that successful image too.
        for observer in observers[token]?.values ?? [:].values { observer.yield(image) }
        if changed {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                try encoder.encode(entry).write(to: path(token), options: .atomic)
                let files = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles)
                let indexed = try files.filter { $0.pathExtension == "plist" }.map { file in
                    let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    return (url: file, date: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
                }.sorted { $0.date > $1.date }
                var total = 0
                for (index, file) in indexed.enumerated() {
                    total += file.size
                    if index >= 512 || total > 16 * 1024 * 1024 { try FileManager.default.removeItem(at: file.url) }
                }
            } catch { OathDiagnostics.record(error, component: "artwork", operation: "identity_cache_write") }
        }
    }
}
