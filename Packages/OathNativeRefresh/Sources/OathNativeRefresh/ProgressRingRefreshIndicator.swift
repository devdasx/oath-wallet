import SwiftUI
import UIKit
import Observation

/// Native content hosting keeps SwiftUI's blur replacement inside UIRefreshControl.
/// The loading stroke still runs on Core Animation, without a per-frame timer.
@MainActor final class ProgressRingRefreshIndicator: UIView {
    static let transitionDuration: TimeInterval = 0.5
    static let resultHoldDuration: TimeInterval = 0.8

    private let model = RingPresentationModel()
    private lazy var content = UIHostingConfiguration {
        RingPresentation(model: model)
    }.margins(.all, 0).makeContentView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        addSubview(content)
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
    }

    func update(cycle: RefreshCycle, tint: UIColor, labels: NativeRefreshLabels,
                active: Bool, reduceMotion: Bool) {
        let next = RingPresentationState(cycle: cycle, tint: tint, labels: labels,
                                         active: active, reduceMotion: reduceMotion)
        guard next != model.state else { return }
        let replacesRing = model.state.cycle.phase == .refreshing && next.isResult
        content.accessibilityIdentifier = next.isResult
            ? (cycle.phase == .failed ? "refresh.ring.failure" : "refresh.ring.success")
            : "refresh.ring.content"
        withAnimation(replacesRing && active && !reduceMotion
                      ? .easeInOut(duration: Self.transitionDuration) : nil) {
            model.state = next
        }
    }
}

private struct RingPresentationState: Equatable {
    var cycle = RefreshCycle()
    var tint = UIColor.white
    var labels = NativeRefreshLabels.english
    var active = true
    var reduceMotion = false
    var isResult: Bool {
        [.succeeded, .acknowledged, .failed].contains(cycle.phase)
    }
    var label: String {
        switch cycle.phase {
        case .idle, .pulling: labels.pull
        case .refreshing, .acknowledged: labels.refreshing
        case .succeeded: labels.succeeded
        case .failed: labels.failed
        }
    }
}

@MainActor @Observable private final class RingPresentationModel {
    var state = RingPresentationState()
}

private struct RingPresentation: View {
    let model: RingPresentationModel
    var body: some View {
        let state = model.state
        ZStack {
            if state.isResult {
                Image(systemName: state.cycle.phase == .failed ? "exclamationmark" : "checkmark")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color(uiColor: state.tint))
                    .frame(width: 28, height: 28)
                    .accessibilityIdentifier(state.cycle.phase == .failed
                        ? "refresh.ring.failure" : "refresh.ring.success")
                    .transition(.blurReplace)
            } else {
                LoadingRing(state: state)
                    .frame(width: 28, height: 28)
                    .transition(.blurReplace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.label)
        .accessibilityValue(state.cycle.phase == .pulling
            ? state.cycle.progress.formatted(.percent.precision(.fractionLength(0))) : "")
    }
}

private struct LoadingRing: UIViewRepresentable {
    let state: RingPresentationState
    func makeUIView(context: Context) -> LoadingRingView { LoadingRingView() }
    func updateUIView(_ view: LoadingRingView, context: Context) { view.update(state) }
}

@MainActor private final class LoadingRingView: UIView {
    private let track = CAShapeLayer()
    private let stroke = CAShapeLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        for shape in [track, stroke] {
            shape.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
            shape.path = RefreshRingGeometry.circle
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 2.5
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
    }
    required init?(coder: NSCoder) { nil }

    func update(_ state: RingPresentationState) {
        let loading = state.cycle.phase == .refreshing
        let animates = loading && state.active && !state.reduceMotion
        if !animates { stroke.removeAllAnimations() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = state.tint.withAlphaComponent(0.18).cgColor
        stroke.strokeColor = state.tint.cgColor
        stroke.strokeEnd = loading ? (animates ? 1 : 0.78) : state.cycle.progress
        track.opacity = state.cycle.phase == .idle ? 0 : 1
        stroke.opacity = track.opacity
        CATransaction.commit()
        if animates { startLoadingIfNeeded() }
        accessibilityIdentifier = loading ? "refresh.ring.loading" : "refresh.ring.pulling"
    }

    private func startLoadingIfNeeded() {
        guard stroke.animation(forKey: "ringRotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 0.85
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        stroke.add(rotation, forKey: "ringRotation")

        // Start and end with the complete pull circle. Matching endpoints
        // prevent a seam while the arc smoothly contracts and opens again.
        let sweep = CAKeyframeAnimation(keyPath: "strokeEnd")
        sweep.values = [1, 0.22, 0.86, 1]
        sweep.keyTimes = [0, 0.45, 0.85, 1]
        sweep.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
        sweep.duration = 1.15
        sweep.repeatCount = .infinity
        stroke.add(sweep, forKey: "ringSweep")
    }
}
