import Foundation

@main
struct CheckHomeScrollEffects {
    @MainActor static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        let effects = OathHomeScrollEffects()
        expect(!effects.showsWalletSettings, "Start with the app settings icon")
        // Native scroll restoration can arrive before SwiftUI has laid out.
        effects.update(origin: -200)
        expect(!effects.showsWalletSettings, "Wait for real geometry")
        effects.update(toolbarHeight: 56)
        effects.update(balanceBottom: 190)
        expect(effects.showsWalletSettings, "Layout must reconcile an already-scrolled viewport")
        effects.update(origin: 0)
        expect(!effects.showsWalletSettings, "Resting at the top restores the app settings icon")

        // Only switch when the entire balance has passed beneath the toolbar.
        effects.update(origin: -133)
        expect(!effects.showsWalletSettings, "Keep app settings while the hero balance is visible")
        effects.update(origin: -134)
        expect(effects.showsWalletSettings, "Wallet settings take over at the measured edge")
        for origin: CGFloat in [-133.9, -134.1, -133.5, -134, -132.5] {
            effects.update(origin: origin)
            expect(effects.showsWalletSettings, "Subpixel scroll jitter must not flash the app settings icon")
        }
        effects.update(origin: -131)
        expect(!effects.showsWalletSettings, "Reverse scrolling returns the app settings icon")

        // A pull, native refresh inset, and rebound must never bring in wallet settings.
        for origin: CGFloat in [0, 25, 80, 180, 60, 0] {
            effects.update(origin: origin)
            expect(!effects.showsWalletSettings, "Pull-to-refresh keeps the app settings icon")
            expect(effects.toolbarForegroundProgress == 0, "Pulling keeps the artwork's white toolbar foreground")
        }
        expect(effects.pullProgress == 0, "Pull blur resets after native rebound")
        expect(effects.toolbarForegroundProgress == 0, "Toolbar foreground resets at the top")
        effects.update(origin: 55)
        expect(effects.pullProgress == 0.5, "Blur follows a partial downward pull")
        effects.update(origin: 220)
        expect(effects.pullProgress == 1, "Deep pulls have a bounded blur radius")
        effects.update(origin: 22)
        expect(effects.pullProgress == 0.2, "Blur decreases with the native rebound")

        // Dynamic Type or localization can change both measured layouts while
        // already scrolled. Reevaluate without waiting for another gesture.
        effects.update(origin: -160)
        expect(effects.pullProgress == 0, "Scrolling into Assets never blurs the animated background")
        expect(effects.showsWalletSettings, "A smaller header has already left the viewport")
        effects.update(balanceBottom: 310)
        effects.update(toolbarHeight: 82)
        expect(!effects.showsWalletSettings, "A taller balance that returns into view restores app settings")
        effects.update(origin: -228)
        expect(effects.showsWalletSettings, "Use the enlarged layout's actual edge")
        effects.update(origin: -200)
        expect(!effects.showsWalletSettings, "Reverse scrolling also works after a layout change")
        effects.update(toolbarHeight: 120)
        expect(effects.showsWalletSettings, "A changed toolbar height updates occlusion immediately")
        effects.update(toolbarHeight: 56)
        expect(!effects.showsWalletSettings, "Reducing toolbar occlusion restores app settings")

        effects.update(balanceBottom: .nan)
        effects.update(toolbarHeight: -1)
        effects.update(origin: .infinity)
        expect(!effects.showsWalletSettings, "Transient invalid geometry must not corrupt state")
        effects.update(origin: -500)
        expect(effects.showsWalletSettings, "Fast scrolls can cross the threshold in one callback")
        expect(effects.toolbarForegroundProgress == 1 && effects.usesScrolledStatusBar,
               "Scrolled foreground and status text adapt to the asset content")
        effects.update(origin: 0)
        expect(!effects.showsWalletSettings && !effects.usesScrolledStatusBar,
               "Scroll-to-top restores both original toolbar states")

        // Native navigation already reserves its safe area. Counting the bar
        // again would switch to wallet settings before the hero balance leaves.
        effects.update(toolbarHeight: 0)
        effects.update(balanceBottom: 200)
        effects.update(origin: -199)
        expect(!effects.showsWalletSettings, "Native bar must not double-count its safe area")
        effects.update(origin: -200)
        expect(effects.showsWalletSettings, "Native bar takes over when the balance leaves the viewport")
        effects.update(origin: -199)
        expect(effects.showsWalletSettings, "Native bar retains threshold hysteresis")
        effects.update(origin: -197)
        expect(!effects.showsWalletSettings, "Native reverse scroll restores the app settings icon")
        effects.update(origin: 80)
        expect(!effects.showsWalletSettings, "Native refresh leaves the app settings icon visible")
        print("Passed \(checks) home toolbar scroll checks")
    }
}
