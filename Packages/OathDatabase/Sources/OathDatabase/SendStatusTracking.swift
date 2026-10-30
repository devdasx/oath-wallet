import Foundation
import GRDB
import OathDiagnostics

/// Public transaction metadata only. No keys or authentication belong to a checker.
public struct SendStatusCheck: Sendable {
    public let send: SendRecord
    public let token: String
    public let attempts: Int
}

extension OathDatabase {
    /// A previous process cannot finish an unsigned authorization. Release only
    /// those old reservations; a current authentication flow is never touched.
    public func cancelAbandonedUnsignedSends(before launch: Double) async throws {
        try await pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')") != true else { return }
            try db.execute(sql: """
                UPDATE utxos SET reservedBy=NULL WHERE reservedBy IN
                    (SELECT id FROM sends WHERE state='queued' AND signedPayload IS NULL AND createdAt<?)
                """, arguments: [launch])
            try db.execute(sql: """
                UPDATE sends SET state='cancelled',updatedAt=?
                WHERE state IN ('draft','queued') AND signedPayload IS NULL AND createdAt<?
                """, arguments: [launch,launch])
        }
    }
    // Skip removed wallets and reset work. Restoring a wallet makes its durable
    // checks eligible again without rebuilding any transaction.
    private static let statusEligibility = """
        FROM sendStatusChecks c INDEXED BY send_status_due JOIN sends s ON s.id=c.sendID JOIN wallets w ON w.id=s.walletID
        WHERE (s.state IN ('signed','broadcast') OR (s.state='confirmed' AND EXISTS(SELECT 1 FROM permissionRemovals r WHERE r.sendID=s.id AND r.status='pending'))) AND w.deletedAt IS NULL
        AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
        """

    public func observeSendStatusDeadline() -> AsyncThrowingStream<Double?, Error> {
        stream { try Self.statusDeadline($0) }
    }
    private static func statusDeadline(_ db: Database, excluding ids: [String] = []) throws -> Double? {
        // GRDB tracks the columns read by SQLite. Reading only a generated
        // column does not observe writes to its underlying retry/lease fields,
        // so the scheduler could miss a changed deadline. Select both sources
        // explicitly for observation, while ordering by the indexed deadline.
        let row = try Row.fetchOne(db, sql: "SELECT c.availableAt,c.nextAttemptAt,c.leaseUntil " + statusEligibility + exclusion(ids) + " ORDER BY c.availableAt,c.sendID LIMIT 1", arguments: StatementArguments(ids))
        return row?["availableAt"]
    }
    private static func exclusion(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " AND s.id NOT IN (" + Array(repeating:"?",count:ids.count).joined(separator:",") + ") "
    }
    public func nextSendStatusDeadline(excluding ids: [String] = []) async throws -> Double? {
        try await pool.read { try Self.statusDeadline($0,excluding:ids) }
    }
    /// Only a new process discards abandoned leases. Concurrent workers in the
    /// same process retain each other's leases and cannot duplicate a check.
    public func resumeSendStatusChecks(owner: String) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE sendStatusChecks SET leaseToken=NULL,leaseOwner=NULL,leaseUntil=NULL,nextAttemptAt=0
                WHERE leaseOwner IS NOT NULL AND leaseOwner<>?
                """, arguments: [owner])
        }
    }
    public func claimSendStatusChecks(owner: String, now: Double = Date.now.timeIntervalSince1970,
                                      limit: Int = 4, excluding ids: [String] = []) async throws -> [SendStatusCheck] {
        try await pool.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT s.*,c.attempts " + Self.statusEligibility + Self.exclusion(ids) + """
                 AND c.availableAt<=?
                 ORDER BY c.availableAt,c.sendID LIMIT ?
                """, arguments: StatementArguments(ids) + [now,max(1,min(4,limit))])
            return try rows.map { row in
                let send = try SendRecord(row: row), token = UUID().uuidString
                try db.execute(sql: "UPDATE sendStatusChecks SET leaseToken=?,leaseOwner=?,leaseUntil=? WHERE sendID=?",
                               arguments: [token,owner,now+900,send.id])
                return SendStatusCheck(send:send,token:token,attempts:row["attempts"])
            }
        }
    }
    public func finishSendStatusCheck(_ check: SendStatusCheck, failed: Bool, cancelled: Bool = false,
                                      now: Double = Date.now.timeIntervalSince1970) async throws {
        let exponent = min(check.attempts,6)
        let delay = cancelled ? 0 : min(failed ? 300.0 : 60.0, (failed ? 15.0 : 2.0) * pow(2,Double(exponent)))
        try await pool.write { db in
            // Terminal settlement deletes the job in the SAME transaction as
            // history/send updates. A late check never recreates completed work.
            try db.execute(sql: """
                UPDATE sendStatusChecks SET nextAttemptAt=?,attempts=MIN(attempts+?,1000000),
                    lastCheckedAt=CASE WHEN ? THEN lastCheckedAt ELSE ? END,
                    leaseToken=NULL,leaseOwner=NULL,leaseUntil=NULL
                WHERE sendID=? AND leaseToken=?
                """, arguments: [now+delay,cancelled ? 0:1,cancelled,now,check.send.id,check.token])
        }
    }
}

/// One bounded, app-lifetime scheduler for every send adapter. Due times and
/// leases survive termination; jobs have no arbitrary retry/age limit. A missing
/// or failing provider cannot turn an unknown transaction into a failed one.
public actor SendStatusTracker {
    public typealias Check = @Sendable (SendRecord) async throws -> Void
    private static let processOwner = UUID().uuidString
    private let database: OathDatabase
    private let check: Check
    private let owner: String
    private var enabled = false
    private var observer: Task<Void,Never>?
    private var timer: Task<Void,Never>?
    private var flights: [String:Task<Void,Never>] = [:]
    private var flightIDs: [String:String] = [:]
    private var pumping = false
    private var epoch = UUID()
    private var scheduling = 0
    private var claimRetryAt = 0.0

    public init(database: OathDatabase, check: @escaping Check) {
        self.database=database; self.check=check; owner=Self.processOwner
    }
    init(database: OathDatabase, owner: String, check: @escaping Check) {
        self.database=database; self.check=check; self.owner=owner
    }
    public func resume() async {
        guard !enabled else { return }
        enabled=true
        let ticket=UUID(); epoch=ticket
        do { try await database.resumeSendStatusChecks(owner:owner) }
        catch { OathDiagnostics.record(error,component:"send",operation:"status_resume") }
        guard enabled, epoch==ticket else { return }
        observer=Task {
            while !Task.isCancelled {
                do {
                    for try await _ in database.observeSendStatusDeadline() {
                        guard !Task.isCancelled, enabled, epoch==ticket else { return }
                        await reschedule()
                    }
                    return
                } catch {
                    if Task.isCancelled { return }
                    OathDiagnostics.record(error,component:"send",operation:"status_observation")
                    do { try await Task.sleep(for:.seconds(15)) } catch { return } // Task teardown.
                }
            }
        }
    }
    public func pause() async {
        enabled=false; epoch=UUID()
        observer?.cancel(); observer=nil; timer?.cancel(); timer=nil
        let tasks=Array(flights.values)
        for task in tasks { task.cancel() }
        // Wait outside the main actor. Keep leases until adapters actually stop,
        // so a fast foreground transition cannot overlap an old network request.
        for task in tasks { await task.value }
    }
    private func schedule(_ deadline: Double?) {
        timer?.cancel(); timer=nil
        guard enabled, flights.count<4, let deadline else { return }
        let ticket=epoch
        timer=Task {
            do { try await Task.sleep(for:.seconds(max(0,deadline-Date.now.timeIntervalSince1970))) }
            catch { return } // Superseded timer or suspension, not an app failure.
            guard !Task.isCancelled, enabled, epoch==ticket else { return }
            // Observation may replace the wake-up while a SQL claim suspends.
            // It must not cancel the task currently executing that claim.
            timer=nil
            await pump()
        }
    }
    private func pump() async {
        guard enabled, !pumping, flights.count<4 else { return }
        pumping=true
        let ticket=epoch
        do {
            let jobs=try await database.claimSendStatusChecks(owner:owner,limit:4-flights.count,excluding:Array(flightIDs.values))
            claimRetryAt = 0
            for job in jobs {
                guard enabled,epoch==ticket else {
                    try await database.finishSendStatusCheck(job,failed:false,cancelled:true); continue
                }
                flightIDs[job.token]=job.send.id
                flights[job.token]=Task {
                    await OathDiagnostics.$chain.withValue(job.send.networkID) {
                        await OathDiagnostics.$operationID.withValue(UUID()) { await run(job) }
                    }
                    await finished(job.token)
                }
            }
        } catch {
            OathDiagnostics.record(error,component:"send",operation:"status_claim")
            claimRetryAt = Date.now.timeIntervalSince1970 + 15
        }
        pumping=false
        await reschedule()
    }
    private func run(_ job: SendStatusCheck) async {
        var failed=false
        do {
            try Task.checkCancellation()
            try await check(job.send)
        } catch {
            if !Task.isCancelled && !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                failed=true
                OathDiagnostics.record(error,component:"send",operation:"status_check",
                    context:["chain":job.send.networkID,"attempt":String(min(job.attempts+1,1000000))])
            }
        }
        let cancelled = Task.isCancelled, didFail = failed
        // GRDB honors cancellation. Release the lease in an uncancelled task
        // after the adapter has stopped, including on background expiration.
        await Task {
            do { try await database.finishSendStatusCheck(job,failed:didFail,cancelled:cancelled) }
            catch { OathDiagnostics.record(error,component:"send",operation:"status_finish") }
        }.value
    }
    private func finished(_ token: String) async {
        flights[token]=nil; flightIDs[token]=nil
        await reschedule()
    }
    private func reschedule() async {
        guard enabled else { return }
        scheduling += 1
        let version = scheduling, ticket = epoch
        do {
            let deadline = try await database.nextSendStatusDeadline(excluding:Array(flightIDs.values))
            guard enabled, epoch == ticket, scheduling == version else { return }
            schedule(deadline.map { max($0, claimRetryAt) })
        }
        catch {
            OathDiagnostics.record(error,component:"send",operation:"status_schedule")
            guard enabled, epoch == ticket, scheduling == version else { return }
            schedule(Date.now.timeIntervalSince1970+15)
        }
    }
}
