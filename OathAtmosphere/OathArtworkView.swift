import MetalKit

/// UIKit commits bundled artwork with the other welcome elements. The Metal
/// layer is transparent until it presents a complete, opaque frame over it.
@MainActor
final class OathArtworkView: UIView {
    let metal = OathMetalCanvas()
    private let startup = OathStartupArtworkView()
    var onLayout: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = false
        clipsToBounds = true
        addSubview(startup)
        metal.metalLayer.pixelFormat = .bgra8Unorm
        metal.metalLayer.framebufferOnly = true
        metal.metalLayer.allowsNextDrawableTimeout = true
        metal.metalLayer.isOpaque = false
        metal.isOpaque = false
        metal.backgroundColor = .clear
        metal.isAccessibilityElement = false
        metal.isUserInteractionEnabled = false
        addSubview(metal)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-oath-artwork-diagnostics") {
            isAccessibilityElement = true
            accessibilityIdentifier = "onboarding.artwork"
            accessibilityLabel = "Welcome artwork"
            accessibilityValue = "bundled"
        }
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateStartup(dark: Bool, colorway: OathColorway, customColor: UInt32? = nil, placement: OathArtworkPlacement?) {
        startup.update(dark: dark, colorway: colorway, customColor: customColor, placement: placement)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        startup.frame = bounds
        metal.frame = bounds
        startup.setNeedsLayout()
        onLayout?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onLayout?()
    }

    func didRenderArtwork() {
        // Keep the image underneath permanently: GPU completion is not display
        // presentation. The opaque drawable replaces it atomically when Core
        // Animation presents it, including on SDKs without presentation callbacks.
        startup.setPosterNeeded(false)
        #if DEBUG
        accessibilityValue = "rendered"
        #endif
    }

    func showStartupArtwork() {
        startup.isHidden = false
        startup.setPosterNeeded(true)
        metal.isHidden = true
        #if DEBUG
        accessibilityValue = "bundled"
        #endif
    }
}

/// UIKit owns geometry. Only the render worker acquires and presents drawables.
/// A display link schedules snapshots; no Metal wait runs on the UI thread.
@MainActor
final class OathMetalCanvas: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

/// The poster is rendered from the same shader at build time. Its logo, fade,
/// and solid action pane follow the same layout as Metal, including RTL/folds.
/// No file decoding, download, or GPU completion is awaited after showing UI.
@MainActor
private final class OathStartupArtworkView: UIView {
    private let material = UIView()
    private let silk = UIImageView()
    private let readableMaterial = UIView()
    private let readableSilk = UIImageView()
    private let readingMask = CAGradientLayer()
    private let readingHorizontalMask = CAGradientLayer()
    private let fade = CAGradientLayer()
    private let logoClip = UIView()
    private let logo = UIImageView()
    private let actionPanel = UIView()
    private var placement: OathArtworkPlacement?
    private var dark = false
    private var colorway: OathColorway?
    private var customColor: UInt32?
    private var posterTask: Task<Void, Never>?
    private var posterNeeded = true
    private var lastLayout: Layout?

    private struct Layout: Equatable {
        let size: CGSize
        let safeTop: CGFloat
        let placement: OathArtworkPlacement?
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = true
        material.clipsToBounds = true
        silk.contentMode = .scaleToFill
        material.addSubview(silk)
        readableSilk.contentMode = .scaleToFill
        readableMaterial.addSubview(readableSilk)
        readableMaterial.layer.mask = readingMask
        material.addSubview(readableMaterial)
        addSubview(material)
        logo.contentMode = .scaleToFill
        logo.layer.minificationFilter = .trilinear
        logoClip.clipsToBounds = true
        logoClip.addSubview(logo)
        addSubview(logoClip)
        addSubview(actionPanel)
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        readingMask.startPoint = CGPoint(x: 0.5, y: 0)
        readingMask.endPoint = CGPoint(x: 0.5, y: 1)
        readingHorizontalMask.startPoint = CGPoint(x: 0, y: 0.5)
        readingHorizontalMask.endPoint = CGPoint(x: 1, y: 0.5)
        readingMask.mask = readingHorizontalMask
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(dark: Bool, colorway: OathColorway, customColor: UInt32?, placement: OathArtworkPlacement?) {
        if self.dark != dark || self.colorway != colorway || self.customColor != customColor {
            posterTask?.cancel()
            let appearance = dark ? "dark" : "light"
            // UIImage's local resource cache shares these across welcome visits.
            silk.image = customColor == nil ? UIImage(named: "OathStartup-\(colorway.rawValue)-\(appearance).jpg") : nil
            readableSilk.image = customColor == nil ? UIImage(named: "OathStartup-\(colorway.rawValue)-\(appearance)-reading.jpg") : nil
            logo.image = UIImage(named: "OathStartup-logo-\(appearance).png")
            let colors = customColor.map(OathSilkColors.custom) ?? colorway.colors
            let rest = dark ? colors.darkRest : colors.lightRest
            let deep = dark ? colors.darkDeep : colors.lightDeep
            material.backgroundColor = UIColor(red: CGFloat(deep.x), green: CGFloat(deep.y), blue: CGFloat(deep.z), alpha: 1)
            backgroundColor = UIColor(red: CGFloat(rest.x), green: CGFloat(rest.y), blue: CGFloat(rest.z), alpha: 1)
            actionPanel.backgroundColor = dark ? backgroundColor : .white
            self.dark = dark
            self.colorway = colorway
            self.customColor = customColor
            preparePosterIfNeeded()
        }
        if self.placement != placement {
            self.placement = placement
            setNeedsLayout()
        }
    }

