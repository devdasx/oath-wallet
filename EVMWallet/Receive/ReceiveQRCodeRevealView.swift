import SwiftUI
import UIKit

/// A bounded, one-shot reveal of the original QR bitmap. Core Animation owns
/// the timing; QR generation and SwiftUI layout do not run on animation frames.
struct ReceiveQRCodeRevealView: UIViewRepresentable {
    let image: CGImage
    let payload: String
    let reduceMotion: Bool
    let isSceneActive: Bool

    func makeUIView(context: Context) -> ReceiveQRCodeRevealUIView {
        ReceiveQRCodeRevealUIView()
    }

    func updateUIView(_ view: ReceiveQRCodeRevealUIView, context: Context) {
        view.configure(
            image: image,
            payload: payload,
            animated: !reduceMotion && isSceneActive
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ReceiveQRCodeRevealUIView,
        context: Context
    ) -> CGSize? {
        let side = min(proposal.width ?? 380, proposal.height ?? 380)
        return CGSize(width: side, height: side)
    }

    static func dismantleUIView(_ view: ReceiveQRCodeRevealUIView, coordinator: ()) {
        view.finishReveal()
    }
}

@MainActor
final class ReceiveQRCodeRevealUIView: UIView {
    enum RevealState {
        case waitingForDisplay, revealing, visible
    }

    static let duration: TimeInterval = 0.62
    static let tileCount = 8
    static let animationKey = "receive.qr.reveal"

    private(set) var revealState = RevealState.waitingForDisplay
    private let imageLayer = CALayer()
    private var payload: String?
    private var generation = 0
    private var completion: ReceiveQRCodeRevealCompletion?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityIgnoresInvertColors = true
        backgroundColor = UIColor(WalletTheme.qrCodeSurface)
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        layer.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(image: CGImage, payload: String, animated: Bool) {
        if self.payload != payload {
            finishReveal()
            self.payload = payload
            revealState = .waitingForDisplay
            withoutImplicitAnimation {
                imageLayer.contents = image
                // Hide the new bitmap until it has a visible, laid-out host.
                imageLayer.mask = CALayer()
            }
        }
        // A palette change updates the same payload without replaying its reveal.
        withoutImplicitAnimation {
            imageLayer.contents = image
            imageLayer.magnificationFilter = image.shouldInterpolate ? .linear : .nearest
            imageLayer.minificationFilter = image.shouldInterpolate ? .linear : .nearest
        }
        if animated {
            startRevealIfReady()
        } else {
            finishReveal()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if imageLayer.frame != bounds {
            // A rotation or size-class change must not stretch a live mask or
            // restart the reveal. The completed bitmap remains pixel-sharp.
            if revealState == .revealing { finishReveal() }
            withoutImplicitAnimation { imageLayer.frame = bounds }
        }
        startRevealIfReady()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            if revealState == .revealing { finishReveal() }
        } else {
            startRevealIfReady()
        }
    }

    func finishReveal() {
        generation += 1
        let oldMask = imageLayer.mask
        completion = nil
        revealState = .visible
        withoutImplicitAnimation { imageLayer.mask = nil }
        for tile in oldMask?.sublayers ?? [] { tile.removeAllAnimations() }
    }

    private func startRevealIfReady() {
        guard revealState == .waitingForDisplay,
              payload != nil,
              window != nil,
              bounds.width > 0, bounds.height > 0,
              imageLayer.frame == bounds else { return }

        revealState = .revealing
        generation += 1
        let currentGeneration = generation
        let completion = ReceiveQRCodeRevealCompletion { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.finishReveal()
        }
        self.completion = completion

        let mask = CALayer()
        mask.frame = bounds
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let count = Self.tileCount
        withoutImplicitAnimation {
            for row in 0..<count {
                for column in 0..<count {
                    let tile = CALayer()
                    let minX = (bounds.width * CGFloat(column) / CGFloat(count) * scale).rounded() / scale
                    let minY = (bounds.height * CGFloat(row) / CGFloat(count) * scale).rounded() / scale
                    let maxX = (bounds.width * CGFloat(column + 1) / CGFloat(count) * scale).rounded() / scale
                    let maxY = (bounds.height * CGFloat(row + 1) / CGFloat(count) * scale).rounded() / scale
                    tile.frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                    tile.backgroundColor = UIColor(WalletTheme.qrCodeInk).cgColor
                    tile.contentsScale = scale
                    tile.allowsEdgeAntialiasing = false
                    mask.addSublayer(tile)

                    // A diagonal sweep with overlapping local fades, never a
                    // transform or blur of the data modules themselves.
                    let start = 0.01 + 0.64 * Double(row + column) / Double(2 * (count - 1))
                    let animation = CAKeyframeAnimation(keyPath: "opacity")
                    animation.values = [0, 0, 1, 1]
                    animation.keyTimes = [0, NSNumber(value: start), NSNumber(value: start + 0.34), 1]
                    animation.duration = Self.duration
                    animation.timingFunctions = [
                        CAMediaTimingFunction(name: .linear),
                        CAMediaTimingFunction(name: .easeOut),
                        CAMediaTimingFunction(name: .linear)
                    ]
                    if row == count - 1 && column == count - 1 {
                        animation.delegate = completion
                    }
                    tile.add(animation, forKey: Self.animationKey)
                }
            }
            imageLayer.mask = mask
        }
    }

    private func withoutImplicitAnimation(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updates()
        CATransaction.commit()
    }
}

/// The animation delegate can be called outside actor isolation. Handoff is
/// completion-driven and generation-checked, with no delayed UI tasks.
private final class ReceiveQRCodeRevealCompletion: NSObject, CAAnimationDelegate {
    private let onCompletion: @MainActor @Sendable () -> Void

    init(onCompletion: @escaping @MainActor @Sendable () -> Void) {
        self.onCompletion = onCompletion
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag else { return }
        let onCompletion = onCompletion
        Task { @MainActor in onCompletion() }
    }
}
