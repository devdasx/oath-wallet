import OathDiagnostics
import Foundation
import OathArtworkSource

public protocol ArtworkTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

/// No app credentials, cookies, or wallet identifiers accompany image requests.
public final class ArtworkURLTransport: NSObject, ArtworkTransport, URLSessionTaskDelegate, Sendable {
    public override init() { super.init() }
    public func data(from url: URL) async throws -> Data {
        guard ArtworkSource.permits(url) else { throw ArtworkError.invalidSource }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(url.host == "tokens.coingecko.com" ? "application/json" :
            "image/avif,image/webp,image/png,image/jpeg,image/svg+xml,image/*;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ArtworkError.invalidImage }
        DiagnosticHTTP.response(Data(), status: http.statusCode, request: request)
        guard http.statusCode == 200 else { throw ArtworkError.http(http.statusCode) }
        guard let finalURL = response.url, ArtworkSource.permits(finalURL) else { throw ArtworkError.invalidSource }
        guard response.expectedContentLength <= ArtworkSource.byteLimit else { throw ArtworkError.oversized }
        var result = Data()
        for try await byte in bytes {
            guard result.count < ArtworkSource.byteLimit else { throw ArtworkError.oversized }
            result.append(byte)
        }
        return result
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(ArtworkSource.permits) == true ? request : nil)
    }
}

