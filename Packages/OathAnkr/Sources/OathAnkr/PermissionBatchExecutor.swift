import Foundation
import OathDiagnostics

/// Fair, sequential signing. Busy networks yield to the rest of the batch.
/// Only unsigned work is retried; execute must return after journaling a send.
public enum PermissionBatchExecutor {
    public enum Outcome: Sendable { case submitted, alreadyRemoved, failed, paused }
    public static func run(
        ids: [String], maximumDeferrals: Int = 60,
        authorized: @Sendable () async -> Bool,
        execute: @Sendable (String) async throws -> Void,
        finish: @Sendable (String, Outcome, (any Error)?) async throws -> Void,
        wait: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }
    ) async throws {
        var remaining = ids, deferrals: [String:Int] = [:]
        while !remaining.isEmpty {
            var deferred: [String] = []
            for id in remaining {
                guard !Task.isCancelled, await authorized() else {
                    for pending in remaining where !deferred.contains(pending) {
                        // finish is idempotent and only changes unfinished rows.
                        try await finish(pending, .paused, nil)
                    }
                    for pending in deferred { try await finish(pending, .paused, nil) }
                    return
                }
                do {
                    try await execute(id)
                    try await finish(id, .submitted, nil)
                } catch {
                    let stillAuthorized = await authorized()
                    if error is CancellationError || Task.isCancelled || !stillAuthorized {
                        try await finish(id, .paused, nil)
                    } else if error as? PermissionError == .alreadyRemoved {
                        try await finish(id, .alreadyRemoved, nil)
                    } else if error as? EVMSendError == .busy || error as? TronSendError == .busy || error as? SolanaSendError == .busy {
                        deferrals[id,default:0] += 1
                        if deferrals[id,default:0] < maximumDeferrals { deferred.append(id) }
                        else { try await finish(id, .paused, nil) }
                    } else {
                        // The app supplies safe chain context at the operation boundary.
                        OathDiagnostics.record(error,component:"permissions",operation:"batch_item")
                        try await finish(id, .failed, error)
                    }
                }
            }
            remaining = deferred
            if !remaining.isEmpty {
                do { try await wait() }
                catch is CancellationError {
                    for id in remaining { try await finish(id,.paused,nil) }
                    return
                }
            }
        }
    }
}