    func setPosterNeeded(_ needed: Bool) {
        guard posterNeeded != needed else { return }
        posterNeeded = needed
        posterTask?.cancel()
        if needed { preparePosterIfNeeded() }
    }

    private func preparePosterIfNeeded() {
        guard posterNeeded, let customColor else { return }
        let dark = dark
        posterTask = Task { [weak self] in
            // A live color preview already runs in Metal. Do not also perform
            // CPU image filtering behind every color-picker update. The poster
            // is only needed for startup, critical heat, or renderer recovery.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let poster = await OathCustomArtworkPoster.shared.images(rgb: customColor, dark: dark)
            guard !Task.isCancelled, let self, posterNeeded,
                  self.customColor == customColor, self.dark == dark, let poster else { return }
            silk.image = UIImage(cgImage: poster.silk)
            readableSilk.image = UIImage(cgImage: poster.reading)
        }
    }

    deinit { posterTask?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let layout = Layout(size: bounds.size, safeTop: max(safeAreaInsets.top, window?.safeAreaInsets.top ?? 0),
                            placement: placement)
        guard layout != lastLayout else { return }
        lastLayout = layout
        let frame = OathArtworkFrame(size: layout.size, safeTop: layout.safeTop, placement: placement)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        material.frame = bounds
        // The shader measures folds in screen-width units around y = 0.32.
        // Preserve that scale and anchor instead of stretching/cropping a phone
        // screenshot when the available size changes.
        let artworkHeight = bounds.width * 2.5
        silk.frame = CGRect(x: 0, y: (bounds.height - artworkHeight) * 0.32,
                            width: bounds.width, height: artworkHeight)
        readableMaterial.frame = bounds
        readableSilk.frame = silk.frame
        readableMaterial.isHidden = !OathLayoutGeometry.isUsable(frame.copy)
        readingMask.frame = bounds
        readingHorizontalMask.frame = bounds
        configureReadingGradient(readingMask, start: frame.copy.minY / bounds.height, end: frame.copy.maxY / bounds.height)
        configureReadingGradient(readingHorizontalMask, start: frame.copy.minX / bounds.width, end: frame.copy.maxX / bounds.width)
        logoClip.frame = frame.logoClip
        logo.frame = frame.logo.offsetBy(dx: -frame.logoClip.minX, dy: -frame.logoClip.minY)
        if let divider = frame.divider {
            material.layer.mask = nil
            actionPanel.isHidden = false
            actionPanel.frame = frame.actionsOnRight
                ? CGRect(x: divider, y: 0, width: max(0, bounds.width - divider), height: bounds.height)
                : CGRect(x: 0, y: 0, width: max(0, divider), height: bounds.height)
        } else {
            actionPanel.isHidden = true
            fade.frame = bounds
            let steps = (0...16).map { CGFloat($0) / 16 }
            fade.locations = steps.map { NSNumber(value: Double(min(1, max(0, frame.fadeStart + $0 * (frame.fadeEnd - frame.fadeStart))))) }
            fade.colors = steps.map { UIColor(white: 1, alpha: 1 - $0 * $0 * (3 - 2 * $0)).cgColor }
            material.layer.mask = fade
        }
        CATransaction.commit()
    }

    private func configureReadingGradient(_ gradient: CAGradientLayer, start: CGFloat, end: CGFloat) {
        // Mask shadows are clipped to their layer's bounds. Explicit gradients
        // cover the whole canvas, retaining soft edges outside the copy rect.
        let steps = (0...16).map { CGFloat($0) / 16 }
        let positions = steps.map { start - 0.065 + $0 * 0.065 } + steps.map { end + $0 * 0.065 }
        let alphas = steps.map { $0 * $0 * (3 - 2 * $0) } + steps.map { 1 - $0 * $0 * (3 - 2 * $0) }
        gradient.locations = positions.map { NSNumber(value: Double(min(1, max(0, $0)))) }
        gradient.colors = alphas.map { UIColor(white: 1, alpha: $0).cgColor }
    }
}
