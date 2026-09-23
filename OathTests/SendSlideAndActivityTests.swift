import SwiftUI
import Observation
import Testing
@testable import Aperture

struct SendSlideGestureTests {
    @Test(arguments: [false, true])
    func readinessFeedbackIsQuietDuringThresholdJitter(isRTL: Bool) {
        let sign: CGFloat = isRTL ? -1 : 1
        var gesture = SendSlideGesture()
        func event(at progress: CGFloat) -> SendSlideGesture.FeedbackEvent {
            gesture.feedbackEvent(translation: CGSize(width: 1_000 * progress * sign, height: 0),
                                  travel: 1_000, isRTL: isRTL, enabled: true)
        }

        #expect(event(at: 0.8999) == .checkpoint)
        #expect(event(at: 0.90) == .ready)
        for progress: CGFloat in [0.90, 0.8999, 0.91, 0.89, 1, 0.8501, 0.90, 1] {
            #expect(event(at: progress) == .none)
            #expect(!gesture.hasCommitted)
        }
        // Feedback remains latched, but releasing even just below 90% still cancels.
        let released = gesture.commitOnRelease(translation: CGSize(width: 899.9 * sign, height: 0),
                                               travel: 1_000, isRTL: isRTL, enabled: true)
        #expect(!released)
        #expect(event(at: 0.90) == .ready)
    }

    @Test(arguments: [false, true])
    func deliberateRetreatRearmsReadinessOncePerApproach(isRTL: Bool) {
        let sign: CGFloat = isRTL ? -1 : 1
        var gesture = SendSlideGesture()
        func event(at progress: CGFloat) -> SendSlideGesture.FeedbackEvent {
            gesture.feedbackEvent(translation: CGSize(width: 1_000 * progress * sign, height: 0),
                                  travel: 1_000, isRTL: isRTL, enabled: true)
        }

        #expect(event(at: 1) == .ready)
        #expect(event(at: 0.8501) == .none)
        #expect(event(at: 0.85) == .retreated)
        #expect(event(at: 0.85) == .none)
        #expect(event(at: 0.8999) == .none)
        #expect(event(at: 0.90) == .ready)
        #expect(event(at: 0.86) == .none)
        #expect(event(at: 0.81) == .retreated)
        #expect(event(at: 0.72) == .checkpoint)
        #expect(event(at: 0.81) == .checkpoint)
        #expect(event(at: 0.90) == .ready)
        #expect(!gesture.hasCommitted)
    }

    @Test func resettingGestureRestoresReadinessFeedbackWithoutChangingCommitRules() {
        var gesture = SendSlideGesture()
        let end = CGSize(width: 300, height: 0)
        func event(enabled: Bool = true) -> SendSlideGesture.FeedbackEvent {
            gesture.feedbackEvent(translation: end, travel: 300, isRTL: false, enabled: enabled)
        }

        #expect(event() == .ready)
        #expect(event(enabled: false) == .none)
        let invalid = gesture.feedbackEvent(translation: CGSize(width: 300, height: 400),
                                            travel: 300, isRTL: false, enabled: true)
        #expect(invalid == .none)
        #expect(event() == .none)
        gesture.resetFeedback()
        #expect(event() == .ready)
        #expect(!gesture.hasCommitted)
        let committed = gesture.commitOnRelease(translation: end, travel: 300, isRTL: false, enabled: true)
        #expect(committed)
        #expect(event() == .none)
        gesture.reset()
        #expect(event() == .ready)
        #expect(!gesture.hasCommitted)
    }

    @Test(arguments: [false, true])
    func progressFeedbackTracksCheckpointsWithoutCommitting(isRTL: Bool) {
        let sign: CGFloat = isRTL ? -1 : 1
        var gesture = SendSlideGesture()
        var ticks = 0
        for step in 1...10 {
            let translation = CGSize(width: (CGFloat(step) * 27 + 0.01) * sign, height: 0)
            if gesture.updateFeedback(translation: translation, travel: 300, isRTL: isRTL, enabled: true) {
                ticks += 1
            }
            // Rendering the same finger position must not emit another tick.
            let repeated = gesture.updateFeedback(translation: translation, travel: 300, isRTL: isRTL, enabled: true)
            #expect(!repeated)
            #expect(!gesture.hasCommitted)
        }
        #expect(ticks == 10)
        let backward = CGSize(width: 160 * sign, height: 0)
        let movedBack = gesture.updateFeedback(translation: backward, travel: 300, isRTL: isRTL, enabled: true)
        let repeatedBack = gesture.updateFeedback(translation: backward, travel: 300, isRTL: isRTL, enabled: true)
        #expect(movedBack)
        #expect(!repeatedBack)
        gesture.resetFeedback()
        let restarted = gesture.updateFeedback(translation: CGSize(width: 30 * sign, height: 0),
                                                travel: 300, isRTL: isRTL, enabled: true)
        #expect(restarted)
        #expect(!gesture.hasCommitted)
    }

