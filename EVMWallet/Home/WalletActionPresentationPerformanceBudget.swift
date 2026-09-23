import Foundation

enum WalletActionPresentationPerformanceMetric:
    String,
    Sendable {
    case firstFrame = "first_frame"
    case mainQueueTurn = "main_queue_turn"
    case destinationInitialization = "destination_initialization"
    case cpuPreparation = "cpu_preparation"
    case indexedLookup = "indexed_lookup"
    case preparationCount = "preparation_count"
}

enum WalletActionPresentationPerformanceBudget {
    static let maximumImmediateCommitMilliseconds = 16.0
    static let maximumFirstFrameMilliseconds = 500.0
    static let maximumMainQueueTurnMilliseconds = 500.0
    static let maximumDestinationInitializationMilliseconds = 250.0
    static let maximumCPUPreparationMilliseconds = 1_000.0
    static let maximumIndexedLookupMilliseconds = 25.0
    static let maximumPreparationsPerBurst = 2
    static let preparationBurstNanoseconds: UInt64 = 1_000_000_000
    static func limit(
        for metric: WalletActionPresentationPerformanceMetric
    ) -> Double {
        switch metric {
        case .firstFrame:
            maximumFirstFrameMilliseconds
        case .mainQueueTurn:
            maximumMainQueueTurnMilliseconds
        case .destinationInitialization:
            maximumDestinationInitializationMilliseconds
        case .cpuPreparation:
            maximumCPUPreparationMilliseconds
        case .indexedLookup:
            maximumIndexedLookupMilliseconds
        case .preparationCount:
            Double(maximumPreparationsPerBurst)
        }
    }

    static func exceedsLimit(
        metric: WalletActionPresentationPerformanceMetric,
        value: Double
    ) -> Bool {
        value > limit(for: metric)
    }
}

struct WalletActionPreparationBurstCounter {
    private var requestID: UUID?
    private var starts: [UInt64] = []

    mutating func record(
        requestID: UUID,
        at nanoseconds: UInt64
    ) -> Int {
        if self.requestID != requestID {
            self.requestID = requestID
            starts.removeAll(keepingCapacity: true)
        }
        let window =
            WalletActionPresentationPerformanceBudget
            .preparationBurstNanoseconds
        starts.removeAll {
            nanoseconds >= $0 && nanoseconds - $0 > window
        }
        starts.append(nanoseconds)
        return starts.count
    }
}

enum WalletActionPreparationPublicationStage: Sendable {
    case immediateState
    case progressiveChainSnapshot
    case synchronizedAggregate

    var schedulesPreparation: Bool {
        switch self {
        case .immediateState, .synchronizedAggregate:
            true
        case .progressiveChainSnapshot:
            false
        }
    }
}
