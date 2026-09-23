import CoreGraphics
import Testing
@testable import SendSlideFixture

struct SendSlideReturnTests {
    @Test(arguments: [false, true], [CGFloat(-80), -24, 24, 80])
    func heldReturnFollowsTheFingerThroughVerticalDrift(isRTL: Bool, drift: CGFloat) {
        let sign: CGFloat = isRTL ? -1 : 1
        let travel: CGFloat = 300
        var drag = SendSlideDragTracking()
        // Reach the endpoint, then move back with an unchanged vertical offset.
        // Crossing x == abs(y) must not turn a sub-point step into a jump home.
        for remaining: CGFloat in [300, 200, 100, abs(drift) + 0.1, abs(drift), abs(drift) - 0.1, 10, 0] {
            let translation = CGSize(width: remaining * sign, height: drift)
            drag.update(translation: translation)
            let renderedDistance = SendSlideGesture.progress(translation: drag.projectedTranslation, travel: travel, isRTL: isRTL) * travel
            #expect(abs(renderedDistance - remaining) < 0.01,
                    "Held return: x=\(remaining), y=\(drift), rendered=\(renderedDistance)")
        }
    }

    @Test(arguments: [false, true])
    func horizontalDragRemainsReversibleAndRequiresAnActualCompletedRelease(isRTL: Bool) {
        let sign: CGFloat = isRTL ? -1 : 1
        for release: CGFloat in [269.99, 270, 300] {
            var drag = SendSlideDragTracking()
            var gesture = SendSlideGesture()
            for point in [CGSize(width: 10 * sign, height: 0),
                          CGSize(width: 300 * sign, height: 80),
                          CGSize(width: 79 * sign, height: 80),
                          CGSize(width: 0, height: 80),
                          CGSize(width: release * sign, height: 400)] {
                drag.update(translation: point)
                _ = gesture.feedbackEvent(translation: drag.projectedTranslation, travel: 300,
                                          isRTL: isRTL, enabled: true)
                #expect(!gesture.hasCommitted, "Moving, reversing and holding must never commit")
            }
            let finalTranslation = drag.projectedTranslation
            drag.finish()
            let sent = gesture.commitOnRelease(translation: finalTranslation, travel: 300, isRTL: isRTL, enabled: true)
            #expect(sent == (release >= 270), "Release uses the current position, not the furthest point reached")
            if sent {
                let duplicate = gesture.commitOnRelease(translation: finalTranslation, travel: 300, isRTL: isRTL, enabled: true)
                #expect(!duplicate)
            }
        }
    }

    @Test(arguments: [false, true])
    func initialVerticalGestureStaysRejectedAndNextTouchStartsFresh(isRTL: Bool) {
        let sign: CGFloat = isRTL ? -1 : 1
        var drag = SendSlideDragTracking()
        var gesture = SendSlideGesture()
        drag.update(translation: CGSize(width: sign, height: 10))
        drag.update(translation: CGSize(width: 300 * sign, height: 0))
        #expect(drag.projectedTranslation == .zero, "A vertical swipe cannot become a send later in that touch")
        let verticalSend = gesture.commitOnRelease(translation: drag.projectedTranslation, travel: 300, isRTL: isRTL, enabled: true)
        #expect(!verticalSend)
        drag.finish()

        drag.update(translation: CGSize(width: 10 * sign, height: 0))
        drag.update(translation: CGSize(width: 300 * sign, height: 0))
        let horizontalSend = gesture.commitOnRelease(translation: drag.projectedTranslation, travel: 300, isRTL: isRTL, enabled: true)
        #expect(horizontalSend)
        drag.finish()
        drag.update(translation: CGSize(width: 0, height: 10))
        #expect(drag.projectedTranslation == .zero, "Horizontal intent must not leak into a later vertical touch")
    }

    @Test func cancellationAndInvalidSamplesCannotKeepHorizontalIntent() {
        var drag = SendSlideDragTracking()
        drag.update(translation: CGSize(width: 150, height: 0))
        drag.reset()
        #expect(drag.projectedTranslation == .zero)
        drag.update(translation: CGSize(width: 0, height: 10))
        drag.update(translation: CGSize(width: 300, height: 0))
        #expect(drag.projectedTranslation == .zero)
        for invalid in [CGSize(width: CGFloat.nan, height: 0), CGSize(width: 300, height: CGFloat.infinity)] {
            drag.reset()
            drag.update(translation: CGSize(width: 150, height: 0))
            drag.update(translation: invalid)
            #expect(drag.projectedTranslation == .zero)
            drag.update(translation: CGSize(width: 300, height: 0))
            #expect(drag.projectedTranslation == .zero)
        }
    }
}