    @Test func feedbackIgnoresBlockedInvalidAndFinishedGestures() {
        var gesture = SendSlideGesture()
        let translation = CGSize(width: 100, height: 0)
        let disabled = gesture.updateFeedback(translation: translation, travel: 300, isRTL: false, enabled: false)
        #expect(!disabled)
        for value in [CGSize(width: -100, height: 0), CGSize(width: CGFloat.infinity, height: 0),
                      CGSize(width: 100, height: 150), CGSize(width: 100, height: CGFloat.nan)] {
            let invalid = gesture.updateFeedback(translation: value, travel: 300, isRTL: false, enabled: true)
            #expect(!invalid)
        }
        for travel in [CGFloat.zero, -1, .infinity, .nan] {
            let invalid = gesture.updateFeedback(translation: translation, travel: travel, isRTL: false, enabled: true)
            #expect(!invalid)
        }
        let committed = gesture.commitOnRelease(translation: CGSize(width: 300, height: 0), travel: 300,
                                        isRTL: false, enabled: true)
        let afterCommit = gesture.updateFeedback(translation: translation, travel: 300, isRTL: false, enabled: true)
        #expect(committed)
        #expect(!afterCommit)
        gesture.reset()
        let afterReset = gesture.updateFeedback(translation: translation, travel: 300, isRTL: false, enabled: true)
        #expect(afterReset)
    }

    @Test(arguments: [false, true])
    func onlyACompletedDragInTheReadingDirectionSends(isRTL: Bool) {
        let sign: CGFloat = isRTL ? -1 : 1
        var gesture = SendSlideGesture()
        for drag in [CGSize.zero, CGSize(width: -300 * sign, height: 0),
                     CGSize(width: 180 * sign, height: 0), CGSize(width: 300 * sign, height: 400)] {
            let committed = gesture.commitOnRelease(translation: drag, travel: 300, isRTL: isRTL, enabled: true)
            #expect(!committed)
        }
        let fullDrag = CGSize(width: 300 * sign, height: 0)
        let disabled = gesture.commitOnRelease(translation: fullDrag, travel: 300, isRTL: isRTL, enabled: false)
        #expect(!disabled)
        let completed = gesture.commitOnRelease(translation: fullDrag, travel: 300, isRTL: isRTL, enabled: true)
        #expect(completed)
        let duplicate = gesture.commitOnRelease(translation: fullDrag, travel: 300, isRTL: isRTL, enabled: true)
        #expect(!duplicate)
        let repeatedActivation = gesture.activateAccessibly(enabled: true)
        #expect(!repeatedActivation)
        gesture.reset()
        let resetActivation = gesture.activateAccessibly(enabled: true)
        #expect(resetActivation)
    }

    @Test func invalidGeometryAndDisabledAccessibilityCannotSend() {
        var gesture = SendSlideGesture()
        let disabled = gesture.activateAccessibly(enabled: false)
        #expect(!disabled)
        for travel in [CGFloat.zero, -1, .infinity, .nan] {
            let committed = gesture.commitOnRelease(translation: CGSize(width: 500, height: 0),
                                           travel: travel, isRTL: false, enabled: true)
            #expect(!committed)
        }
    }

    @Test(arguments: [false, true])
    func reachingAndHoldingTheEndDoesNotCommitUntilRelease(isRTL: Bool) {
        let sign: CGFloat = isRTL ? -1 : 1
        for drift: CGFloat in [-90, 90] {
            var gesture = SendSlideGesture()
            for width: CGFloat in [150, 270, 300, 300, 300] {
                _ = gesture.updateFeedback(translation: CGSize(width: width * sign, height: drift),
                                           travel: 300, isRTL: isRTL, enabled: true)
                #expect(!gesture.hasCommitted)
            }
            let endpoint = CGSize(width: 300 * sign, height: drift)
            #expect(SendSlideGesture.progress(translation: endpoint, travel: 300, isRTL: isRTL) == 1)
            let released = gesture.commitOnRelease(translation: endpoint, travel: 300, isRTL: isRTL, enabled: true)
            #expect(released)
            #expect(gesture.hasCommitted)
            let duplicate = gesture.commitOnRelease(translation: endpoint, travel: 300, isRTL: isRTL, enabled: true)
            #expect(!duplicate)
        }
    }

