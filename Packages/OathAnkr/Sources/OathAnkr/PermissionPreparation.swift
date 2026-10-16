import Foundation
import OathDiagnostics

/// The review screen's unsigned fee check. Submission failures use their own
/// reporting boundary and must never inherit preparation-only exclusions.
public enum PermissionPreparation {
    public static func run<Value: Sendable>(chain: String,
        isolation: isolated (any Actor)? = #isolation,
        work: () async throws -> Value) async throws -> Value {
        try await OathDiagnostics.$chain.withValue(chain) {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    try Task.checkCancellation()
                    let result = try await work()
                    try Task.checkCancellation()
                    return result
                }
                catch {
                    if Task.isCancelled { throw CancellationError() }
                    // Expected unsigned fee validation: keep the original error
                    // for the UI, with no signable quote. Provider, simulation,
                    // storage and post-approval failures are not excluded.
                    if error as? EVMSendError != .insufficientFunds,
                       error as? TronSendError != .insufficientFunds,
                       error as? SolanaSendError != .insufficientFunds {
                        OathDiagnostics.record(error, component: "permissions", operation: "prepare")
                    }
                    throw error
                }
            }
        }
    }
}
