import OathDiagnostics
import Foundation
import GRDB

public struct SyncCheckpoint: Sendable {
    public let cursor: SyncCursor?
    public let generation: Int64
}

public struct SyncJob: Sendable {
    public let accountID: String
    public let stream: String
    public let fetch: @Sendable (SyncCheckpoint) async throws -> SyncBatch
    public init(accountID: String, stream: String,
                fetch: @escaping @Sendable (SyncCheckpoint) async throws -> SyncBatch) {
        self.accountID = accountID; self.stream = stream; self.fetch = fetch
    }
    var id: String { "\(accountID.count):\(accountID)\(stream)" }
}

public struct SyncOutcome: Sendable {
    public enum Status: Sendable { case committed, alreadyApplied, inProgress, stale, failed, cancelled }
    public let accountID: String
    public let stream: String
    public let status: Status
}

/// Provider-neutral ingestion. Network adapters return records here; screens
/// never consume provider responses. Sliding task groups bound task count and
/// a shared permit pool bounds concurrent work even across overlapping refreshes.
public actor SyncCoordinator {
    private let database: OathDatabase
    private let concurrency: Int
    private let permits: AsyncPermits
    private var active: Set<String> = []

    public init(database: OathDatabase, maximumConcurrency: Int = 4) {
        self.database = database
        concurrency = min(16, max(1, maximumConcurrency))
        permits = AsyncPermits(count: min(16, max(1, maximumConcurrency)))
    }

    public func synchronize(_ jobs: [SyncJob]) async -> [SyncOutcome] {
        var seen: Set<String> = []
        let jobs = jobs.filter { seen.insert($0.id).inserted }
        return await withTaskGroup(of: SyncOutcome.self) { group in
            var next = 0
            func enqueue() {
                guard next < jobs.count, !Task.isCancelled else { return }
                let job = jobs[next]; next += 1
                group.addTask { await self.run(job) }
            }
            for _ in 0..<min(concurrency, jobs.count) { enqueue() }
            var results: [SyncOutcome] = []
            for await result in group { results.append(result); enqueue() }
            for job in jobs.dropFirst(next) {
                results.append(SyncOutcome(accountID: job.accountID, stream: job.stream, status: .cancelled))
            }
            return results
        }
    }

    private func run(_ job: SyncJob) async -> SyncOutcome {
        func outcome(_ status: SyncOutcome.Status) -> SyncOutcome {
            SyncOutcome(accountID: job.accountID, stream: job.stream, status: status)
        }
        // An overlapping refresh must not fetch/commit the same account stream.
        guard active.insert(job.id).inserted else { return outcome(.inProgress) }
        defer { active.remove(job.id) }
        do {
            let database = database
            let applied = try await permits.withPermit {
                let checkpoint = try await database.checkpoint(accountID: job.accountID, stream: job.stream)
                var batch = try await job.fetch(checkpoint)
                try Task.checkCancellation()
                guard batch.cursor.accountID == job.accountID, batch.cursor.stream == job.stream else {
                    throw StoreError.conflictingIdentity
                }
                batch.expectedCursor = checkpoint.cursor?.cursor
                batch.expectedGeneration = checkpoint.generation
                return try await database.apply(batch)
            }
            return outcome(applied ? .committed : .alreadyApplied)
        } catch is CancellationError { return outcome(.cancelled) }
        catch StoreError.staleSync { return outcome(.stale) }
        catch { OathDiagnostics.record(error); return outcome(.failed) }
    }
}

private actor AsyncPermits {
    private var count: Int
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(count: Int) { self.count = count }

    func withPermit<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            try Task.checkCancellation()
            let result = try await work()
            release()
            return result
        } catch { OathDiagnostics.record(error); release(); throw error }
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if count > 0 { count -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func release() {
        if waiters.isEmpty { count += 1 }
        else { waiters.removeFirst().1.resume() }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}

extension OathDatabase {
    public func checkpoint(accountID: String, stream: String) async throws -> SyncCheckpoint {
        try await pool.read { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID) else { throw StoreError.missingRecord }
            return SyncCheckpoint(cursor: try SyncCursor.fetchOne(db, key: ["accountID": accountID, "stream": stream]),
                                  generation: account.syncGeneration)
        }
    }
    public func assets(networkID: String, limit: Int = 100, afterID: String = "") async throws -> [AssetRecord] {
        try await pool.read { try AssetRecord.fetchAll($0, sql: "SELECT * FROM assets WHERE networkID=? AND id>? ORDER BY id LIMIT ?",
                                                       arguments: [networkID, afterID, Self.pageSize(limit)]) }
    }
    public func asset(networkID: String, reference: String) async throws -> AssetRecord? {
        try await pool.read { try AssetRecord.fetchOne($0, sql: "SELECT * FROM assets WHERE networkID=? AND reference=?",
                                                       arguments: [networkID, reference]) }
    }
}
