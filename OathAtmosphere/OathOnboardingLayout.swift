import Foundation
import CoreGraphics

/// Navigation can propose an empty size before its first visible layout.
/// Never let null rectangles or invalid measurements reach SwiftUI or Metal.
enum OathLayoutGeometry {
    static func finiteSize(_ size: CGSize) -> CGSize {
        CGSize(width: size.width.isFinite ? max(0, size.width) : 0,
               height: size.height.isFinite ? max(0, size.height) : 0)
    }

    static func isFinite(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }

    static func isUsable(_ rect: CGRect) -> Bool {
        isFinite(rect) && rect.width > 0 && rect.height > 0
    }
}

/// Content coordinates, after system safe areas. No device names or screen constants.
struct OathOnboardingLayout: Equatable {
    enum Arrangement: Equatable { case stacked, spread, tabletop }

    let arrangement: Arrangement
    let introduction: CGRect
    let actions: CGRect
    let logoSize: CGSize
    let introductionTopPadding: CGFloat
    let spreadDivider: CGFloat?

    init(
        size: CGSize,
        actionHeight: CGFloat,
        introductionHeight: CGFloat,
        divisions: [CGRect] = [],
        occlusions: [CGRect] = [],
        rightToLeft: Bool = false
    ) {
        let size = OathLayoutGeometry.finiteSize(size)
        let actionHeight = actionHeight.isFinite ? max(0, actionHeight) : 200
        let introductionHeight = introductionHeight.isFinite ? max(0, introductionHeight) : 175
        let bounds = CGRect(origin: .zero, size: size)
        let margin = OathActionMetrics.screenMargin(for: size.width)
        let horizontalInset = min(margin, size.width / 2)
        let verticalInset = min(16, size.height / 2)
        // insetBy returns CGRect.null (infinite origin) when the inset exceeds
        // the proposed size. Construct a finite empty rectangle instead.
        let content = CGRect(x: horizontalInset, y: verticalInset,
                             width: max(0, size.width - 2 * horizontalInset),
                             height: max(0, size.height - 2 * verticalInset))
        var hero: CGRect
        var controls: CGRect
        let mode: Arrangement

        // Reserved-region frames already include Apple's recommended margins.
        var fold: CGRect?
        for division in divisions {
            guard OathLayoutGeometry.isUsable(division) else { continue }
            let candidate = division.intersection(bounds)
            guard !candidate.isNull, candidate.width > 0, candidate.height > 0 else { continue }
            let previousArea = fold.map { $0.width * $0.height } ?? 0
            if candidate.width * candidate.height > previousArea { fold = candidate }
        }

        if let fold, fold.height > fold.width,
           fold.minX > content.minX, fold.maxX < content.maxX {
            mode = .spread
            hero = CGRect(x: content.minX, y: content.minY,
                          width: fold.minX - content.minX, height: content.height)
            controls = CGRect(x: fold.maxX, y: content.minY,
                              width: content.maxX - fold.maxX, height: content.height)
        } else if let fold, fold.minY > content.minY, fold.maxY < content.maxY {
            mode = .tabletop
            hero = CGRect(x: content.minX, y: content.minY,
                          width: content.width, height: fold.minY - content.minY)
            controls = CGRect(x: content.minX, y: fold.maxY,
                              width: content.width, height: content.maxY - fold.maxY)
        } else if size.width >= 580 && size.width > size.height * 1.12 {
            mode = .spread
            let gap: CGFloat = 48
            let width = (content.width - gap) / 2
            hero = CGRect(x: content.minX, y: content.minY, width: width, height: content.height)
            controls = CGRect(x: hero.maxX + gap, y: content.minY, width: width, height: content.height)
        } else {
            mode = .stacked
            // At accessibility sizes each region can scroll independently; the
            // actions never disappear behind an oversized introduction.
            let controlsHeight = min(max(actionHeight, 190), content.height * 0.5)
            let gap = min(28, max(0, content.height - controlsHeight))
            hero = CGRect(x: content.minX, y: content.minY, width: content.width,
                          height: max(0, content.height - controlsHeight - gap))
            controls = CGRect(x: content.minX, y: hero.maxY + gap,
                              width: content.width, height: controlsHeight)
        }

        if mode == .spread && rightToLeft { swap(&hero, &controls) }
        // Keep the artwork split centered in the fold or column gap. Camera
        // avoidance can resize a pane, but must not move the background edge.
        spreadDivider = mode == .spread
            ? (min(hero.maxX, controls.maxX) + max(hero.minX, controls.minX)) / 2
            : nil
        hero = Self.avoidingOcclusions(hero, occlusions)
        controls = Self.avoidingOcclusions(controls, occlusions)

        let topPadding: CGFloat = mode == .stacked ? min(28, hero.height * 0.04) : 0
        let desiredHeight = min(225, hero.height * 0.43)
        let availableHeight = max(72, hero.height - introductionHeight - topPadding - 12)
        let logoWidth = min(300, hero.width * 0.78, min(desiredHeight, availableHeight) / 0.75)

        arrangement = mode
        introduction = hero
        actions = controls
        logoSize = CGSize(width: logoWidth, height: logoWidth * 0.75)
        introductionTopPadding = topPadding
    }

    /// Keep every important element inside a usable rectangle, including when
    /// the inner camera becomes active without changing the scene's size.
    private static func avoidingOcclusions(_ original: CGRect, _ obstacles: [CGRect]) -> CGRect {
        obstacles.reduce(original) { region, obstacle in
            guard OathLayoutGeometry.isUsable(obstacle) else { return region }
            let overlap = region.intersection(obstacle)
            guard !overlap.isNull, !overlap.isEmpty else { return region }
            let choices = [
                CGRect(x: region.minX, y: region.minY, width: region.width, height: max(0, overlap.minY - region.minY)),
                CGRect(x: region.minX, y: overlap.maxY, width: region.width, height: max(0, region.maxY - overlap.maxY)),
                CGRect(x: region.minX, y: region.minY, width: max(0, overlap.minX - region.minX), height: region.height),
                CGRect(x: overlap.maxX, y: region.minY, width: max(0, region.maxX - overlap.maxX), height: region.height)
            ]
            return choices.max { $0.width * $0.height < $1.width * $1.height } ?? region
        }
    }
}

/// Measured SwiftUI geometry, shared with the persistent Metal surface.
struct OathArtworkPlacement: Equatable {
    var logo: CGRect = .zero
    var logoClip: CGRect = .zero
    var copy: CGRect = .zero
    var actions: CGRect = .zero
    var spreadDivider: CGFloat?

    var spread: Bool { spreadDivider != nil }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
        Self(logo: logo.offsetBy(dx: dx, dy: dy),
             logoClip: logoClip.offsetBy(dx: dx, dy: dy),
             copy: copy.offsetBy(dx: dx, dy: dy),
             actions: actions.offsetBy(dx: dx, dy: dy),
             spreadDivider: spreadDivider.map { $0 + dx })
    }
}