    @Test(arguments: [false, true])
    func returningBelowThresholdCancelsAndAnotherDragCanSend(isRTL: Bool) {
        let sign: CGFloat = isRTL ? -1 : 1
        var gesture = SendSlideGesture()
        for width: CGFloat in [150, 270, 300, 280, 269] {
            _ = gesture.updateFeedback(translation: CGSize(width: width * sign, height: 0),
                                       travel: 300, isRTL: isRTL, enabled: true)
            #expect(!gesture.hasCommitted)
        }
        let cancelled = gesture.commitOnRelease(translation: CGSize(width: 269 * sign, height: 0),
                                                 travel: 300, isRTL: isRTL, enabled: true)
        #expect(!cancelled)
        #expect(!gesture.hasCommitted)
        // A cancelled release silently resets checkpoints for the next gesture.
        let nextTick = gesture.updateFeedback(translation: CGSize(width: 30 * sign, height: 0),
                                               travel: 300, isRTL: isRTL, enabled: true)
        #expect(nextTick)
        let sent = gesture.commitOnRelease(translation: CGSize(width: 270 * sign, height: 0),
                                            travel: 300, isRTL: isRTL, enabled: true)
        #expect(sent)
    }

    @Test(arguments: [false, true])
    func releaseRequiresAtLeastNinetyPercentOfActualTravel(isRTL: Bool) {
        let sign: CGFloat = isRTL ? -1 : 1
        for width: CGFloat in [0, 269.99, 270, 270.01, 300] {
            var gesture = SendSlideGesture()
            let sent = gesture.commitOnRelease(translation: CGSize(width: width * sign, height: 0),
                                                travel: 300, isRTL: isRTL, enabled: true)
            #expect(sent == (width >= 270))
        }
    }

    @Test(arguments: [false, true])
    func invalidMovementNeverLooksCompleteOrCommits(isRTL: Bool) {
        let sign: CGFloat = isRTL ? -1 : 1
        for sample in [CGSize(width: 300 * sign, height: 400),
                       CGSize(width: 300 * sign, height: CGFloat.nan),
                       CGSize(width: CGFloat.infinity * sign, height: 0)] {
            var gesture = SendSlideGesture()
            #expect(SendSlideGesture.progress(translation: sample, travel: 300, isRTL: isRTL) == 0)
            let committed = gesture.commitOnRelease(translation: sample, travel: 300, isRTL: isRTL, enabled: true)
            #expect(!committed)
        }
    }
}

@MainActor
struct SendOperationLifetimeTests {
    @Test func closingAndReopeningDetailsDoesNotCancelOrRepeatSubmission() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await SendRecipientHistoryTestFixtures.seed(database)
        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "a", count: 64))
        let draft = SendEntryTestFixtures.draft(recipient: receipt.toAddress, amount: receipt.amount)
        let operation = SendOperation(database: database, draft: draft, walletAddress: receipt.fromAddress,
                                      nativeUnitUSDPrice: nil, statusReader: { _ in .confirmed })
        let (stream, continuation) = AsyncStream<SendTransactionSubmissionOutcome>.makeStream()
        let counter = SubmissionInvocationCounter()
        operation.start {
            await counter.increment()
            var iterator = stream.makeAsyncIterator()
            return try #require(await iterator.next())
        }
        let store = SendActivityStore()
        store.presentedOperation = operation
        store.finishDetails(operation)
        #expect(store.presentedOperation == nil)
        #expect(operation.isSubmitting)
        #expect(!operation.isAcknowledged)
        store.presentedOperation = operation
        operation.start {
            await counter.increment()
            throw SendTransactionSubmissionError.invalidAmount
        }
        continuation.yield(.init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: nil))
        continuation.finish()
        await operation.waitUntilSettled()
        #expect(await counter.count == 1)
        #expect(operation.networkStatus == .confirmed)
        #expect(operation.receipt == receipt)
        #expect(operation.receiptVisualStatus == .confirmed)
        #expect(!operation.canRetry)
    }

    @Test func definiteFailureAndUnknownOutcomeHaveDifferentRetryRules() async throws {
        let database = try WalletDatabase.temporary()
        let errors: [SendTransactionSubmissionError] = [
            .broadcastRejected(code: "rejected", message: "Rejected"),
            .broadcastOutcomeUnknown(networkID: "eth", code: "timeout")
        ]
        for (index, error) in errors.enumerated() {
            let operation = SendOperation(database: database, draft: SendEntryTestFixtures.draft(),
                                          walletAddress: "wallet", nativeUnitUSDPrice: nil)
            operation.start { throw error }
            await operation.waitUntilSettled()
            #expect(operation.canRetry == (index == 0))
            #expect(operation.receiptVisualStatus == (index == 0 ? .failed : .warning))
            let store = SendActivityStore()
            store.retry(operation)
            #expect((store.pendingRetry != nil) == (index == 0))
        }
    }

    @Test func unknownSubmissionCanBecomeConfirmedWithoutAnotherBroadcast() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await SendRecipientHistoryTestFixtures.seed(database)
        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "b", count: 64))
        let operation = SendOperation(database: database,
            draft: SendEntryTestFixtures.draft(recipient: receipt.toAddress, amount: receipt.amount),
            walletAddress: receipt.fromAddress, nativeUnitUSDPrice: nil, statusReader: { _ in .confirmed })
        operation.start {
            throw SendTransactionSubmissionError.broadcastOutcomeUnknown(
                networkID: "eth", code: "timeout", receipt: receipt)
        }
        await operation.waitUntilSettled()
        #expect(operation.networkStatus == .confirmed)
        #expect(operation.heroCopy == .confirmed)
        #expect(operation.localTransactionID != nil)
        #expect(!operation.canRetry)
    }
}

