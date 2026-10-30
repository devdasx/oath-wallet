import Foundation

/// One owner for pull progress, activation and completion. Native scroll
/// geometry drives this value; animation frames never start wallet work.
struct RefreshCycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, pulling, refreshing, acknowledged, succeeded, failed }

    static let activationDistance: Double = 96
    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var isReturning = false

    /// Native overscroll fills the indicator; the caller selects its activation policy.
    mutating func pull(distance: Double, isDragging: Bool, activationDistance: Double = Self.activationDistance) {
        guard distance.isFinite, activationDistance.isFinite, activationDistance > 0 else { return }
        if isReturning {
            if distance <= 0.5 && !isDragging { reset() }
            return
        }
        guard phase == .idle || phase == .pulling else { return }
        // A spring rebound or programmatic scroll must never arm a refresh.
        guard isDragging || phase == .pulling else { return }
        progress = min(1, max(0, distance / activationDistance))
        phase = progress > 0 ? .pulling : .idle
    }

    /// The ring uses the same progress for drawing and activation. A rebound,
    /// ineligible navigation pan or returning result cannot start work.
    mutating func beginIfFilled(isDragging: Bool, eligible: Bool) -> Bool {
        guard isDragging, eligible, phase == .pulling, progress >= 1 else { return false }
        return begin()
    }

    /// Called by a filled ring, native refresh event or VoiceOver refresh action.
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

    /// The timed UI acknowledges the gesture while provider work is pending.
    /// This is deliberately distinct from a successful data refresh.
    mutating func acknowledge() {
        guard phase == .refreshing, !isReturning else { return }
        phase = .acknowledged
    }

    mutating func returnToRest() {
        guard phase == .succeeded || phase == .failed || phase == .acknowledged else { return }
        isReturning = true
    }

    /// A timed presentation ends without claiming that provider work succeeded.
    mutating func finishPresentation() {
        guard phase == .refreshing else { return }
        isReturning = true
    }

    mutating func reset() { self = Self() }
}
