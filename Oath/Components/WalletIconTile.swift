import SwiftUI

/// Canonical Apple Settings-style treatment for the app's small colored symbol
/// tiles. Settings, import methods, data-removal rows, and wallet identity icons
/// all use this component so future tiles inherit identical metrics and the
/// native SwiftUI color gradient. Owning surfaces keep their native row and
/// toolbar behavior.
enum WalletIconTileStyle {
    static let size: CGFloat = 29
    static let symbolPointSize: CGFloat = 15
    static let symbolWeight: Font.Weight = .semibold
    static let cornerRadius: CGFloat = 7
    static let walletSystemImage = "wallet.bifold.fill"

    static func backgroundStyle(for color: Color) -> AnyGradient {
        color.gradient
    }

    static func symbolPointSize(for size: CGFloat) -> CGFloat {
        size * symbolPointSize / Self.size
    }

    static func cornerRadius(for size: CGFloat) -> CGFloat {
        size * cornerRadius / Self.size
    }
}

enum WalletIconTileArtwork: Equatable, Sendable {
    case asset(String)
    case systemImage(String)
}

struct WalletIconTile: View {
    let artwork: WalletIconTileArtwork
    let color: Color
    let size: CGFloat

    init(
        artwork: WalletIconTileArtwork,
        color: Color,
        size: CGFloat
    ) {
        self.artwork = artwork
        self.color = color
        self.size = size
    }

    init(
        systemImage: String,
        color: Color,
        size: CGFloat
    ) {
        self.init(
            artwork: .systemImage(systemImage),
            color: color,
            size: size
        )
    }

    var body: some View {
        artworkView
            .foregroundStyle(WalletTheme.settingsIconForeground)
            .frame(width: size, height: size)
            .background(
                WalletIconTileStyle.backgroundStyle(for: color),
                in: RoundedRectangle(
                    cornerRadius: WalletIconTileStyle.cornerRadius(for: size),
                    style: .continuous
                )
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artworkView: some View {
        switch artwork {
        case let .asset(assetName):
            Image(assetName)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(assetName == AppBrandArtwork.walletIdentityMarkAssetName
                         ? size * AppBrandArtwork.walletIdentityMarkInsetRatio : 0)

        case let .systemImage(systemImage):
            Image(systemName: systemImage)
                .font(.system(
                    size: WalletIconTileStyle.symbolPointSize(for: size),
                    weight: WalletIconTileStyle.symbolWeight
                ))
                .imageScale(.medium)
                .symbolRenderingMode(.monochrome)
        }
    }
}