/// One pipeline for lists, search, activity, details, and exports. Deduplication
/// uses the complete artwork URI, so identical tickers cannot share wrong icons.
public actor ArtworkLoader {
    public static let shared = ArtworkLoader()
    private struct Entry { let image: ArtworkImage; let fetched: Date }
    private struct DiskEntry: Codable { let data: Data; let fetched: Date }
    private final class Box: NSObject {
        let entry: Entry
        init(_ entry: Entry) { self.entry = entry }
    }
    private let memory = NSCache<NSString, Box>()
    private let directory: URL
    private let transport: any ArtworkTransport
    private let fallbackCatalog: ArtworkFallbackCatalog
    private let freshFor: TimeInterval
    private let retryAfter: TimeInterval
    private let diskLimit: Int
    private var inflight: [String: Task<ArtworkImage?, Never>] = [:]
    private var failures: [String: Date] = [:]
    private var activeDownloads = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(directory: URL? = nil, transport: any ArtworkTransport = ArtworkURLTransport(),
                freshFor: TimeInterval = 7 * 24 * 3600, retryAfter: TimeInterval = 30,
                diskLimit: Int = 128 * 1024 * 1024,
                fallbackCatalog: ArtworkFallbackCatalog = .shared) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OathTokenArtwork-v1", isDirectory: true)
        self.transport = transport
        self.fallbackCatalog = fallbackCatalog
        self.freshFor = freshFor
        self.retryAfter = retryAfter
        self.diskLimit = diskLimit
        memory.totalCostLimit = 48 * 1024 * 1024
        memory.countLimit = 128
    }

    /// Show saved artwork immediately, including offline/expired originals.
    public func cached(for sources: [String]) -> ArtworkImage? {
        for source in ArtworkSource.candidates(sources) {
            if let entry = stored(source) { return entry.image }
        }
        return nil
    }

    public func image(for sources: [String]) async -> ArtworkImage? {
        let candidates = ArtworkSource.candidates(sources)
        if candidates.isEmpty, sources.contains(where: { !$0.isEmpty }) {
            OathDiagnostics.record(ArtworkError.invalidSource, component: "artwork", operation: "resolve_source", severity: "warning")
        }
        for source in candidates {
            let key = ArtworkSource.key(source)
            if let entry = stored(source), Date().timeIntervalSince(entry.fetched) < freshFor { return entry.image }
            if let task = inflight[key] {
                if let image = await task.value { return image }
                continue
            }
            if let failed = failures[key], Date().timeIntervalSince(failed) < retryAfter { continue }
            let task = Task {
                await OathDiagnostics.$operationID.withValue(UUID()) { await self.download(source) }
            }
            inflight[key] = task
            let image = await task.value
            inflight[key] = nil
            if let image { return image }
        }
        return cached(for: candidates)
    }

    private func download(_ source: String) async -> ArtworkImage? {
        await acquireSlot()
        defer { releaseSlot() }
        var candidates = [source]
        var index = 0
        while index < candidates.count {
            let candidate = candidates[index]
            do {
                let data: Data
                if let inline = ArtworkSource.inlineData(candidate) { data = inline }
                else if let url = URL(string: candidate) { data = try await transport.data(from: url) }
                else { throw ArtworkError.invalidSource }
                let image = try ArtworkImage.decode(data)
                let fetched = Date()
                let key = ArtworkSource.key(source)
                memory.setObject(Box(Entry(image: image, fetched: fetched)), forKey: key as NSString, cost: image.memoryCost)
                failures[key] = nil
                // Cache the successful, identity-matched image under the requested
                // source too, so relaunches don't repeat the known missing URL.
                save(DiskEntry(data: data, fetched: fetched), source: source)
                return image
            } catch {
                OathDiagnostics.record(error, component: "artwork", operation: "download_decode",
                    context: ["host": URL(string: candidate)?.host ?? "inline",
                        "source": String(ArtworkSource.key(candidate).prefix(12)),
                        "stage": index == 0 ? "primary" : "fallback"])
                if index == 0, error as? ArtworkError == .http(404) || error as? ArtworkError == .http(410) {
                    let alternatives = await fallbackCatalog.sources(for: source)
                    candidates += ArtworkSource.candidates(alternatives).filter { $0 != source }
                }
            }
            index += 1
        }
        // Bounded cooldown, never persist a failed download/placeholder.
        failures = failures.filter { Date().timeIntervalSince($0.value) < retryAfter }
        if failures.count >= 256, let oldest = failures.min(by: { $0.value < $1.value })?.key { failures[oldest] = nil }
        failures[ArtworkSource.key(source)] = Date()
        return nil
    }

    private func stored(_ source: String) -> Entry? {
        let key = ArtworkSource.key(source)
        if let box = memory.object(forKey: key as NSString) { return box.entry }
        let file = path(source)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let saved: DiskEntry, image: ArtworkImage
        var stage = "cache_envelope"
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= ArtworkSource.byteLimit * 2 else { throw ArtworkError.oversized }
            saved = try PropertyListDecoder().decode(DiskEntry.self, from: Data(contentsOf: file))
            stage = "cache_image"
            image = try ArtworkImage.decode(saved.data)
        } catch {
            OathDiagnostics.record(error, component: "artwork", operation: "cache_read",
                context: ["source": String(key.prefix(12)), "stage": stage])
            _ = OathDiagnostics.attempt("remove_invalid_artwork") { try FileManager.default.removeItem(at: file) }
            return nil
        }
        let entry = Entry(image: image, fetched: saved.fetched)
        memory.setObject(Box(entry), forKey: key as NSString, cost: image.memoryCost)
        // Touch the file for disk LRU; freshness lives inside the envelope.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return entry
    }
    private func path(_ source: String) -> URL { directory.appendingPathComponent(ArtworkSource.key(source) + ".artwork") }
    private func save(_ entry: DiskEntry, source: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            try encoder.encode(entry).write(to: path(source), options: .atomic)
            prune()
        } catch { OathDiagnostics.record(error); /* The in-memory original still works if disk is unavailable. */ }
    }
    private func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let entries = files.filter { $0.pathExtension == "artwork" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, bytes, _) in entries where total > diskLimit {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= bytes }
        }
    }
    private func acquireSlot() async {
        if activeDownloads < 6 { activeDownloads += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func releaseSlot() {
        if waiting.isEmpty { activeDownloads -= 1 }
        else { waiting.removeFirst().resume() }
    }
}
