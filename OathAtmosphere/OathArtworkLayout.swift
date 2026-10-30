import Foundation

/// Shared point-space placement for the Metal logo and its SwiftUI caption.
struct OathArtworkLayout {
    let logoFrame: CGRect

    init(size: CGSize, safeTop: CGFloat) {
        let width = min(size.width * 0.66, 300)
        let top = max(safeTop + 24, min(size.height * 0.10, 110))
        logoFrame = CGRect(
            x: (size.width - width) / 2,
            y: top,
            width: width,
            height: width * 0.75
        )
    }

    var capsuleTop: CGFloat { logoFrame.maxY + 12 }
}
