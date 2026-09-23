import Foundation
import Observation

enum WalletRecoveryPhraseCopyState: Equatable, Sendable {
    case ready
    case copied

    var localizationKey: String {
        switch self {
        case .ready:
            "common.copy"
        case .copied:
            "common.copied_to_clipboard"
        }
    }

    mutating func markCopied() {
        self = .copied
    }

    mutating func reset() {
        self = .ready
    }
}

@MainActor
@Observable
final class WalletClipboardCopyFeedback {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    static let displayDuration: Duration = .seconds(2)

    private(set) var state = WalletRecoveryPhraseCopyState.ready

    @ObservationIgnored private let duration: Duration
    @ObservationIgnored private let sleep: Sleeper
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    init(
        duration: Duration = displayDuration,
        sleep: @escaping Sleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.duration = duration
        self.sleep = sleep
    }

    var localizationKey: String {
        state.localizationKey
    }

    func markCopied() {
        resetTask?.cancel()
        state.markCopied()
        let duration = duration
        let sleep = sleep
        resetTask = Task { [weak self] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.state.reset()
            self?.resetTask = nil
        }
    }

    func reset() {
        resetTask?.cancel()
        resetTask = nil
        state.reset()
    }
}
