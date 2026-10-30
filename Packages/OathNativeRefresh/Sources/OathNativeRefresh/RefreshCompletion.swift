import Foundation

/// A refresh may finish its work before UIKit finishes presenting its control.
/// This small policy is independent of the wallet and of UIKit for host tests.
struct RefreshCompletion {
    // A brief presentation floor, not a delay in starting or publishing work.
    // It keeps very fast local refreshes perceptible instead of flashing away.
    static let minimumPresentation: TimeInterval = 0.4
    let startedAt: TimeInterval
    let minimumDuration: TimeInterval
    private var previousOffset: Double?
    private var stationaryFrames = 0

    init(startedAt: TimeInterval, minimumDuration: TimeInterval = Self.minimumPresentation) {
        self.startedAt = startedAt
        self.minimumDuration = minimumDuration
    }

    mutating func canFinish(at time: TimeInterval, tracking: Bool, dragging: Bool,
                            decelerating: Bool, modelOffset: Double,
                            presentedOffset: Double) -> Bool {
        let stationary = previousOffset.map { abs(presentedOffset - $0) < 0.25 } ?? false
        previousOffset = presentedOffset
        let settled = !tracking && !dragging && !decelerating
            && abs(modelOffset - presentedOffset) < 0.25 && stationary
        stationaryFrames = settled ? stationaryFrames + 1 : 0
        return stationaryFrames >= 2 && time - startedAt >= minimumDuration
    }
}
