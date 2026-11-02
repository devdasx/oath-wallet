import Foundation
import OathDiagnostics

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
        return CloudLocation(accountID: identity, directory: Self.backupDirectory(in: root),
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

    static func backupDirectory(in root: URL) -> URL {
        root.appendingPathComponent("Documents/Wallet Backups", isDirectory: true)
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
                    do {
                        guard try CloudBackupFiles.boundedContents(of: url) == encrypted else { throw CloudBackupError.fileConflict }
                    } catch CloudBackupError.invalidDocument {
                        OathDiagnostics.record(CloudBackupError.invalidDocument, component: "backup", operation: "compare_backup_file")
                        throw CloudBackupError.fileConflict
                    }
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
    private let directory: URL?
    private let queue: OperationQueue
    private var observers: [NSObjectProtocol] = []
    public let updates: AsyncStream<[CloudUpload]>
    private let continuation: AsyncStream<[CloudUpload]>.Continuation

    @MainActor public convenience init() throws {
        try self.init(directory: nil)
    }

    @MainActor public convenience init(location: CloudLocation) throws {
        try self.init(directory: location.directory)
    }

    @MainActor private init(directory: URL?) throws {
        self.directory = directory
        let stream = AsyncStream<[CloudUpload]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = stream.stream; continuation = stream.continuation
        queue = OperationQueue(); queue.name = "org.oathwallet.icloud-metadata"
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        query.operationQueue = queue
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // The broad metadata query finds candidates. Only files in the actual
        // backup directory can acknowledge a write or keep a removed backup active.
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
        // Legacy callers without an explicit location resolve the container on the
        // query's utility queue. An unavailable container cannot confirm removal.
        guard let directory = directory ?? FileManager.default
                .url(forUbiquityContainerIdentifier: CloudDrive.containerID).map(CloudDrive.backupDirectory(in:)),
              let values = Self.snapshot(query.results as? [NSMetadataItem], in: directory, gathering: query.isGathering)
        else { return }
        continuation.yield(values)
    }

    static func snapshot(_ items: [NSMetadataItem]?, in directory: URL, gathering: Bool) -> [CloudUpload]? {
        // The consumer treats absence in a snapshot as a removal. Withhold the
        // whole snapshot if the query is incomplete or an item cannot be located.
        guard !gathering, let items else { return nil }
        var values: [CloudUpload] = []
        for item in items {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL, url.isFileURL else { return nil }
            guard CloudBackupFiles.belongs(url, to: directory) else { continue }
            guard let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String,
                  url.lastPathComponent == name else { return nil }
            let error = item.value(forAttribute: NSMetadataUbiquitousItemUploadingErrorKey) as? NSError
            let percent = (item.value(forAttribute: NSMetadataUbiquitousItemPercentUploadedKey) as? NSNumber)?.doubleValue
            values.append(CloudUpload(fileName: name,
                uploaded: (item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? NSNumber)?.boolValue == true,
                percent: percent.map { min(100, max(0, $0)) },
                failure: error.map { $0.domain == NSCocoaErrorDomain && $0.code == NSUbiquitousFileUbiquityServerNotAvailable
                    ? .unavailable : ($0.domain == NSCocoaErrorDomain && $0.code == NSUbiquitousFileNotUploadedDueToQuotaError ? .quotaExceeded : .uploadFailed) }))
        }
        return values
    }

    @MainActor public func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        continuation.finish()
    }
}
