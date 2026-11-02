import SwiftUI
import UIKit
import OathTokenImages

/// The shared presentation for bundled network and asset artwork.
/// Full-bleed network artwork gets one antialiased, continuous rounded-square
/// mask at its final display size. Other bundled artwork keeps its silhouette.
struct OathNetworkLogo: View {
    let asset: String
    let size: CGFloat

    private var resolvedAsset: String { Self.resolvedAsset(asset) }

    static func resolvedAsset(_ asset: String) -> String {
        guard asset.hasPrefix("network-") else { return asset }
        let network = String(asset.dropFirst("network-".count))
        return OathReceiveExampleCatalog.bundled.redesignedArtwork(networkID: network, reference: "native") ?? asset
    }

    private var artwork: Image {
        // Pre-sized catalog renditions avoid decoding/uploading a 4K texture
        // when a small row or badge enters the viewport. UIKit caches these
        // named images; larger artwork still uses the preserved source.
        if size <= 128, let displayImage = UIImage(named: resolvedAsset + "-display") {
            return Image(uiImage: displayImage)
        }
        // Optional display artwork may be absent for non-network assets.
        return Image(resolvedAsset)
    }

    var body: some View {
        artwork
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(
                RoundedRectangle(cornerRadius: resolvedAsset.hasPrefix("network-") ? size * TokenArtworkStyle.cornerRadiusFraction : 0,
                                 style: .continuous),
                style: FillStyle(antialiased: true)
            )
            .accessibilityHidden(true)
    }
}
