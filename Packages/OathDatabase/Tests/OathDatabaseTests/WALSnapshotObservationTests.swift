import Foundation
import XCTest
import GRDB

/// Exercises the database observation path used when a wallet session opens
/// Home while balances/metadata are being written. No app/user database is used.
final class WALSnapshotObservationTests: XCTestCase {
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int] = []
        private var failure: String?
        func append(_ value: Int) { lock.withLock { stored.append(value) } }
        func fail(_ error: any Error) { lock.withLock { failure = String(describing: type(of: error)) } }
        var values: [Int] { lock.withLock { stored } }
        var error: String? { lock.withLock { failure } }
    }

    func testObservationSeesWriteAcross512WALRestarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathWALObservation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pool = try DatabasePool(path: directory.appendingPathComponent("fixture.sqlite").path)
        defer { try? pool.close() }
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE fixture (value INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO fixture VALUES (0)")
        }
        let queue = DispatchQueue(label: "org.oathwallet.tests.wal-observation")
        for round in 0..<512 {
            let before = round * 2, after = before + 1
            try pool.write { db in try db.execute(sql: "UPDATE fixture SET value = ?", arguments: [before]) }
            // Fully checkpoint without deleting the WAL. A reader of this
            // snapshot need not read WAL frames, so the next writer can restart it.
            try pool.writeWithoutTransaction { db in _ = try db.checkpoint(.passive) }
            let writerEntered = DispatchSemaphore(value: 0)
            let releaseWriter = DispatchSemaphore(value: 0)
            let writerDone = DispatchSemaphore(value: 0)
            let initial = DispatchSemaphore(value: 0)
            let changed = DispatchSemaphore(value: 0)
            let results = Results()
            pool.asyncWriteWithoutTransaction { db in
                writerEntered.signal()
                guard releaseWriter.wait(timeout: .now() + 10) == .success else {
                    writerDone.signal()
                    return
                }
                do { try db.execute(sql: "UPDATE fixture SET value = ?", arguments: [after]) }
                catch { results.fail(error) }
                writerDone.signal()
            }
            XCTAssertEqual(writerEntered.wait(timeout: .now() + 10), .success)
            let observation = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT value FROM fixture")!
            }.start(in: pool, scheduling: .async(onQueue: queue), onError: { error in
                results.fail(error)
                initial.signal()
                changed.signal()
            }, onChange: { value in
                results.append(value)
                if value == before { initial.signal() }
                if value == after { changed.signal() }
            })
            // The initial read has completed, but observation registration is
            // waiting on the held writer. Commit exactly one write between them.
            let initialResult = initial.wait(timeout: .now() + 10)
            releaseWriter.signal()
            XCTAssertEqual(initialResult, .success, "Initial value, round \(round)")
            XCTAssertEqual(writerDone.wait(timeout: .now() + 10), .success)
            let changedResult = changed.wait(timeout: .now() + 10)
            observation.cancel()
            XCTAssertEqual(changedResult, .success, "Lost post-restart write, round \(round)")
            XCTAssertNil(results.error)
            XCTAssertEqual(results.values, [before, after], "Every committed change must be observed, round \(round)")
            if initialResult != .success || changedResult != .success || results.error != nil { return }
            // Drain cancellation before the next checkpoint/observation.
            try pool.writeWithoutTransaction { _ in }
        }
    }
}
