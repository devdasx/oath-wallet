import SwiftUI

struct SendSlideControl: View {
    let isEnabled: Bool
    var isLoadingFee = false
    var resetID: UUID?
    let onSend: () -> Void

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var isTouching = false
    @State private var drag = SendSlideDragTracking()
    @State private var gesture = SendSlideGesture()
    @State private var gestureRevision = UUID()
    @State private var trackWidth: CGFloat = 0
    @State private var progress: CGFloat = 0
    @State private var isReturning = false
    @State private var completionID = UUID()
    @State private var didContinue = false
    @State private var didFinishCompletion = false
    @ScaledMetric(relativeTo: .body) private var scaledThumbSize = 52

    private var thumbSize: CGFloat { min(72, scaledThumbSize) }
    private var canSend: Bool {
        // The first width measurement installs the gesture's coordinate bounds.
        // A newly presented control must not accept a touch before that happens.
        isEnabled && !isLoadingFee && !gesture.hasCommitted && !isReturning && scenePhase == .active
            && travel.isFinite && travel > 0
    }
    private var isRTL: Bool { layoutDirection == .rightToLeft }
    private var travel: CGFloat { max(0, trackWidth - thumbSize - 12) }
    private var isReadyToRelease: Bool {
        canSend && isTouching && progress >= SendSlideGesture.completionProgress
    }
    private var showsIdleGuidance: Bool { canSend && !isTouching }
    private var title: LocalizedStringKey {
        isLoadingFee ? "send.review.slide_loading" : "send.review.slide_action"
    }
    private var trackColor: Color {
        isEnabled && !isLoadingFee || gesture.hasCommitted ? WalletTheme.primaryAction : WalletTheme.disabledControlFill
    }
    private var labelColor: Color {
        isEnabled && !isLoadingFee || gesture.hasCommitted ? WalletTheme.onAccentLabel : WalletTheme.disabledControlLabel
    }
    private var handleColor: Color {
        isEnabled && !isLoadingFee || gesture.hasCommitted ? WalletTheme.primaryAction : WalletTheme.disabledControlLabel
    }
    private var readinessAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.3)
    }

    var body: some View {
        SendSlideLabel(title: title, isAnimating: showsIdleGuidance,
            progress: progress, isReadyToRelease: isReadyToRelease)
            .font(.headline)
            .multilineTextAlignment(.center)
            .animation(readinessAnimation) { label in
                label.foregroundStyle(labelColor)
            }
            .padding(.horizontal, thumbSize + 12)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, minHeight: thumbSize + 12)
            .background {
                SendSlideTrack(color: trackColor, progress: progress, isComplete: gesture.hasCommitted)
                    .overlay(alignment: .trailing) {
                        // A stationary dock shows the handle's destination;
                        // it is an outline, never a moving progress fill.
                        Circle()
                            .strokeBorder(labelColor.opacity(isReadyToRelease ? 0.55 : 0.22), lineWidth: 1)
                            .frame(width: thumbSize, height: thumbSize)
                            .padding(6)
                            .opacity(canSend ? 1 : 0)
                            .animation(readinessAnimation, value: isReadyToRelease)
                    }
                    .animation(readinessAnimation, value: canSend)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .leading) {
                    Circle()
                        .fill(reduceTransparency ? WalletTheme.groupedSurface : .clear)
                        .frame(width: thumbSize, height: thumbSize)
                        .walletRegularGlassEffect(tint: WalletTheme.groupedSurface, interactive: canSend, in: Circle())
                        .overlay {
                            handleIndicator
                        }
                        // Deform only the artwork. The gesture keeps the same
                        // unscaled hit area and release distance throughout.
                        .modifier(ThumbAppearance(isPressed: isTouching,
                            progress: progress, reduceMotion: reduceMotion))
                        .overlay {
                            // Cancel stale gestures without replacing the visible glass
                            // and interrupting its disabled-to-enabled color animation.
                            Color.clear
                                .contentShape(Circle())
                                .gesture(
                                    DragGesture(minimumDistance: 0, coordinateSpace: .named("sendSlideTrack"))
                                        .updating($isTouching) { _, state, _ in
                                            state = canSend
                                        }
                                        .onChanged { value in
                                            updateSlideFeedback(translation: value.translation, travel: travel)
                                        }
                                        .onEnded { value in
                                            finishSlide(translation: value.translation, travel: travel)
                                        }
                                )
                                .id(gestureRevision)
                        }
                        .modifier(ThumbPlacement(distance: progress * travel))
            }
            .coordinateSpace(name: "sendSlideTrack")
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                trackWidth = width
                if !gesture.hasCommitted { resetGesture() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(isReadyToRelease ? "send.review.slide_release" : title))
            .accessibilityHint(canSend ? Text("send.review.slide_hint") : Text(verbatim: ""))
            .accessibilityAddTraits(gesture.hasCommitted ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction { activateAccessibly() }
            .accessibilityIdentifier("sendReviewSlideToSend")
            .focusable()
            .onKeyPress(.return) { activateAccessibly(); return .handled }
            .onKeyPress(.space) { activateAccessibly(); return .handled }
            .disabled(!canSend)
            .onChange(of: isTouching) { _, isActive in
                if isActive && canSend {
                    UniHaptic.play(.whisper)
                } else {
                    if !gesture.hasCommitted { resetGesture() }
                    drag.reset()
                    gesture.resetFeedback()
                }
            }
            .onChange(of: resetID) { _, _ in resetGesture() }
            .onChange(of: isEnabled) { _, _ in
                if !didContinue { resetGesture() }
            }
            .onChange(of: isLoadingFee) { _, _ in
                if !didContinue { resetGesture() }
            }
            .onChange(of: layoutDirection) { _, _ in
                if !didContinue { resetGesture() }
            }
            .onChange(of: scenePhase) { _, phase in
                // Face ID briefly makes the scene inactive. A committed slide
                // stays docked until the owner explicitly requests a retry.
                if phase == .active {
                    continueAfterCompletion()
                } else if !gesture.hasCommitted || (phase == .background && !didContinue) {
                    resetGesture()
                }
            }
            .onDisappear {
                if !didContinue { resetGesture() }
            }
    }

    enum Motion {
        /// Short cancellations settle quickly; longer returns take up to 0.36s.
        static func returnDuration(distance: CGFloat) -> Double {
            guard distance.isFinite else { return 0.16 }
            return min(0.36, 0.16 + Double(max(0, distance)) / 1_800)
        }
    }

    struct ThumbAppearance: ViewModifier {
        let isPressed: Bool
        let progress: CGFloat
        let reduceMotion: Bool

        private let pickupScale: CGFloat = 1.055

        private var settling: CGFloat { easedProgress(from: 0.75, to: 0.9) }
        private var compression: CGFloat { easedProgress(from: 0.9, to: 1) }

        private func easedProgress(from start: CGFloat, to end: CGFloat) -> CGFloat {
            guard isPressed, progress.isFinite else { return 0 }
            let fraction = min(1, max(0, (progress - start) / (end - start)))
            return fraction * fraction * (3 - 2 * fraction)
        }

        func body(content: Content) -> some View {
            content
                // Finger-owned deformation has no duration or readiness switch.
                // Smoothstep joins have zero slope at each boundary, so reversing
                // near 90% or the dock cannot restart a catch-up animation.
                .scaleEffect(
                    x: reduceMotion ? 1 : (pickupScale - 0.055 * settling - 0.05 * compression) / pickupScale,
                    y: reduceMotion ? 1 : (pickupScale - 0.055 * settling + 0.02 * compression) / pickupScale,
                    anchor: .trailing
                )
                // Animate pickup only; this scope cannot animate progress or
                // the gesture footprint. Keep one native trailing anchor.
                .animation(reduceMotion ? nil : .smooth(duration: 0.16)) { thumb in
                    thumb.scaleEffect(isPressed && !reduceMotion ? pickupScale : 1, anchor: .trailing)
                }
        }
    }

    /// Leading padding follows native layout direction exactly once. A signed
    /// offset is mirrored again by SwiftUI in RTL and can move outside the track.
    nonisolated struct ThumbPlacement: ViewModifier, Animatable {
        var distance: CGFloat

        var animatableData: CGFloat {
            get { distance }
            set { distance = newValue }
        }

        func body(content: Content) -> some View {
            content
                .padding(.leading, distance)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var handleIndicator: some View {
        if gesture.hasCommitted {
            let id = completionID
            SendSlideCompletionCheckmark(
                symbolSize: thumbSize * 0.42,
                tint: handleColor,
                reduceMotion: reduceMotion,
                onCompletion: { finished in finishCompletion(id: id, finished: finished) }
            )
            .frame(width: thumbSize, height: thumbSize)
            .id(id)
            .accessibilityHidden(true)
        } else if isLoadingFee {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
                .tint(WalletTheme.disabledControlLabel)
                .accessibilityHidden(true)
        } else {
            SendSlideDirectionIndicator(
                isAnimating: showsIdleGuidance,
                symbolSize: thumbSize * 0.27
            )
                .foregroundStyle(handleColor)
                .animation(readinessAnimation, value: canSend)
                .accessibilityHidden(true)
        }
    }

    private func activateAccessibly() {
        // Accessibility and keyboard activation use the same completion path.
        if gesture.activateAccessibly(enabled: canSend) { dockThumb() }
    }

    private func updateSlideFeedback(translation: CGSize, travel: CGFloat) {
        guard canSend else { return }
        drag.update(translation: translation)
        let projected = drag.projectedTranslation
        // Only the finger drives tracking. Return/docking animations must never
        // introduce lag into the next drag.
        withTransaction(Transaction(animation: nil)) {
            progress = SendSlideGesture.progress(translation: projected, travel: travel, isRTL: isRTL)
        }
        switch gesture.feedbackEvent(translation: projected, travel: travel, isRTL: isRTL, enabled: canSend) {
        case .none: break
        case .checkpoint: UniHaptic.play(.progressTick)
        case .ready: UniHaptic.play(.increase)
        case .retreated: UniHaptic.play(.decrease)
        }
    }

    private func finishSlide(translation: CGSize, travel: CGFloat) {
        guard canSend else { return }
        drag.update(translation: translation)
        let projected = drag.projectedTranslation
        drag.finish()
        // Evaluate the actual final position, never the furthest position reached
        // or predicted momentum. Keeping a finger down leaves the action reversible.
        if gesture.commitOnRelease(
            translation: projected, travel: travel, isRTL: isRTL, enabled: canSend
        ) {
            dockThumb()
        } else {
            resetGesture()
        }
    }

    private func finishCompletion(id: UUID, finished: Bool) {
        guard id == completionID, gesture.hasCommitted, !didContinue else { return }
        guard finished, isEnabled, !isLoadingFee else {
            resetGesture()
            return
        }
        didFinishCompletion = true
        continueAfterCompletion()
    }

    private func continueAfterCompletion() {
        guard gesture.hasCommitted, didFinishCompletion, !didContinue,
              isEnabled, !isLoadingFee, scenePhase == .active else { return }
        didContinue = true
        onSend()
    }

    private func dockThumb() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.16)) {
            progress = 1
        }
    }

    private func resetGesture() {
        // Repeated lifecycle/availability updates must not interrupt a return
        // already in flight and snap its presentation back to zero.
        guard !isReturning else { return }
        let id = UUID()
        completionID = id
        didContinue = false
        didFinishCompletion = false
        gestureRevision = id
        drag.reset()
        gesture.reset()
        let distance = progress * travel
        isReturning = !reduceMotion && distance > 0
        withAnimation(
            isReturning ? .spring(duration: Motion.returnDuration(distance: distance), bounce: 0) : nil,
            completionCriteria: .logicallyComplete
        ) {
            progress = 0
        } completion: {
            guard completionID == id else { return }
            isReturning = false
        }
    }
}
