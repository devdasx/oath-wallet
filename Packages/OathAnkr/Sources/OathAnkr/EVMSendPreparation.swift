import Foundation
import OathDiagnostics

/// Unsigned quote boundary only. Rejections still reach the existing recovery
/// UI unchanged. Signing, revalidation and broadcast must report independently.
public enum EVMSendPreparation {
    public static func run<Value: Sendable>(
        network: EVMSendNetwork,
        isolation: isolated (any Actor)? = #isolation,
        work: () async throws -> Value
    ) async throws -> Value {
        try await OathDiagnostics.$chain.withValue(network.rawValue) {
            try await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    try Task.checkCancellation()
                    let value = try await work()
                    try Task.checkCancellation()
                    return value
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    // An unsigned quote above the available balance is ordinary
                    // form validation. Keep the exact typed rejection; never
                    // apply this exemption to signing or submission failures.
                    if error as? EVMSendError != .insufficientFunds {
                        OathDiagnostics.record(error, component: "evm_send", operation: "quote",
                            context: ["chain": network.rawValue, "stage": "quote"])
                    }
                    throw error
                }
            }
        }
    }
}
