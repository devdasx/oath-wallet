import Foundation

/// One owner for pull progress, activation and completion. Native scroll
/// geometry drives this value; animation frames never start wallet work.
struct RefreshCycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, pulling, refreshing, succeeded, failed }

    static let activationDistance: Double = 96
    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var isReturning = false

    /// Pulling only fills the mark. UIRefreshControl owns activation on release.
    mutating func pull(distance: Double, isDragging: Bool) {
        guard distance.isFinite else { return }
        if isReturning {
            if distance <= 0.5 && !isDragging { reset() }
            return
        }
        guard phase == .idle || phase == .pulling else { return }
        // A spring rebound or programmatic scroll must never arm a refresh.
        guard isDragging || phase == .pulling else { return }
        progress = min(1, max(0, distance / Self.activationDistance))
        phase = progress > 0 ? .pulling : .idle
    }

    /// Called by the native refresh event or explicit VoiceOver refresh action.
    mutating func begin() -> Bool {
        guard !isReturning, phase == .idle || phase == .pulling else { return false }
        phase = .refreshing
        progress = 1
        return true
    }

    mutating func complete(succeeded: Bool) {
        guard phase == .refreshing, !isReturning else { return }
        phase = succeeded ? .succeeded : .failed
    }

    mutating func returnToRest() {
        guard phase == .succeeded || phase == .failed else { return }
        isReturning = true
    }

    mutating func reset() { self = Self() }
}
