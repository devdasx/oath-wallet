/// One subtle tick per quarter of a pull. Native refresh activation has its own
/// feedback. A quick swipe emits only the latest step, never a burst of ticks.
struct RefreshPullFeedback {
    private var highestStep = 0
    private var wasDragging = false

    mutating func update(progress: Double, isDragging: Bool, eligible: Bool) -> Bool {
        defer { wasDragging = isDragging }
        if !isDragging || !wasDragging { highestStep = 0 }
        guard eligible, isDragging, progress.isFinite else { return false }
        let step = min(4, max(0, Int((min(1, max(0, progress)) * 4).rounded(.down))))
        guard step > highestStep else { return false }
        highestStep = step
        return step < 4
    }
}
