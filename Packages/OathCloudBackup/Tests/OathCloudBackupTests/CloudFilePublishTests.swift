import Foundation
import XCTest
@testable import OathCloudBackup

final class CloudFilePublishTests: XCTestCase, @unchecked Sendable {
    func testDanglingLinkAtBackupNameIsPreservedAsAConflict() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oath-existing-link-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("selected.oathbackup")
        let target = directory.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try CloudFileWriter.write(Data([3, 7]), to: url)) {
            XCTAssertEqual($0 as? CloudBackupError, .fileConflict)
        }
        let remaining = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        XCTAssertEqual(remaining, target.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testUncoordinatedExclusiveFileCreationIsNeverOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oath-publish-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = Data(repeating: 7, count: BackupDocument.maximumBytes)
        let different = Data("synthetic competing backup".utf8)
        var conflicts = 0
        for cycle in 0..<120 {
            let url = directory.appendingPathComponent("test.oathbackup")
            let installedFirst = cycle == 0
            if installedFirst { try different.write(to: url, options: .withoutOverwriting) }
            let writer = Task.detached { () -> Bool in
                do { try CloudFileWriter.write(backup, to: url); return true }
                catch CloudBackupError.fileConflict { return false }
            }
            try await Task.sleep(for: .microseconds(50 + (cycle % 16) * 100))
            var otherWon = true
            if !installedFirst {
                do { try different.write(to: url, options: .withoutOverwriting) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { otherWon = false }
            }
            let published = try await writer.value
            let stored = try Data(contentsOf: url)
            if otherWon {
                conflicts += 1
                XCTAssertFalse(published, "Both different writers reported success")
                XCTAssertEqual(stored, different, "The first file was overwritten")
                if published || stored != different { return }
            } else {
                XCTAssertTrue(published)
                XCTAssertEqual(stored, backup)
            }
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertGreaterThan(conflicts, 0, "The competing creator must exercise a conflict")
    }
}
