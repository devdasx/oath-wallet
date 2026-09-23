import Foundation

enum WalletRemovalProgressStage: Int, CaseIterable, Equatable, Sendable {
    case preparing
    case removingWalletData
    case removingCredentials
    case updatingServices
    case complete

    var ordinal: Int {
        rawValue + 1
    }

    var total: Int {
        Self.allCases.count
    }

    /// Keeps each service-backed phase readable while the removal task itself
    /// continues independently at full speed.
    var minimumPresentationDurationNanoseconds: UInt64 {
        switch self {
        case .preparing:
            450_000_000
        case .removingWalletData:
            700_000_000
        case .removingCredentials:
            600_000_000
        case .updatingServices:
            450_000_000
        case .complete:
            250_000_000
        }
    }
}

typealias WalletRemovalProgressHandler =
    @MainActor @Sendable (WalletRemovalProgressStage) -> Void
