import Foundation
import XCTest
@testable import OathCloudBackup

final class CloudUploadScopeTests: XCTestCase {
    private final class Item: NSMetadataItem {
        let fields: [String: Any]
        init(_ fields: [String: Any]) { self.fields = fields; super.init() }
        override func value(forAttribute key: String) -> Any? { fields[key] }
    }

    func testConfirmationRequiresTheExactRegularFileEvenWhenItsNameMatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(CloudDrive.fileName(UUID()))
        let bytes = Data([1, 2, 3])
        try bytes.write(to: url)
        XCTAssertTrue(try CloudBackupFiles.matches(bytes, at: url))
        XCTAssertFalse(try CloudBackupFiles.matches(Data([3, 2, 1]), at: url))
        XCTAssertFalse(try CloudBackupFiles.matches(Data(), at: url))
        let link = root.appendingPathComponent("linked.oathbackup")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try CloudBackupFiles.matches(bytes, at: link))
        XCTAssertThrowsError(try CloudFileWriter.write(bytes, to: link))
        try Data(repeating: 1, count: BackupDocument.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try CloudBackupFiles.matches(bytes, at: url))
        XCTAssertThrowsError(try CloudFileWriter.write(bytes, to: url))
    }

    func testOnlyCompleteResultsForTheBackupDirectoryCanAcknowledgeUpload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dir = root.appendingPathComponent("Wallet Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = CloudDrive.fileName(UUID())
        func item(_ url: URL, name: String) -> NSMetadataItem {
            Item([NSMetadataItemURLKey: url, NSMetadataItemFSNameKey: name,
                  NSMetadataUbiquitousItemIsUploadedKey: true])
        }
        let intended = item(dir.appendingPathComponent(name), name: name)
        let elsewhere = item(root.appendingPathComponent(name), name: name)
        let nested = item(dir.appendingPathComponent("old/"+name), name: name)
        XCTAssertNil(CloudUploadObservation.snapshot([], in: dir, gathering: true))
        XCTAssertNil(CloudUploadObservation.snapshot(nil, in: dir, gathering: false))
        XCTAssertNil(CloudUploadObservation.snapshot([Item([NSMetadataItemFSNameKey: name])], in: dir, gathering: false))
        XCTAssertNil(CloudUploadObservation.snapshot([item(dir.appendingPathComponent("other.oathbackup"), name: name)], in: dir, gathering: false))
        XCTAssertEqual(CloudUploadObservation.snapshot([elsewhere,nested], in: dir, gathering: false), [])
        let output = try XCTUnwrap(CloudUploadObservation.snapshot([elsewhere,intended,nested], in: dir, gathering: false))
        XCTAssertEqual(output.map(\.fileName), [name])
        XCTAssertEqual(output.map(\.uploaded), [true])
        XCTAssertEqual(CloudUploadObservation.snapshot([], in: dir, gathering: false), [])
    }
}
