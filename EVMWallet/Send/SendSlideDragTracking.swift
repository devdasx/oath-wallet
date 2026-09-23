import CoreGraphics

/// Recognizes the axis once per touch. Vertical drift must not reclassify an
/// accepted horizontal drag as the finger returns toward its starting point.
struct SendSlideDragTracking {
    private enum Axis { case undecided, horizontal, rejected }
    private var axis = Axis.undecided
    private var isActive = false
    private var translation = CGSize.zero

    /// Consumers share this projection for placement, feedback and release.
    /// Layout direction is applied once by SendSlideGesture, not by this tracker.
    var projectedTranslation: CGSize {
        axis == .horizontal ? CGSize(width: translation.width, height: 0) : .zero
    }

    mutating func update(translation: CGSize) {
        if !isActive {
            reset()
            isActive = true
        }
        self.translation = translation
        guard translation.width.isFinite, translation.height.isFinite else {
            axis = .rejected
            return
        }
        guard axis == .undecided else { return }
        // A small spatial threshold distinguishes a slide from touch-down
        // noise. Pickup remains immediate; no timer or tracking animation runs.
        guard max(abs(translation.width), abs(translation.height)) >= 6 else { return }
        axis = abs(translation.width) >= abs(translation.height) ? .horizontal : .rejected
    }

    mutating func finish() {
        // Retain the last position until GestureState resets and drives the
        // existing release spring. The next touch starts fresh, even at one point.
        isActive = false
    }

    mutating func reset() {
        axis = .undecided
        isActive = false
        translation = .zero
    }
}
