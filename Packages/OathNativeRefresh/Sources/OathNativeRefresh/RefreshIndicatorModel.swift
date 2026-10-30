import Foundation
import Observation

public enum NativeRefreshIndicator: Sendable { case system, oathLogo, progressRing }

public struct NativeRefreshLabels: Equatable, Sendable {
    public let pull, refreshing, succeeded, failed: String
    public init(pull: String, refreshing: String, succeeded: String, failed: String) {
        self.pull = pull
        self.refreshing = refreshing
        self.succeeded = succeeded
        self.failed = failed
    }
    public static let english = Self(pull: "Pull to refresh", refreshing: "Refreshing",
                                      succeeded: "Updated", failed: "Refresh failed")
}

@MainActor @Observable final class RefreshIndicatorModel {
    var cycle = RefreshCycle()
    var startedAt = Date.now
    var labels = NativeRefreshLabels.english
    var isActive = true

    /// Stop can be called from a SwiftUI representable update. An in-place
    /// mutation of an already-idle observable value notifies its readers and
    /// schedules that same update again, starving the first UI frame.
    func resetIfNeeded() {
        let idle = RefreshCycle()
        if cycle != idle { cycle = idle }
    }
}
