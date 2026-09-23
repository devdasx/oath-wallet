import CryptoKit
import Foundation

struct WalletICloudDriveBackupDocument: Codable, Sendable, Equatable {
    static let currentVersion = 3
    static let algorithm = "AES.GCM.256+WebAuthn.PRF"

    let version: Int
    let algorithm: String
    let walletID: String
    let walletName: String
    let hasPassphrase: Bool?
    let applicationName: String
    let passkeyCredentialID: Data
    let passkeyPRFSalt: Data
    let wrappedDataKey: Data
    let encryptedPayload: Data
    let contentDigest: Data
    let createdAt: Double
    let modifiedAt: Double

    static func authenticatedContext(
        purpose: String,
        version: Int = currentVersion,
        walletID: String,
        walletName: String,
        hasPassphrase: Bool? = nil,
        applicationName: String,
        passkeyCredentialID: Data,
        passkeyPRFSalt: Data,
        binding: Data = Data()
    ) -> Data {
        var context = Data()
        appendFramed(
            Data("aperture.icloud-drive-passkey-backup".utf8),
            to: &context
        )
        appendFramed(Data(algorithm.utf8), to: &context)
        appendFramed(Data(purpose.utf8), to: &context)
        appendFramed(Data(String(version).utf8), to: &context)
        appendFramed(Data(walletID.utf8), to: &context)
        appendFramed(Data(walletName.utf8), to: &context)
        if let hasPassphrase {
            appendFramed(
                Data((hasPassphrase ? "1" : "0").utf8),
                to: &context
            )
        }
        appendFramed(Data(applicationName.utf8), to: &context)
        appendFramed(passkeyCredentialID, to: &context)
        appendFramed(passkeyPRFSalt, to: &context)
        appendFramed(binding, to: &context)
        return context
    }

    static func digest(
        version: Int = currentVersion,
        walletID: String,
        walletName: String,
        hasPassphrase: Bool? = nil,
        applicationName: String,
        passkeyCredentialID: Data,
        passkeyPRFSalt: Data,
        wrappedDataKey: Data,
        encryptedPayload: Data
    ) -> Data {
        var authenticatedData = authenticatedContext(
            purpose: "document",
            version: version,
            walletID: walletID,
            walletName: walletName,
            hasPassphrase: hasPassphrase,
            applicationName: applicationName,
            passkeyCredentialID: passkeyCredentialID,
            passkeyPRFSalt: passkeyPRFSalt
        )
        appendFramed(wrappedDataKey, to: &authenticatedData)
        appendFramed(encryptedPayload, to: &authenticatedData)
        return Data(SHA256.hash(data: authenticatedData))
    }

    private static func appendFramed(
        _ value: Data,
        to destination: inout Data
    ) {
        var length = UInt64(value.count).bigEndian
        Swift.withUnsafeBytes(of: &length) {
            destination.append(contentsOf: $0)
        }
        destination.append(value)
    }
}

private struct WalletICloudDriveBackupIdentity: Decodable {
    let walletID: String
}