private actor SubmissionInvocationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor @Suite(.serialized)
struct NativeSendSlideControlTests {
    @Test(arguments: NativeListTestLayout.allCases)
    func feeLoadingUpdatesLabelAndBlocksActivationUntilReady(layout: NativeListTestLayout) async throws {
        let state = SlideLoadingTestState()
        let host = try NativeListTestHost(layout: layout) {
            SlideLoadingTestView(state: state)
        }
        defer { host.close() }
        let locale = layout.direction == .rightToLeft ? "ar" : "en"
        let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let loadingTitle = bundle.localizedString(forKey: "send.review.slide_loading", value: nil, table: nil)
        let readyTitle = bundle.localizedString(forKey: "send.review.slide_action", value: nil, table: nil)
        func control() -> NSObject? {
            SendEntryUIProbe.element("sendReviewSlideToSend", in: host.rootView)
        }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            control()?.accessibilityLabel == loadingTitle
        }
        let loading = try #require(control())
        #expect(loading.accessibilityTraits.contains(.notEnabled))
        #expect(loading.accessibilityHint?.isEmpty != false)
        _ = loading.accessibilityActivate()
        #expect(state.sends == 0)
        #expect(!loading.accessibilityFrame.isEmpty)

        // A failed preflight ends loading without making the slider actionable.
        state.isEnabled = false
        state.isLoadingFee = false
        try await SendEntryUIProbe.wait(in: host.rootView) {
            control()?.accessibilityLabel == readyTitle
        }
        #expect(try #require(control()).accessibilityTraits.contains(.notEnabled))
        _ = control()?.accessibilityActivate()
        #expect(state.sends == 0)

        state.isLoadingFee = true
        try await SendEntryUIProbe.wait(in: host.rootView) {
            control()?.accessibilityLabel == loadingTitle
        }
        state.isLoadingFee = false
        state.isEnabled = true
        try await SendEntryUIProbe.wait(in: host.rootView) {
            control()?.accessibilityLabel == readyTitle
                && control()?.accessibilityTraits.contains(.notEnabled) == false
        }
        #expect(control()?.accessibilityHint?.isEmpty == false)
        _ = control()?.accessibilityActivate()
        _ = control()?.accessibilityActivate()
        #expect(state.sends == 1)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func accessibleSlideIsReadableAndOnlyActivatesOnce(layout: NativeListTestLayout) async throws {
        var sends = 0
        let host = try NativeListTestHost(layout: layout) {
            SendSlideControl(isEnabled: true) { sends += 1 }
                .padding(20)
                .environment(\.scenePhase, .active)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendReviewSlideToSend", in: host.rootView) != nil
        }
        let control = try #require(SendEntryUIProbe.element("sendReviewSlideToSend", in: host.rootView))
        #expect(!control.accessibilityTraits.contains(.notEnabled))
        #expect(control.accessibilityActivate())
        _ = control.accessibilityActivate()
        #expect(sends == 1)
        #expect(!control.accessibilityFrame.isEmpty)
    }
}

@MainActor @Observable
private final class SlideLoadingTestState {
    // Loading itself must prevent activation, even if a caller passes enabled.
    var isEnabled = true
    var isLoadingFee = true
    var sends = 0
}

private struct SlideLoadingTestView: View {
    let state: SlideLoadingTestState

    var body: some View {
        SendSlideControl(isEnabled: state.isEnabled, isLoadingFee: state.isLoadingFee) {
            state.sends += 1
        }
        .padding(20)
        .environment(\.scenePhase, .active)
    }
}
