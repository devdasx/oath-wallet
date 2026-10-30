import OathDiagnostics
import Foundation

public enum CloudRestoreError: Error, Equatable, Sendable {
    case discoveryFailed, downloadFailed, downloadTimedOut, missingFile
}

/// Only file metadata is exposed before authentication. Wallet names and keys
/// remain inside the authenticated, encrypted document.
public struct CloudBackupEntry: Identifiable, Equatable, Sendable {
    public let fileName: String
    public let modifiedAt: Date?
    public let percentDownloaded: Double?
    public var id: String { fileName }

    public init(fileName: String, modifiedAt: Date?, percentDownloaded: Double? = nil) {
        self.fileName = fileName
        self.modifiedAt = modifiedAt
        self.percentDownloaded = percentDownloaded.map { min(100, max(0, $0)) }
    }
}

extension CloudDrive {
    /// Download the current cloud version, then coordinate a bounded read.
    /// Waiting yields the actor; it neither blocks the UI nor polls in a loop
    /// without sleeping. An account switch invalidates the entire operation.
    public func read(_ entry: CloudBackupEntry, at location: CloudLocation) async throws -> Data {
        try validate(location)
        let url = try CloudBackupFiles.url(for: entry.fileName, in: location.directory)
        do { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
        catch { OathDiagnostics.record(error);
            if (error as NSError).code == NSFileNoSuchFileError { throw CloudRestoreError.missingFile }
            throw CloudRestoreError.downloadFailed
        }
        try await CloudDownload.waitUntilCurrent {
            try await self.validate(location)
            return try CloudBackupFiles.downloadStatus(at: url)
        }
        try validate(location)
        let data = try CloudBackupFiles.read(url)
        try validate(location)
        return data
    }

    private func validate(_ location: CloudLocation) throws {
        try Task.checkCancellation()
        guard location.generation == generation else { throw CancellationError() }
        try verifyAccount(location.accountID)
    }
}

enum CloudDownload {
    static func waitUntilCurrent(timeout: Duration = .seconds(180), interval: Duration = .milliseconds(500),
                                 status: @Sendable () async throws -> URLUbiquitousItemDownloadingStatus?) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            // `.downloaded` can be a stale local version; wait for `.current`.
            if try await status() == .current { return }
            guard ContinuousClock.now < deadline else { throw CloudRestoreError.downloadTimedOut }
            try await Task.sleep(for: interval)
        }
    }
}

enum CloudBackupFiles {
    static func downloadStatus(at source: URL) throws -> URLUbiquitousItemDownloadingStatus? {
        var url = source
        // Resource values are cached. Background actors have no main run-loop
        // cache eviction, so explicitly refresh on every download observation.
        url.removeAllCachedResourceValues()
        do {
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey,
                                                          .ubiquitousItemDownloadingErrorKey])
            guard values.ubiquitousItemDownloadingError == nil else { throw CloudRestoreError.downloadFailed }
            return values.ubiquitousItemDownloadingStatus
        } catch let error as CloudRestoreError { OathDiagnostics.record(error); throw error }
        catch { OathDiagnostics.record(error);
            if (error as NSError).code == NSFileNoSuchFileError { throw CloudRestoreError.missingFile }
            throw CloudRestoreError.downloadFailed
        }
    }

    static func url(for name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"),
              !name.contains("\0"), name.utf8.count <= 255,
              (name as NSString).pathExtension == BackupDocument.fileExtension else {
            throw CloudBackupError.invalidDocument
        }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    static func belongs(_ url: URL, to directory: URL) -> Bool {
        // Metadata may use /private/var where the ubiquity URL uses /var.
        url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL ==
            directory.resolvingSymlinksInPath().standardizedFileURL
    }

    static func read(_ source: URL) throws -> Data {
        try Task.checkCancellation()
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CloudRestoreError.missingFile)
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
            result = Result {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 0, size <= BackupDocument.maximumBytes else {
                    throw CloudBackupError.invalidDocument
                }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                // Never allocate an unbounded file, including one that grows
                // between its metadata check and this coordinated read.
                let data = try file.read(upToCount: BackupDocument.maximumBytes + 1) ?? Data()
                guard !data.isEmpty, data.count <= BackupDocument.maximumBytes else {
                    throw CloudBackupError.invalidDocument
                }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}

/// Query notifications and result enumeration run on one utility queue. Only
/// query start/stop and observer lifetime belong to the main run loop. No empty
/// result is emitted until iCloud's initial gathering has actually completed.
public final class CloudBackupDiscovery: @unchecked Sendable {
    private let query = NSMetadataQuery()
    private let queue: OperationQueue
    private let directory: URL
    @MainActor private var observers: [NSObjectProtocol] = []
    public let updates: AsyncThrowingStream<[CloudBackupEntry], Error>
    private let continuation: AsyncThrowingStream<[CloudBackupEntry], Error>.Continuation

    @MainActor public init(location: CloudLocation) throws {
        directory = location.directory
        let stream = AsyncThrowingStream<[CloudBackupEntry], Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = stream.stream; continuation = stream.continuation
        queue = OperationQueue()
        queue.name = "org.oathwallet.icloud-restore-discovery"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        query.operationQueue = queue
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K ENDSWITH %@", NSMetadataItemFSNameKey, "." + BackupDocument.fileExtension)
        query.notificationBatchingInterval = 0.5
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: queue) { [weak self] _ in
                self?.publish()
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: queue) { [weak self] _ in
            self?.continuation.finish(throwing: CloudBackupError.accountChanged)
        })
        guard query.start() else {
            stop()
            throw CloudRestoreError.discoveryFailed
        }
    }

    private func publish() {
        guard !query.isGathering else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let entries = (query.results as? [NSMetadataItem] ?? []).compactMap { item -> CloudBackupEntry? in
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String,
                  CloudBackupFiles.belongs(url, to: directory),
                  (try? CloudBackupFiles.url(for: name, in: directory)) != nil else { return nil }
            let modifiedAt = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            let percent = (item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? NSNumber)?.doubleValue
            return CloudBackupEntry(fileName: name, modifiedAt: modifiedAt, percentDownloaded: percent)
        }
        // File names identify documents, while dates provide useful selection
        // context without leaking plaintext wallet metadata into iCloud.
        continuation.yield(entries.sorted {
            if $0.modifiedAt != $1.modifiedAt { return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            return $0.fileName < $1.fileName
        })
    }

    @MainActor public func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        continuation.finish()
    }
}
