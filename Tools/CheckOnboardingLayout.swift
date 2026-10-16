import Foundation
import CoreGraphics

@main
struct CheckOnboardingLayout {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func layout(_ size: CGSize, divisions: [CGRect] = [], occlusions: [CGRect] = [],
                    rtl: Bool = false, actionHeight: CGFloat = 200, copyHeight: CGFloat = 175) -> OathOnboardingLayout {
            OathOnboardingLayout(size: size, actionHeight: actionHeight,
                                 introductionHeight: copyHeight, divisions: divisions,
                                 occlusions: occlusions, rightToLeft: rtl)
        }
        func validate(_ result: OathOnboardingLayout, size: CGSize, obstacles: [CGRect] = []) {
            let bounds = CGRect(origin: .zero, size: size)
            for region in [result.introduction, result.actions] {
                check(bounds.contains(region), "Content must remain inside system-safe bounds")
                check(region.width > 200 && region.height > 100, "Both content groups need usable space")
                for obstacle in obstacles {
                    check(region.intersection(obstacle).isEmpty, "Content must not cross a reserved region")
                }
            }
            check(result.introduction.intersection(result.actions).isEmpty, "Content groups must not overlap")
            check(result.logoSize.width <= result.introduction.width, "Logo must fit its content region")
            check(abs(result.logoSize.height / result.logoSize.width - 0.75) < 0.0001, "Preserve logo proportions")
        }

        let closed = CGSize(width: 466, height: 638)
        let closedLayout = layout(closed)
        check(closedLayout.arrangement == .stacked, "The closed display uses the compact composition")
        validate(closedLayout, size: closed)

        // Observed outer-display safe bounds after the camera and home insets.
        let closedLandscape = CGSize(width: 594, height: 432)
        let landscapeLayout = layout(closedLandscape)
        check(landscapeLayout.arrangement == .spread, "The shorter outer landscape display needs two columns")
        validate(landscapeLayout, size: closedLandscape)

        let open = CGSize(width: 951, height: 629)
        let openLayout = layout(open)
        check(openLayout.arrangement == .spread, "The wide display uses both sides")
        validate(openLayout, size: open)

        let crease = CGRect(x: 457, y: 0, width: 37, height: open.height)
        let book = layout(open, divisions: [crease])
        check(book.arrangement == .spread, "Book pose divides content horizontally")
        validate(book, size: open, obstacles: [crease])
        let rtl = layout(open, divisions: [crease], rtl: true)
        check(rtl.introduction == book.actions && rtl.actions == book.introduction, "RTL mirrors pane order")
        validate(rtl, size: open, obstacles: [crease])

        let tall = CGSize(width: 669, height: 911)
        let hinge = CGRect(x: 0, y: 441, width: tall.width, height: 29)
        let tabletop = layout(tall, divisions: [hinge])
        check(tabletop.arrangement == .tabletop, "Tabletop keeps actions below the fold")
        validate(tabletop, size: tall, obstacles: [hinge])
        check(layout(tall).arrangement == .stacked, "Flat portrait keeps one reading column")

        let camera = CGRect(x: 875, y: 0, width: 76, height: 82)
        let cameraLayout = layout(open, occlusions: [camera])
        validate(cameraLayout, size: open, obstacles: [camera])
        check(cameraLayout.introduction == openLayout.introduction, "Camera activation preserves the unaffected pane")

        let largeText = layout(closed, actionHeight: 440, copyHeight: 470)
        validate(largeText, size: closed)
        check(largeText.actions.height >= 280, "Accessibility copy receives room to scroll")
        check(largeText.introduction.height > 250, "The introduction remains accessible with large text")
        check(layout(open, divisions: [.zero]) == openLayout, "An inactive zero-width fold has no effect")

        // Regression: NavigationStack first proposed (0, 0) on Thuglife. An
        // over-inset CGRect became null, and a NaN measurement poisoned the
        // subsequent 440 x 754 layout, causing CALayerInvalidGeometry at launch.
        let startupSizes = [CGSize.zero, CGSize(width: 440, height: 0),
                            CGSize(width: 440, height: 16), CGSize(width: 20, height: 20),
                            CGSize(width: -1, height: 50), CGSize(width: CGFloat.infinity, height: CGFloat.nan)]
        for size in startupSizes {
            let result = layout(size)
            let safeSize = OathLayoutGeometry.finiteSize(size)
            for region in [result.introduction, result.actions] {
                check(OathLayoutGeometry.isFinite(region), "Startup frames must have finite coordinates")
                check(region.width >= 0 && region.height >= 0, "Startup frames cannot have negative dimensions")
                check(region.minX >= 0 && region.maxX <= safeSize.width
                      && region.minY >= 0 && region.maxY <= safeSize.height, "Startup frames stay inside the proposed bounds")
            }
            check(result.logoSize.width.isFinite && result.logoSize.height.isFinite, "Startup logo dimensions stay finite")
        }
        check(!OathLayoutGeometry.isUsable(layout(.zero).actions), "Empty startup panes are not mounted as scroll views")
        let visible = CGSize(width: 440, height: 754)
        for badHeight in [CGFloat.nan, .infinity, -.infinity] {
            check(layout(visible, actionHeight: badHeight, copyHeight: badHeight) == layout(visible),
                  "Invalid measured heights cannot poison the next valid layout")
        }
        let invalidFrames = [CGRect.null, .infinite, CGRect(x: 0, y: 0, width: 10, height: CGFloat.nan)]
        for frame in invalidFrames {
            check(!OathLayoutGeometry.isUsable(frame), "Invalid geometry cannot be cached by measurement callbacks")
        }
        check(layout(visible, divisions: invalidFrames, occlusions: invalidFrames) == layout(visible),
              "Invalid reserved regions cannot contaminate content frames")
        print("Passed \(checks) host layout checks: startup geometry, closed, open, book, tabletop, camera, RTL, large text, and logo proportions.")
    }
}
