import Foundation

/// History, not balance, determines whether an HD address has been used.
/// The persisted high-water mark prevents a reorg or a reserved change address
/// beyond a gap from hiding addresses already known to this wallet.
enum HDGapDiscovery {
    enum Failure: Error { case invalidWindow, scanLimitReached }

    struct Observation<Value: Sendable>: Sendable {
        let index: Int
        let isUsed: Bool
        let value: Value
    }

    static func scan<Value: Sendable>(gapLimit: Int, highestKnownUsedIndex: Int,
        maximumAddressCount: Int = 100_000,
        load: @Sendable (Range<Int>) async throws -> [Observation<Value>]) async throws -> [Value] {
        guard gapLimit > 0, highestKnownUsedIndex >= -1, maximumAddressCount >= gapLimit,
              maximumAddressCount <= Int.max - gapLimit,
              highestKnownUsedIndex < maximumAddressCount else {
            throw Failure.invalidWindow
        }
        var values: [Value] = []
        var start = 0
        var lastUsed = highestKnownUsedIndex
        while start < maximumAddressCount {
            try Task.checkCancellation()
            let end = min(start + gapLimit, lastUsed + gapLimit + 1, maximumAddressCount)
            let window = try await load(start..<end).sorted { $0.index < $1.index }
            guard window.map(\.index) == Array(start..<end) else { throw Failure.invalidWindow }
            for observation in window {
                if observation.isUsed { lastUsed = max(lastUsed, observation.index) }
                values.append(observation.value)
            }
            if end - lastUsed - 1 >= gapLimit { return values }
            start = end
        }
        // Never publish a truncated scan as a complete zero balance.
        throw Failure.scanLimitReached
    }
}
