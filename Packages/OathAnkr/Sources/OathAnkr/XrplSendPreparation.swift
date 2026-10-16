import Foundation
import OathDiagnostics

/// Unsigned review only. Account requirements still reject the quote and reach
/// the existing recovery UI. Signing/submission must never use this boundary.
public enum XrplSendPreparation {
    /// Only proved account requirements from an unsigned quote. In particular,
    /// `amount` can also indicate invalid internal/provider data, so it remains
    /// observable until its exact origin is known. Do not use for submission.
    static func isAccountRequirement(_ error: Error) -> Bool {
        switch error as? XrplSendError {
        case .reserve, .recipientUnfunded: return true
        case .recipientMinimum(let minimum): return minimum > 0
        default: return false
        }
    }

    public static func run<Value: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        work: () async throws -> Value
    ) async throws -> Value {
        try await OathDiagnostics.$chain.withValue("xrpl") {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    try Task.checkCancellation()
                    let value = try await work()
                    try Task.checkCancellation()
                    return value
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if !isAccountRequirement(error) {
                        OathDiagnostics.record(error, component: "xrpl_send", operation: "prepare",
                            context: ["chain": "xrpl", "stage": "quote"])
                    }
                    throw error
                }
            }
        }
    }
}
