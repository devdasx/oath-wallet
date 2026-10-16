import SwiftUI

/// The shared presentation for bundled network and asset artwork. The image
/// keeps its original colors; one native circle clips square source files.
struct OathNetworkLogo: View {
    let asset: String
    let size: CGFloat

    var body: some View {
        Image(asset)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            // A stable contrast surface also keeps transparent black marks
            // legible on dark-mode rows and in overlapping logo stacks.
            .background(.white, in: Circle())
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
