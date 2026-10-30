import Foundation
import Testing
@testable import OathCloudBackup

@Test func resetRejectsPreviouslyIssuedLocationBeforeCloudOrFileAccess() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathResetDrive-" + UUID().uuidString)
    let drive = CloudDrive()
    let location = CloudLocation(accountID: "synthetic-account", directory: directory, generation: await drive.generation)
    await drive.resetBarrier()
    do {
        try await drive.write(Data([1,2,3]), backupID: UUID(), at: location)
        Issue.record("Reset accepted an old file write")
    } catch {
        #expect(error is CancellationError, "Must reject before querying the real iCloud account")
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}
