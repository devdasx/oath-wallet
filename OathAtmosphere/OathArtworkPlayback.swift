import Foundation

/// Shared playback state for every artwork surface. Color/layout updates only
/// invalidate a frame; they never restart time or change whether it animates.
struct OathArtworkPlayback {
    private(set) var revision: UInt64 = 1
    private(set) var presentedRevision: UInt64 = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var failures = 0
    private var lastTime: TimeInterval?

    var hasPresentedFrame: Bool { presentedRevision > 0 }
    var needsFrame: Bool { presentedRevision < revision }
    var recoveryExhausted: Bool { failures > Self.retryDelays.count }
    private static let retryDelays: [TimeInterval] = [0.25, 1, 3]

    mutating func requestFrame() { revision += 1 }

    func shouldTick(canDraw: Bool, animating: Bool) -> Bool {
        canDraw && !recoveryExhausted && (animating || needsFrame)
    }

    mutating func advance(at now: TimeInterval, animating: Bool) -> TimeInterval {
        let delta = lastTime.map { max(0, now - $0) } ?? 0
        lastTime = animating ? now : nil
        // Advance by native clock time, not by a capped per-frame increment.
        // Dropped frames must not slow the material to an apparent standstill.
        if animating { elapsed += delta }
        return delta
    }

    mutating func pause() { lastTime = nil }

    mutating func didPresent(revision: UInt64) {
        // A color change during GPU work still needs its own completed frame.
        presentedRevision = max(presentedRevision, revision)
        failures = 0
    }

    mutating func renderingFailed() -> TimeInterval? {
        requestFrame()
        pause()
        failures += 1
        // Bounded recovery avoids a hot retry loop for an unavailable GPU or
        // missing resource. Re-entering/cooling gives the surface a fresh try.
        return recoveryExhausted ? nil : Self.retryDelays[failures - 1]
    }

    mutating func resume() {
        failures = 0
        pause()
        requestFrame()
    }
}
