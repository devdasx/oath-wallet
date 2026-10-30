import Foundation
import OathDiagnostics

/// Requote a transfer while its fee asset is missing. The owner supplies the
/// current lifecycle state; this loop never authorizes, signs or broadcasts.
public enum SendFeeFundingRecovery {
    public enum State: Sendable { case waiting, preparing, stopped }

    @MainActor public static func run(
        interval: Duration = .seconds(15),
        state: @MainActor () -> State,
        refresh: @MainActor () -> Void,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async {
        while !Task.isCancelled, state() != .stopped {
            do { try await sleep(interval) }
            catch is CancellationError { return } // Normal view/lifecycle teardown.
            catch {
                OathDiagnostics.record(error, component: "send", operation: "fee_funding_timer")
                return
            }
            guard !Task.isCancelled else { return }
            switch state() {
            case .waiting: refresh()
            case .preparing: continue // Never overlap a manual or automatic quote.
            case .stopped: return
            }
        }
    }
}
