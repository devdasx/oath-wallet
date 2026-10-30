import XCTest
@testable import OathCloudBackup

final class CloudRestoreTests: XCTestCase {
    func testDownloadWaitsForCurrentVersionRatherThanStaleLocalCopy() async throws {
        actor Status {
            var reads = 0
            func next() -> URLUbiquitousItemDownloadingStatus {
                reads += 1
                return reads == 1 ? .notDownloaded : (reads == 2 ? .downloaded : .current)
            }
        }
        let status = Status()
        try await CloudDownload.waitUntilCurrent(timeout: .seconds(1), interval: .milliseconds(1)) { await status.next() }
        let reads = await status.reads
        XCTAssertEqual(reads, 3)
    }

    func testOfflineDownloadHasBoundedTimeoutAndCanBeCancelled() async throws {
        do {
            try await CloudDownload.waitUntilCurrent(timeout: .milliseconds(5), interval: .milliseconds(1)) { .notDownloaded }
            XCTFail("An offline download never timed out")
        } catch { XCTAssertEqual(error as? CloudRestoreError, .downloadTimedOut) }
        let task = Task {
            try await CloudDownload.waitUntilCurrent { .notDownloaded }
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled download completed") }
        catch is CancellationError { }
    }

    func testDownloadStatusDoesNotKeepCachedUbiquityValues() throws {
        try withDirectory { directory in
            var file = directory.appendingPathComponent("local.oathbackup")
            try Data([1, 2, 3]).write(to: file)
            file.setTemporaryResourceValue(URLUbiquitousItemDownloadingStatus.current,
                                            forKey: .ubiquitousItemDownloadingStatusKey)
            // The fixture is local, never ubiquitous. A retained temporary
            // value would incorrectly say it was a current iCloud download.
            XCTAssertNil(try CloudBackupFiles.downloadStatus(at: file))
        }
    }

    func testCoordinatedReadReturnsDecryptableBackupAndPreservesMetadata() throws {
        try withDirectory { directory in
            let backup = BackupWallet(id: UUID(), name: "Restore fixture", mnemonic: "public fixture only",
                language: "english", createdAt: Date(timeIntervalSince1970: 100),
                accounts: [.init(network: "ethereum", derivationPath: "m/44'/60'/0'/0/0", index: 0)],
                colorHex: "DF438D", passphrase: "public fixture passphrase")
            let encrypted = try BackupDocument.seal(backup, password: "test-password")
            let url = try CloudBackupFiles.url(for: CloudDrive.fileName(UUID()), in: directory)
            try CloudFileWriter.write(encrypted, to: url)
            let document = try CloudBackupFiles.read(url)
            XCTAssertTrue(try BackupDocument.open(document, password: "test-password") == backup)
            XCTAssertThrowsError(try BackupDocument.open(document, password: "incorrect-password")) {
                XCTAssertEqual($0 as? CloudBackupError, .authenticationFailed)
            }
        }
    }

    func testReadRejectsEmptyOversizedDirectoriesAndSymlinks() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("Wallet.oathbackup")
            try Data().write(to: file)
            XCTAssertThrowsError(try CloudBackupFiles.read(file))
            try Data(repeating: 0, count: BackupDocument.maximumBytes + 1).write(to: file)
            XCTAssertThrowsError(try CloudBackupFiles.read(file))
            XCTAssertThrowsError(try CloudBackupFiles.read(directory))
            let link = directory.appendingPathComponent("Link.oathbackup")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            XCTAssertThrowsError(try CloudBackupFiles.read(link))
            XCTAssertThrowsError(try CloudBackupFiles.read(directory.appendingPathComponent("Missing.oathbackup")))
        }
    }

    func testDiscoveryScopeAndNamesCannotEscapeBackupDirectory() throws {
        try withDirectory { directory in
            let valid = try CloudBackupFiles.url(for: "Renamed backup.oathbackup", in: directory)
            XCTAssertTrue(CloudBackupFiles.belongs(valid, to: directory))
            XCTAssertFalse(CloudBackupFiles.belongs(directory.appendingPathComponent("nested/file.oathbackup"), to: directory))
            XCTAssertFalse(CloudBackupFiles.belongs(directory.deletingLastPathComponent().appendingPathComponent("other.oathbackup"), to: directory))
            for invalid in ["", "../escape.oathbackup", "nested/file.oathbackup", "nested\\file.oathbackup", ".hidden.oathbackup", "wallet.json", "bad\0.oathbackup"] {
                XCTAssertThrowsError(try CloudBackupFiles.url(for: invalid, in: directory))
            }
        }
    }

    func testRevokedLocationRejectsRestoreBeforeAccessingICloud() async throws {
        let drive = CloudDrive()
        let location = await CloudLocation(accountID: "synthetic-no-account", directory: URL(fileURLWithPath: "/tmp/no-cloud"), generation: drive.generation)
        await drive.resetBarrier()
        do {
            _ = try await drive.read(.init(fileName: "Wallet.oathbackup", modifiedAt: nil), at: location)
            XCTFail("A revoked restore location was accepted")
        } catch is CancellationError { }
    }

    func testCancelledReadDoesNotBeginCloudDownload() async throws {
        let drive = CloudDrive()
        let location = await CloudLocation(accountID: "synthetic-no-account", directory: URL(fileURLWithPath: "/tmp/no-cloud"), generation: drive.generation)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await drive.read(.init(fileName: "Wallet.oathbackup", modifiedAt: nil), at: location)
        }
        do { _ = try await task.value; XCTFail("Cancelled restore continued") }
        catch is CancellationError { }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathRestoreTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