actor WalletICloudDriveBackupStore {
    static let shared = WalletICloudDriveBackupStore()

    private let fileManager: FileManager
    private let containerURLProvider: @Sendable () -> URL?
    private let fileExtension = "aperturewallet"
    private let maximumDocumentByteCount = 1_048_576
    private let writeData: @Sendable (Data, URL) throws -> Void

    init(
        fileManager: FileManager = .default,
        containerURLProvider: @escaping @Sendable () -> URL? = {
            FileManager.default.url(
                forUbiquityContainerIdentifier:
                    "iCloud.com.aperture.wallet"
            )
        },
        writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    ) {
        self.fileManager = fileManager
        self.containerURLProvider = containerURLProvider
        self.writeData = writeData
    }

    func save(
        _ document: WalletICloudDriveBackupDocument,
        writePolicy: WalletCloudBackupWritePolicy = .replaceExisting
    ) throws -> WalletICloudDriveBackupDocument {
        try validate(document)
        let existing: WalletICloudDriveBackupDocument?
        do {
            existing = try fetch(walletID: document.walletID)
        } catch WalletCloudBackupError.backupNotFound {
            existing = nil
        }
        try writePolicy.validate(existingBackup: existing != nil)
        let directory = try documentsDirectory()
        let destination = directory.appendingPathComponent(
            UUID().uuidString + " - " + fileName(
                walletID: document.walletID,
                walletName: document.walletName
            ),
            isDirectory: false
        )
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(document)
        } catch {
            throw WalletCloudBackupError.storageFailed
        }
        guard encoded.count <= maximumDocumentByteCount else {
            throw WalletCloudBackupError.storageFailed
        }

        let verified: WalletICloudDriveBackupDocument
        do {
            // A new revision is written separately. The previous copy remains
            // readable if writing or verifying this revision fails.
            try coordinatedWrite(encoded, to: destination)
            verified = try readDocument(at: destination)
            guard verified == document else {
                throw WalletCloudBackupError.remoteVerificationFailed
            }
        } catch {
            try? coordinatedRemove(at: destination)
            throw error
        }
        try removeOtherDocuments(
            walletID: document.walletID,
            keeping: destination
        )
        return verified
    }

    func fetch(
        walletID: String
    ) throws -> WalletICloudDriveBackupDocument {
        let urls = try backupFileURLs(in: documentsDirectory())
        let suffix = " - \(fileIdentifier(walletID: walletID)).\(fileExtension)"
        var matches: [WalletICloudDriveBackupDocument] = []
        for url in urls {
            // An unavailable or corrupt document for this exact wallet is an
            // error, not evidence that the wallet has no backup.
            if url.lastPathComponent.hasSuffix(suffix) {
                let document = try readDocument(at: url)
                guard document.walletID == walletID else {
                    throw WalletCloudBackupError.invalidBackupDocument
                }
                matches.append(document)
            } else if let document = try? readDocument(at: url),
                      document.walletID == walletID {
                matches.append(document)
            }
        }
        guard let document = matches.max(by: {
            $0.modifiedAt < $1.modifiedAt
        }) else {
            throw WalletCloudBackupError.backupNotFound
        }
        return document
    }

    func availableDocuments()
        throws -> [WalletICloudDriveBackupDocument]
    {
        try allDocuments().sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.walletID < $1.walletID
        }
    }

    func remove(walletID: String) throws -> Bool {
        let directory = try documentsDirectory()
        let urls = try backupFileURLs(in: directory)
        var removed = false
        for url in urls {
            guard let storedWalletID = try? readWalletID(at: url),
                  storedWalletID == walletID
            else {
                continue
            }
            try coordinatedRemove(at: url)
            removed = true
        }
        return removed
    }

    @discardableResult
    func removeAll() throws -> Int {
        let directory = try documentsDirectory()
        let urls = try backupFileURLs(in: directory)
        var removedCount = 0
        for url in urls {
            try coordinatedRemove(at: url)
            removedCount += 1
        }
        return removedCount
    }

    private func allDocuments()
        throws -> [WalletICloudDriveBackupDocument]
    {
        let directory = try documentsDirectory()
        var newestByWalletID: [
            String: WalletICloudDriveBackupDocument
        ] = [:]
        for url in try backupFileURLs(in: directory) {
            guard let document = try? readDocument(at: url) else {
                continue
            }
            if let existing = newestByWalletID[document.walletID],
               existing.modifiedAt >= document.modifiedAt {
                continue
            }
            newestByWalletID[document.walletID] = document
        }
        return Array(newestByWalletID.values)
    }

    private func documentsDirectory() throws -> URL {
        guard let containerURL = containerURLProvider() else {
            throw WalletCloudBackupError.iCloudUnavailable
        }
        let directory = containerURL.appendingPathComponent(
            "Documents",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw WalletCloudBackupError.storageFailed
        }
        return directory
    }

    private func backupFileURLs(in directory: URL) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey
                ],
                options: [.skipsHiddenFiles]
            ).filter {
                $0.pathExtension.caseInsensitiveCompare(fileExtension)
                    == .orderedSame
            }
        } catch {
            throw WalletCloudBackupError.storageFailed
        }
    }

    private func readDocument(
        at url: URL
    ) throws -> WalletICloudDriveBackupDocument {
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        let data = try coordinatedRead(from: url)
        guard !data.isEmpty,
              data.count <= maximumDocumentByteCount,
              let document = try? JSONDecoder().decode(
                WalletICloudDriveBackupDocument.self,
                from: data
              )
        else {
            throw WalletCloudBackupError.invalidBackupDocument
        }
        try validate(document)
        return document
    }

    private func validate(
        _ document: WalletICloudDriveBackupDocument
    ) throws {
        guard document.version
                == WalletICloudDriveBackupDocument.currentVersion,
              document.algorithm
                == WalletICloudDriveBackupDocument.algorithm,
              !document.walletID.isEmpty,
              WalletDefaultName.normalizedCustomName(
                document.walletName
              ) != nil,
              document.applicationName == "Aperture",
              !document.passkeyCredentialID.isEmpty,
              document.passkeyCredentialID.count <= 1_024,
              document.passkeyPRFSalt.count
                == WalletBackupPasskeyIdentity.prfSaltByteCount,
              !document.wrappedDataKey.isEmpty,
              document.wrappedDataKey.count <= 512,
              !document.encryptedPayload.isEmpty,
              WalletICloudDriveBackupDocument.digest(
                version: document.version,
                walletID: document.walletID,
                walletName: document.walletName,
                hasPassphrase: document.hasPassphrase,
                applicationName: document.applicationName,
                passkeyCredentialID: document.passkeyCredentialID,
                passkeyPRFSalt: document.passkeyPRFSalt,
                wrappedDataKey: document.wrappedDataKey,
                encryptedPayload: document.encryptedPayload
              )
                == document.contentDigest
        else {
            throw WalletCloudBackupError.invalidBackupDocument
        }
    }

    private func removeOtherDocuments(
        walletID: String,
        keeping destination: URL
    ) throws {
        let urls = try backupFileURLs(
            in: destination.deletingLastPathComponent()
        )
        for url in urls where url.standardizedFileURL
            != destination.standardizedFileURL {
            guard let storedWalletID = try? readWalletID(at: url),
                  storedWalletID == walletID
            else {
                continue
            }
            try coordinatedRemove(at: url)
        }
    }

    private func readWalletID(at url: URL) throws -> String {
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        let data = try coordinatedRead(from: url)
        guard !data.isEmpty,
              data.count <= maximumDocumentByteCount,
              let identity = try? JSONDecoder().decode(
                WalletICloudDriveBackupIdentity.self,
                from: data
              ),
              !identity.walletID.isEmpty
        else {
            throw WalletCloudBackupError.invalidBackupDocument
        }
        return identity.walletID
    }

    private func fileName(
        walletID: String,
        walletName: String
    ) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: " -_")
        )
        let cleanedScalars = walletName.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let cleaned = String(cleanedScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = String(cleaned.prefix(80))
        let identifier = fileIdentifier(walletID: walletID)
        return "\(String(localized: "brand.name")) - \(safeName) - \(identifier).\(fileExtension)"
    }

    private func fileIdentifier(walletID: String) -> String {
        SHA256.hash(data: Data(walletID.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func coordinatedRead(from url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try Data(
                    contentsOf: coordinatedURL,
                    options: [.mappedIfSafe]
                )
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw WalletCloudBackupError.storageFailed
        }
        do {
            return try result.get()
        } catch {
            throw WalletCloudBackupError.storageFailed
        }
    }

    private func coordinatedWrite(
        _ data: Data,
        to url: URL
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try writeData(data, coordinatedURL)
            } catch {
                writeError = error
            }
        }
        if coordinationError != nil || writeError != nil {
            throw WalletCloudBackupError.storageFailed
        }
    }

    private func coordinatedRemove(at url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var removalError: Error?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try fileManager.removeItem(at: coordinatedURL)
            } catch CocoaError.fileNoSuchFile {
                return
            } catch {
                removalError = error
            }
        }
        if coordinationError != nil || removalError != nil {
            throw WalletCloudBackupError.storageFailed
        }
    }
}
