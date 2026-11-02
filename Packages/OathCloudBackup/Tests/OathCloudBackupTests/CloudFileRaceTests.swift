import XCTest
import Foundation
import Darwin
@testable import OathCloudBackup

final class CloudFileRaceTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (URL, URL, URL, Data, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oath-synthetic-race-" + UUID().uuidString)
        let folder = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let selected = folder.appendingPathComponent("selected.oathbackup")
        let outside = root.appendingPathComponent("outside-fixture")
        let file = Data("synthetic selected backup".utf8), other = Data("synthetic unselected file".utf8)
        try file.write(to: selected)
        try other.write(to: outside)
        return (root, selected, outside, file, other)
    }

    func testCachedMetadataDoesNotAuthorizeAReplacementSymlink() throws {
        let (root, selected, outside, _, other) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try FileManager.default.contentsOfDirectory(at: selected.deletingLastPathComponent(),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        let cached = try XCTUnwrap(entries.first)
        XCTAssertEqual(try cached.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, true)
        try FileManager.default.removeItem(at: selected)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)
        let read = try? CloudBackupFiles.boundedContents(of: cached)
        XCTAssertNotEqual(read, other, "Stale resource values authorized the unselected file")
        XCTAssertNil(read)
    }

    func testNamedPipeIsRejectedWithoutAWriter() throws {
        let (root, selected, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: selected)
        XCTAssertEqual(mkfifo(selected.path, 0o600), 0)
        XCTAssertThrowsError(try CloudBackupFiles.boundedContents(of: selected)) {
            XCTAssertEqual($0 as? CloudBackupError, .invalidDocument)
        }
    }

    func testCoordinatedRestoreReadDoesNotFollowARacingSymlink() async throws {
        let (root, selected, outside, file, other) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let alternate = selected.deletingLastPathComponent().appendingPathComponent("alternate")
        try FileManager.default.createSymbolicLink(at: alternate, withDestinationURL: outside)
        let left = selected.path, right = alternate.path
        let writer = Task.detached { () -> Int in
            var swapped = 0
            while !Task.isCancelled && renamex_np(left, right, UInt32(RENAME_SWAP)) == 0 { swapped += 1 }
            return swapped
        }
        var followed = false
        for _ in 0..<2_000 {
            if let contents = try? CloudBackupFiles.read(selected) {
                if contents == other { followed = true; break }
                XCTAssertEqual(contents, file)
            }
        }
        writer.cancel()
        let swaps = await writer.value
        XCTAssertGreaterThan(swaps, 0, "The fixture must actually replace the entry")
        XCTAssertFalse(followed, "The coordinated backup reader returned data from the temporary sibling outside the backup directory")
    }
}
