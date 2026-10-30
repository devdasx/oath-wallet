import Foundation
import Observation

/// Continuous scroll values are observed only by the toolbar and artwork blur
/// modifier. The asset list and Metal renderer never observe the scroll position.
@MainActor @Observable
final class OathHomeScrollEffects {
    private(set) var pullProgress: Double = 0
    private(set) var toolbarForegroundProgress: Double = 0
    private(set) var usesScrolledStatusBar = false
    func update(origin: CGFloat) {
        guard origin.isFinite else { return }
        let pull = Double(min(1, max(0, origin / 110)))
        let scroll = Double(min(1, max(0, -origin / 100)))
        if pullProgress != pull { pullProgress = pull }
        if toolbarForegroundProgress != scroll { toolbarForegroundProgress = scroll }
        let scrolled = scroll >= 0.5
        if usesScrolledStatusBar != scrolled { usesScrolledStatusBar = scrolled }
    }
}
