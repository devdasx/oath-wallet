import Foundation

public enum NativeRefreshTiming: Sendable {
    case untilFinished
    /// Present for 2.5 seconds while the action continues independently.
    case brief
}

/// Presentation owns only its timer. One separately owned action survives that
/// timer and is reused by further pulls until it completes. Screen/scene/wallet
/// teardown still cancels it through cancel(), just like an ordinary refresh.
@MainActor final class BackgroundRefresh {
    static let presentationDuration: Duration = .milliseconds(2_500)
    private var work: Task<Void, Never>?
    private var request: UUID?
    private(set) var outcome: RefreshAction.Outcome?

    func present(action: @escaping @MainActor @Sendable () async throws -> Void,
                 onCompletion: @escaping @MainActor (RefreshAction.Outcome) -> Void,
                 wait: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws
        -> RefreshAction.Outcome? {
        try Task.checkCancellation()
        if work == nil {
            let id = UUID()
            request = id
            outcome = nil
            work = Task { [weak self] in
                let result = await RefreshAction.run(action: action,
                    isCurrent: { self?.request == id })
                guard let self, self.request == id else { return }
                self.outcome = result
                self.work = nil
                onCompletion(result)
            }
        }
        try await wait(Self.presentationDuration)
        try Task.checkCancellation()
        return outcome
    }

    func cancel() {
        request = nil
        work?.cancel()
        work = nil
        outcome = nil
    }
}
