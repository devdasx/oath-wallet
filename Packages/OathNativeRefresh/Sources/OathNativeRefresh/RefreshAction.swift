import Foundation
import OathDiagnostics

/// The asynchronous refresh boundary, independent of UIKit presentation.
enum RefreshAction {
    enum Outcome: Equatable, Sendable { case succeeded, failed, cancelled }

    @MainActor static func run(action: @MainActor () async throws -> Void,
                               isCurrent: @MainActor () -> Bool) async -> Outcome {
        await OathDiagnostics.$operationID.withValue(UUID()) {
            guard !Task.isCancelled, isCurrent() else { return .cancelled }
            do {
                try await action()
                return Task.isCancelled || !isCurrent() ? .cancelled : .succeeded
            } catch {
                // Navigation, backgrounding and wallet changes invalidate this
                // UI request. A non-cooperative callback may still return an
                // ordinary error afterward; it must not report a new UI failure.
                // Provider boundaries keep reporting their original failures.
                guard !Task.isCancelled, isCurrent(), !(error is CancellationError),
                      (error as? URLError)?.code != .cancelled else { return .cancelled }
                OathDiagnostics.record(error, component: "OathNativeRefresh", operation: "startRefresh")
                return .failed
            }
        }
    }
}
