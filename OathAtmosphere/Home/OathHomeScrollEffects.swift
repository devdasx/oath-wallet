import Foundation
import Observation

/// Continuous scroll values are observed only by the toolbar and artwork blur
/// modifier. The asset list and Metal renderer never observe the scroll position.
@MainActor @Observable
final class OathHomeScrollEffects {
    private(set) var pullProgress: Double = 0
    private(set) var toolbarForegroundProgress: Double = 0
    private(set) var usesScrolledStatusBar = false
    private(set) var showsWalletSettings = false

    @ObservationIgnored private var origin: CGFloat = 0
    @ObservationIgnored private var balanceBottom: CGFloat?
    @ObservationIgnored private var toolbarHeight: CGFloat?

    func update(origin: CGFloat) {
        guard origin.isFinite else { return }
        self.origin = origin
        let pull = Double(min(1, max(0, origin / 110)))
        let scroll = Double(min(1, max(0, -origin / 100)))
        if pullProgress != pull { pullProgress = pull }
        if toolbarForegroundProgress != scroll { toolbarForegroundProgress = scroll }
        let scrolled = scroll >= 0.5
        if usesScrolledStatusBar != scrolled { usesScrolledStatusBar = scrolled }
        updateWalletSettingsVisibility()
    }

    func update(balanceBottom: CGFloat) {
        guard balanceBottom.isFinite, balanceBottom > 0 else { return }
        self.balanceBottom = balanceBottom
        updateWalletSettingsVisibility()
    }

    func update(toolbarHeight: CGFloat) {
        guard toolbarHeight.isFinite, toolbarHeight >= 0 else { return }
        self.toolbarHeight = toolbarHeight
        updateWalletSettingsVisibility()
    }

    private func updateWalletSettingsVisibility() {
        guard let balanceBottom, let toolbarHeight else { return }
        // Both measurements start below the real top safe area. A native bar
        // contributes to that safe area, so its extra occlusion is zero. The
        // balance bottom plus origin gives its position in this viewport.
        let visibleBottom = balanceBottom + origin - toolbarHeight
        // Two points of hysteresis prevent flicker at the native scroll's
        // subpixel boundary. A returning balance restores the app settings icon.
        let showWallet = visibleBottom <= (showsWalletSettings ? 2 : 0)
        if showsWalletSettings != showWallet { showsWalletSettings = showWallet }
    }
}
