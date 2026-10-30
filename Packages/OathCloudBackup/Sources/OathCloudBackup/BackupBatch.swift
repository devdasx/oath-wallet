import OathDiagnostics
import Foundation

/// One user action, separate portable encrypted documents. Serialize expensive
/// password derivation to bound memory; committed uploads proceed independently.
public enum BackupBatch {
    public static func prepare(
        walletIDs: [String],
        operation: @Sendable (String) async throws -> Void,
        didFinish: @Sendable (String, (any Error)?) async -> Void
    ) async throws {
        var seen = Set<String>()
        for id in walletIDs where seen.insert(id).inserted {
            try Task.checkCancellation()
            do {
                try await operation(id)
                await didFinish(id, nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch { OathDiagnostics.record(error);
                try Task.checkCancellation()
                await didFinish(id, error)
            }
        }
    }
}
