import Foundation
import UIKit

actor AssetLogoCache {
    static let shared = AssetLogoCache(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private enum CacheError: LocalizedError, Sendable {
        case invalidResponse(statusCode: Int)
        case invalidImageData

        var errorDescription: String? {
            switch self {
            case let .invalidResponse(statusCode):
                return EnglishNumbers.localized(
                    "wallet.asset.logo.error.http",
                    statusCode
                )
            case .invalidImageData:
                return WalletLocalization.string(
                    "wallet.asset.logo.error.invalid_image"
                )
            }
        }
    }

    private struct FetchedImage: Sendable {
        let data: Data
        let etag: String?
        let lastModified: String?
        let shouldPersist: Bool
    }

    private struct InFlightRequest {
        let id: UUID
        let generation: UInt64
        let task: Task<Data, Error>
    }

    private static let cachedImageLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumImageByteCount = 8 * 1_024 * 1_024

    private let databaseProvider:
        @Sendable () throws -> WalletDatabase
    private let memoryCache: NSCache<NSURL, NSData>
    private let session: URLSession
    private var cacheGeneration: UInt64 = 0
    private var inFlightRequests: [URL: InFlightRequest] = [:]

    init(database: WalletDatabase) {
        databaseProvider = { database }
        Self.removeLegacyDiskCaches()

        let memoryCache = NSCache<NSURL, NSData>()
        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = 48 * 1_024 * 1_024
        self.memoryCache = memoryCache

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    private init(
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase
    ) {
        self.databaseProvider = databaseProvider
        Self.removeLegacyDiskCaches()

        let memoryCache = NSCache<NSURL, NSData>()
        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = 48 * 1_024 * 1_024
        self.memoryCache = memoryCache

        // Logo persistence belongs to WalletDatabase. An ephemeral session with
        // no URLCache prevents Foundation from creating a second disk cache.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    private var database: WalletDatabase {
        get throws {
            try databaseProvider()
        }
    }

    func imageData(for url: URL) async throws -> Data {
        if let cachedData = memoryCache.object(forKey: url as NSURL) {
            return cachedData as Data
        }

        if url.scheme == "oath-asset" {
            guard AssetCatalogEntryValidation.isValidCatalogLogoURL(url.absoluteString),
                  let resource = Bundle.main.url(
                    forResource: url.lastPathComponent,
                    withExtension: nil,
                    subdirectory: "CatalogLogos"
                  ) else { throw CacheError.invalidImageData }
            let data = try Data(contentsOf: resource, options: .mappedIfSafe)
            guard data.count <= Self.maximumImageByteCount,
                  Self.isValidImageData(data) else { throw CacheError.invalidImageData }
            storeInMemory(data, for: url)
            return data
        }

        if let inFlightRequest = inFlightRequests[url] {
            return try await resolvedData(
                from: inFlightRequest,
                for: url
            )
        }

        var storedEntry = try? await database.assetLogoCacheEntry(
            for: url
        )
        if let entry = storedEntry {
            if !Self.isValidImageData(entry.payload) {
                try? await database.removeAssetLogoCacheEntry(for: url)
                storedEntry = nil
            } else if entry.expiresAt > Date().timeIntervalSince1970 {
                storeInMemory(entry.payload, for: url)
                return entry.payload
            }
        }

        // The actor can be re-entered while GRDB performs the cache lookup.
        // Check again so simultaneous callers still share one network request.
        if let inFlightRequest = inFlightRequests[url] {
            return try await resolvedData(
                from: inFlightRequest,
                for: url
            )
        }
        return try await startRequest(
            for: url,
            storedEntry: storedEntry
        )
    }

    func removeAllCachedData() async {
        cacheGeneration &+= 1
        for request in inFlightRequests.values {
            request.task.cancel()
        }
        inFlightRequests.removeAll()
        memoryCache.removeAllObjects()
        try? await database.removeAllAssetLogoCacheEntries()
    }

    private func startRequest(
        for url: URL,
        storedEntry: AssetLogoDatabaseEntry?
    ) async throws -> Data {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if let etag = storedEntry?.etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = storedEntry?.lastModified,
           !lastModified.isEmpty {
            request.setValue(
                lastModified,
                forHTTPHeaderField: "If-Modified-Since"
            )
        }

        let requestID = UUID()
        let generation = cacheGeneration
        let session = session
        let database = try database
        let staleEntry = storedEntry
        let downloadTask = Task<Data, Error> {
            do {
                let fetchedImage = try await Self.fetchImage(
                    using: session,
                    request: request,
                    staleEntry: staleEntry
                )
                try Task.checkCancellation()

                if fetchedImage.shouldPersist {
                    try? await database.storeAssetLogoCacheEntry(
                        for: url,
                        payload: fetchedImage.data,
                        lifetime: Self.cachedImageLifetime,
                        etag: fetchedImage.etag,
                        lastModified: fetchedImage.lastModified
                    )
                    try Task.checkCancellation()
                }
                return fetchedImage.data
            } catch {
                if Self.isRetryable(error),
                   let staleEntry,
                   Self.isValidImageData(staleEntry.payload) {
                    return staleEntry.payload
                }
                throw error
            }
        }
        let inFlightRequest = InFlightRequest(
            id: requestID,
            generation: generation,
            task: downloadTask
        )
        inFlightRequests[url] = inFlightRequest
        return try await resolvedData(
            from: inFlightRequest,
            for: url
        )
    }

    private func resolvedData(
        from request: InFlightRequest,
        for url: URL
    ) async throws -> Data {
        do {
            let data = try await request.task.value
            clearInFlightRequest(request, for: url)
            guard request.generation == cacheGeneration else {
                throw CancellationError()
            }
            storeInMemory(data, for: url)
            return data
        } catch {
            clearInFlightRequest(request, for: url)
            throw error
        }
    }

    private func clearInFlightRequest(
        _ request: InFlightRequest,
        for url: URL
    ) {
        guard inFlightRequests[url]?.id == request.id else { return }
        inFlightRequests[url] = nil
    }

    private func storeInMemory(_ data: Data, for url: URL) {
        memoryCache.setObject(
            data as NSData,
            forKey: url as NSURL,
            cost: data.count
        )
    }

    nonisolated private static func fetchImage(
        using session: URLSession,
        request: URLRequest,
        staleEntry: AssetLogoDatabaseEntry?
    ) async throws -> FetchedImage {
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CacheError.invalidResponse(statusCode: -1)
                }

                if httpResponse.statusCode == 304,
                   let staleEntry,
                   isValidImageData(staleEntry.payload) {
                    return FetchedImage(
                        data: staleEntry.payload,
                        etag: httpResponse.value(
                            forHTTPHeaderField: "ETag"
                        ) ?? staleEntry.etag,
                        lastModified: httpResponse.value(
                            forHTTPHeaderField: "Last-Modified"
                        ) ?? staleEntry.lastModified,
                        shouldPersist: true
                    )
                }

                guard 200..<300 ~= httpResponse.statusCode else {
                    throw CacheError.invalidResponse(
                        statusCode: httpResponse.statusCode
                    )
                }
                guard isValidImageData(data) else {
                    throw CacheError.invalidImageData
                }
                return FetchedImage(
                    data: data,
                    etag: httpResponse.value(forHTTPHeaderField: "ETag"),
                    lastModified: httpResponse.value(
                        forHTTPHeaderField: "Last-Modified"
                    ),
                    shouldPersist: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                let willRetry = attempt < 2 && isRetryable(error)
                guard willRetry else {
                    throw error
                }
                try await Task.sleep(
                    for: .milliseconds(250 * (attempt + 1))
                )
            }
        }
        throw lastError ?? CacheError.invalidResponse(statusCode: -1)
    }

    nonisolated private static func isValidImageData(_ data: Data) -> Bool {
        !data.isEmpty
            && data.count <= maximumImageByteCount
            && UIImage(data: data) != nil
    }

    nonisolated private static func removeLegacyDiskCaches() {
        let fileManager = FileManager.default
        guard let cachesDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return
        }
        for directoryName in ["TrustWalletLogos", "AssetLogos"] {
            let legacyDirectory = cachesDirectory.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
            try? fileManager.removeItem(at: legacyDirectory)
        }
    }

    nonisolated private static func isRetryable(_ error: Error) -> Bool {
        if case let CacheError.invalidResponse(statusCode) = error {
            return statusCode == 408
                || statusCode == 429
                || 500...599 ~= statusCode
        }
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable
        ].contains(urlError.code)
    }
}
