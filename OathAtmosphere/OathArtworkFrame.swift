import Foundation

struct OathArtworkViewport: Equatable {
    let size: CGSize
    let safeTop: CGFloat
}

extension OathArtworkPlacement {
    /// Home and Customize use the same full-height material behind their UI.
    /// Welcome adds its logo and copy placement to this same shader/renderer.
    static func walletBackdrop(size: CGSize) -> Self {
        Self(logo: CGRect(x: -100, y: -100, width: 1, height: 1), logoClip: .zero,
             copy: CGRect(origin: .zero, size: size),
             actions: CGRect(x: 0, y: size.height + 160, width: size.width, height: 1))
    }
}

struct AtmosphereUniforms: Sendable {
    var resolution: SIMD2<Float>
    var timeAndAppearance: SIMD2<Float>
    var interaction: SIMD2<Float> = .zero
    var logoLayout: SIMD2<Float> = .zero
    var logoRect: SIMD4<Float> = .zero
    var fadeLayout: SIMD4<Float> = .zero
    var copyRect: SIMD4<Float> = .zero
    var logoClip: SIMD4<Float> = .zero
    var panelLayout: SIMD4<Float> = .zero
}

/// The first-frame image and live renderer share measured point-space layout.
struct OathArtworkFrame {
    let size: CGSize
    let logo: CGRect
    let logoClip: CGRect
    let copy: CGRect
    let fadeStart: CGFloat
    let fadeEnd: CGFloat
    let divider: CGFloat?
    let actionsOnRight: Bool

    init(size: CGSize, safeTop: CGFloat, placement: OathArtworkPlacement?) {
        self.size = OathLayoutGeometry.finiteSize(size)
        let measured = placement.flatMap {
            OathLayoutGeometry.isUsable($0.logo) && OathLayoutGeometry.isUsable($0.copy)
                && OathLayoutGeometry.isUsable($0.actions) ? $0 : nil
        }
        logo = measured?.logo ?? OathArtworkLayout(size: self.size, safeTop: safeTop).logoFrame
        logoClip = measured?.logoClip ?? CGRect(origin: .zero, size: self.size)
        copy = measured?.copy ?? .zero
        divider = placement?.spreadDivider.flatMap { $0.isFinite ? $0 : nil }
        actionsOnRight = (placement?.logoClip.midX ?? 0) < (divider ?? 0)
        if let measured, divider == nil, self.size.height > 0 {
            let start = min(measured.copy.maxY + 12, self.size.height - 40) / self.size.height
            fadeStart = start
            fadeEnd = max(start + 0.012, max(0, measured.actions.minY - 16) / self.size.height)
        } else {
            fadeStart = 0.46
            fadeEnd = 0.72
        }
    }

    func uniforms(pixelSize: CGSize, time: Float, appearance: Float,
                  interaction: SIMD2<Float>) -> AtmosphereUniforms {
        func normalized(_ rect: CGRect) -> SIMD4<Float> {
            SIMD4(Float(rect.minX / max(size.width, 1)), Float(rect.minY / max(size.height, 1)),
                  Float(rect.width / max(size.width, 1)), Float(rect.height / max(size.height, 1)))
        }
        return AtmosphereUniforms(
            resolution: SIMD2(Float(pixelSize.width), Float(pixelSize.height)),
            timeAndAppearance: SIMD2(time, appearance), interaction: interaction,
            logoRect: normalized(logo),
            fadeLayout: SIMD4(Float(fadeStart), Float(fadeEnd), Float(fadeStart), Float(fadeEnd)),
            copyRect: normalized(copy), logoClip: normalized(logoClip),
            panelLayout: divider.map { SIMD4(Float($0 / max(size.width, 1)), actionsOnRight ? 1 : -1, 0, 0) } ?? .zero
        )
    }
}
