import Foundation

public struct CloudLocation: Sendable {
    public let accountID: String
    public let directory: URL
    let generation: UUID
}

public struct CloudUpload: Sendable, Equatable {
    public let fileName: String
    public let uploaded: Bool
    public let percent: Double?
    public let failure: CloudBackupError?
    public init(fileName: String, uploaded: Bool, percent: Double?, failure: CloudBackupError?) {
        self.fileName = fileName; self.uploaded = uploaded; self.percent = percent; self.failure = failure
    }
}

/// All container discovery, coordination and file I/O run on this background
/// actor, never the UI actor. iOS owns the network transfer after the write.
public actor CloudDrive {
    public static let containerID = "iCloud.com.aperture.wallet"
    private var cachedToken: NSObject?
    private var cachedArchive: String?
    private(set) var generation = UUID()
    public init() { }

    /// Revoke locations already handed to callers. Actor messages can be
    /// reordered by priority, so a serial hop alone is not a write barrier.
    /// An old queued write must reject its generation before any file I/O.
    public func resetBarrier() {
        generation = UUID()
        cachedToken = nil; cachedArchive = nil
    }

    public func location() throws -> CloudLocation {
        let manager = FileManager.default
        let identity = try identity()
        guard let root = manager.url(forUbiquityContainerIdentifier: Self.containerID) else {
            throw CloudBackupError.unavailable
        }
        guard try self.identity() == identity else { throw CloudBackupError.accountChanged }
        return CloudLocation(accountID: identity, directory: root.appendingPathComponent("Documents/Wallet Backups", isDirectory: true),
                             generation: generation)
    }

    public func verifyAccount(_ accountID: String) throws {
        guard try matchesAccount(accountID) else { throw CloudBackupError.accountChanged }
    }

    public func matchesAccount(_ accountID: String) throws -> Bool {
        if try identity() == accountID { return true }
        guard let current = cachedToken, accountID.hasPrefix("token-v1:"),
              let archived = Data(base64Encoded: String(accountID.dropFirst(9))), archived.count < 65_536,
              let previous = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [type(of: current)], from: archived) as? NSObject else { return false }
        // Apple specifies object equality for archived ubiquity tokens; binary
        // archive hashes are not guaranteed stable across process launches.
        return current.isEqual(previous)
    }

    private func identity() throws -> String {
        guard let token = FileManager.default.ubiquityIdentityToken as? NSObject else { throw CloudBackupError.unavailable }
        if let cachedToken, token.isEqual(cachedToken), let cachedArchive { return cachedArchive }
        // An opaque, locally archived system token, never an Apple ID/password.
        let archived = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        let value = "token-v1:" + archived.base64EncodedString()
        cachedToken = token; cachedArchive = value
        return value
    }

    public func write(_ encrypted: Data, backupID: UUID, at location: CloudLocation) throws {
        try Task.checkCancellation()
        guard location.generation == generation else { throw CancellationError() }
        try verifyAccount(location.accountID)
        guard encrypted.count <= BackupDocument.maximumBytes else { throw CloudBackupError.invalidDocument }
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        let destination = location.directory.appendingPathComponent(Self.fileName(backupID))
        try CloudFileWriter.write(encrypted, to: destination)
        try verifyAccount(location.accountID)
    }

    public static func fileName(_ id: UUID) -> String { "Wallet-\(id.uuidString).\(BackupDocument.fileExtension)" }
}

enum CloudFileWriter {
    static func write(_ encrypted: Data, to destination: URL) throws {
        var coordinationError: NSError?
        var writeResult: Result<Void, Error> = .failure(CloudBackupError.unavailable)
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { url in
            writeResult = Result {
                // A retry is idempotent. A file with different bytes is never
                // overwritten, even if a different device used the same name.
                if FileManager.default.fileExists(atPath: url.path) {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true, values.fileSize == encrypted.count,
                          try Data(contentsOf: url) == encrypted else { throw CloudBackupError.fileConflict }
                } else {
                    try encrypted.write(to: url, options: .atomic)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        try writeResult.get()
    }
}

/// NSMetadataQuery performs live, system-driven upload observation. Its
/// serial operation queue reads metadata off the UI thread. Only start/stop
/// are dispatched to the main run loop, as required by Foundation.
public final class CloudUploadObservation: @unchecked Sendable {
    private let query = NSMetadataQuery()
    private let queue: OperationQueue
    private var observers: [NSObjectProtocol] = []
    public let updates: AsyncStream<[CloudUpload]>
    private let continuation: AsyncStream<[CloudUpload]>.Continuation

    @MainActor public init() throws {
        let stream = AsyncStream<[CloudUpload]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = stream.stream; continuation = stream.continuation
        queue = OperationQueue(); queue.name = "org.oathwallet.icloud-metadata"
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        query.operationQueue = queue
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // The entitlement exposes only the app's container. Match immutable
        // UUID filenames, avoiding /var vs /private/var path aliases in metadata.
        query.predicate = NSPredicate(format: "%K ENDSWITH %@",
            NSMetadataItemFSNameKey, "." + BackupDocument.fileExtension)
        query.notificationBatchingInterval = 0.25
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: queue) { [weak self] _ in
                self?.publish()
            })
        }
        if !query.start() {
            observers.forEach(NotificationCenter.default.removeObserver)
            continuation.finish()
            throw CloudBackupError.unavailable
        }
    }

    private func publish() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let values = (query.results as? [NSMetadataItem] ?? []).compactMap { item -> CloudUpload? in
            guard let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String else { return nil }
            let error = item.value(forAttribute: NSMetadataUbiquitousItemUploadingErrorKey) as? NSError
            let percent = (item.value(forAttribute: NSMetadataUbiquitousItemPercentUploadedKey) as? NSNumber)?.doubleValue
            return CloudUpload(fileName: name,
                uploaded: (item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? NSNumber)?.boolValue == true,
                percent: percent.map { min(100, max(0, $0)) },
                failure: error.map { $0.domain == NSCocoaErrorDomain && $0.code == NSUbiquitousFileUbiquityServerNotAvailable
                    ? .unavailable : ($0.domain == NSCocoaErrorDomain && $0.code == NSUbiquitousFileNotUploadedDueToQuotaError ? .quotaExceeded : .uploadFailed) })
        }
        continuation.yield(values)
    }

    @MainActor public func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        continuation.finish()
    }
}
