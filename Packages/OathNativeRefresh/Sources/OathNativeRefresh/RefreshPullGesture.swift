/// Eligibility is fixed for the entire pan. Crossing the top while returning
/// from lower content is navigation, not a new pull-to-refresh gesture.
struct RefreshPullGesture {
    private var previousPosition: Double?
    private var wasPanning = false
    private(set) var allowsRefresh = false

    /// Position is contentOffset.y + the resting adjusted top inset. Observe
    /// idle/decelerating offsets too: UIKit can move content before the first
    /// `.began` callback, so that callback must use the preceding position.
    mutating func observe(position: Double, isPanning: Bool) {
        if isPanning && !wasPanning {
            allowsRefresh = previousPosition.map { $0.isFinite && $0 <= 1 } ?? false
        }
        if !isPanning { previousPosition = position }
        wasPanning = isPanning
    }
}
