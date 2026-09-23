import CoreGraphics

/// Rendering, feedback and activation share actual horizontal progress.
/// Only release at or beyond the threshold commits; moving back can cancel.
struct SendSlideGesture {
    static let completionProgress: CGFloat = 0.90
    private static let readinessRearmProgress: CGFloat = 0.85
    private static let feedbackSteps = 10
    private(set) var hasCommitted = false
    private var feedbackStep = 0
    private var readinessFeedbackLatched = false

    enum FeedbackEvent: Equatable {
        case none
        case checkpoint
        case ready
        case retreated
    }

    static func progress(translation: CGSize, travel: CGFloat, isRTL: Bool) -> CGFloat {
        guard travel > 0, travel.isFinite, translation.width.isFinite, translation.height.isFinite,
              abs(translation.width) >= abs(translation.height) else { return 0 }
        return min(1, max(0, translation.width * (isRTL ? -1 : 1) / travel))
    }

    mutating func commitOnRelease(translation: CGSize, travel: CGFloat, isRTL: Bool, enabled: Bool) -> Bool {
        defer { resetFeedback() }
        guard enabled, !hasCommitted,
              Self.progress(translation: translation, travel: travel, isRTL: isRTL) >= Self.completionProgress else {
            return false
        }
        hasCommitted = true
        return true
    }

    /// Readiness has a small feedback-only hysteresis zone. The actual release
    /// threshold remains exactly 90%, including when reversing after reaching it.
    mutating func feedbackEvent(translation: CGSize, travel: CGFloat, isRTL: Bool,
                                enabled: Bool) -> FeedbackEvent {
        guard enabled, !hasCommitted, travel.isFinite, travel > 0,
              translation.width.isFinite, translation.height.isFinite,
              abs(translation.width) >= abs(translation.height) else { return .none }
        let progress = Self.progress(translation: translation, travel: travel, isRTL: isRTL)
        let step = min(Self.feedbackSteps, Int(progress / Self.completionProgress * CGFloat(Self.feedbackSteps)))

        if readinessFeedbackLatched {
            guard progress <= Self.readinessRearmProgress else { return .none }
            readinessFeedbackLatched = false
            feedbackStep = step
            return .retreated
        }
        if progress >= Self.completionProgress {
            readinessFeedbackLatched = true
            feedbackStep = step
            return .ready
        }
        // Fast drags emit only the current checkpoint, never a queue of past ticks.
        guard step != feedbackStep else { return .none }
        feedbackStep = step
        return .checkpoint
    }

    /// Compatibility for callers that need only to know whether feedback occurred.
    mutating func updateFeedback(translation: CGSize, travel: CGFloat, isRTL: Bool, enabled: Bool) -> Bool {
        feedbackEvent(translation: translation, travel: travel, isRTL: isRTL, enabled: enabled) != .none
    }

    mutating func resetFeedback() {
        feedbackStep = 0
        readinessFeedbackLatched = false
    }

    mutating func activateAccessibly(enabled: Bool) -> Bool {
        guard enabled, !hasCommitted else { return false }
        hasCommitted = true
        return true
    }

    mutating func reset() {
        hasCommitted = false
        resetFeedback()
    }
}
