import ImageIO
import SwiftUI
import UIKit

private final class AssetLogoThumbnailCache: @unchecked Sendable {
    static let shared = AssetLogoThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 512
        cache.totalCostLimit = 24 * 1_024 * 1_024
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(
        _ image: UIImage,
        for key: String,
        maximumPixelSize: Int
    ) {
        let estimatedCost =
            maximumPixelSize * maximumPixelSize * 4
        cache.setObject(
            image,
            forKey: key as NSString,
            cost: estimatedCost
        )
    }
}

struct WalletLogoStatusBadge: View {
    let color: Color
    let systemSymbol: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(WalletTheme.groupedSurface)

            Circle()
                .fill(color)
                .padding(size * 0.09)

            Image(systemName: systemSymbol)
                .font(
                    .system(
                        size: size * 0.41,
                        weight: WalletSFSymbol.weight
                    )
                )
                .foregroundStyle(WalletTheme.onAccentLabel)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct WalletAssetLogoWithNetworkBadge: View {
    let asset: WalletAsset
    let size: CGFloat

    init(asset: WalletAsset, size: CGFloat = 44) {
        self.asset = asset
        self.size = size
    }

    var body: some View {
        WalletAssetLogoBadges(
            logoSource: asset.logoSource,
            networkLogoSource: asset.networkLogoSource,
            familyLogoSource: asset.familyLogoSource,
            size: size,
            animatesChanges: true,
            diagnosticAssetIdentity: asset.id
        )
    }
}

/// An asset logo with its network badge at the bottom trailing corner and,
/// for a member of an asset family (bStocks…), the family badge at the bottom
/// leading corner, so both memberships read at a glance.
struct WalletAssetLogoBadges: View {
    let logoSource: AssetLogoSource
    let networkLogoSource: AssetLogoSource?
    let familyLogoSource: AssetLogoSource?
    let size: CGFloat
    let animatesChanges: Bool
    let diagnosticAssetIdentity: String?

    var body: some View {
        ZStack {
            AssetLogoView(
                source: logoSource,
                size: size,
                animatesChanges: animatesChanges,
                diagnosticAssetIdentity: diagnosticAssetIdentity
            )

            if let familyLogoSource {
                badge(familyLogoSource)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottomLeading
                    )
            }

            if let networkLogoSource {
                badge(networkLogoSource)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottomTrailing
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func badge(_ source: AssetLogoSource) -> some View {
        ZStack {
            Circle()
                .fill(WalletTheme.groupedSurface)
                .frame(
                    width: size * 0.50,
                    height: size * 0.50
                )

            AssetLogoView(
                source: source,
                size: size * 0.36,
                animatesChanges: animatesChanges
            )
            .clipShape(Circle())
        }
    }
}

struct AssetLogoView: View {
    private struct LoadRequest: Hashable {
        let source: AssetLogoSource
        let diagnosticAssetIdentity: String?
        let retryGeneration: UInt64
    }

    private enum LoadState {
        case idle
        case loading(AssetLogoSource)
        case loaded(AssetLogoSource, UIImage)
        case failed(AssetLogoSource)
    }

    private let providedSource: AssetLogoSource
    let size: CGFloat
    let animatesChanges: Bool
    let diagnosticAssetIdentity: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var loadState: LoadState = .idle
    @State private var retryGeneration: UInt64 = 0

    private var source: AssetLogoSource {
        // A holding may have been created before the catalog arrived.
        // Resolve by chain and contract, never by an untrusted ticker.
        providedSource.resolvingCatalogArtwork(assetIdentity: diagnosticAssetIdentity)
    }

    init(
        source: AssetLogoSource,
        size: CGFloat = 44,
        animatesChanges: Bool = true,
        diagnosticAssetIdentity: String? = nil
    ) {
        self.providedSource = source
        self.size = size
        self.animatesChanges = animatesChanges
        self.diagnosticAssetIdentity = diagnosticAssetIdentity
    }

    var body: some View {
        logoContent
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .walletAssetCatalogDidChange)) { _ in
            retryGeneration &+= 1
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { retryGeneration &+= 1 }
        }
    }

    @ViewBuilder
    private var logoContent: some View {
        if let bundledAssetName = source.bundledAssetName {
            Image(bundledAssetName)
                .resizable()
                .scaledToFit()
        } else if source.remoteLogoURL != nil {
            loadedContent
                .task(
                    id: LoadRequest(
                        source: source,
                        diagnosticAssetIdentity:
                            diagnosticAssetIdentity,
                        retryGeneration: retryGeneration
                    )
                ) {
                    await loadRemoteLogoIfNeeded()
                }
        } else {
            neutralLogoFallback
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        switch loadState {
        case let .loaded(loadedSource, image) where loadedSource == source:
            loadedImage(image)
        case let .failed(failedSource) where failedSource == source:
            neutralLogoFallback
        default:
            neutralLogoFallback
        }
    }

    private func loadedImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
    }

    @MainActor
    private func loadRemoteLogoIfNeeded() async {
        let source = self.source
        guard let logoURL = source.remoteLogoURL else {
            loadState = .idle
            return
        }
        if case let .loaded(loadedSource, _) = loadState,
           loadedSource == source {
            return
        }

        let displayScale = UITraitCollection.current.displayScale
        let maximumPixelSize = max(
            1,
            Int((size * displayScale).rounded(.up))
        )
        let thumbnailCacheKey =
            "\(logoURL.absoluteString)#\(maximumPixelSize)"
        if let cachedImage = AssetLogoThumbnailCache.shared.image(
            for: thumbnailCacheKey
        ) {
            loadState = .loaded(source, cachedImage)
            return
        }

        loadState = .loading(source)
        do {
            let data = try await AssetLogoCache.shared.imageData(
                for: logoURL
            )
            let decodedImage = await Task.detached(
                priority: .userInitiated
            ) {
                Self.decodedThumbnail(
                    from: data,
                    maximumPixelSize: maximumPixelSize,
                    displayScale: displayScale
                )
            }.value
            guard
                !Task.isCancelled
            else { return }
            guard let image = decodedImage else {
                loadState = .failed(source)
                return
            }
            AssetLogoThumbnailCache.shared.insert(
                image,
                for: thumbnailCacheKey,
                maximumPixelSize: maximumPixelSize
            )
            withAnimation(
                animatesChanges && !reduceMotion
                    ? .smooth(duration: 0.2)
                    : nil
            ) {
                loadState = .loaded(source, image)
            }
            return
        } catch {
            guard !Task.isCancelled else { return }
        }
        withAnimation(
            animatesChanges && !reduceMotion
                ? .smooth(duration: 0.2)
                : nil
        ) {
            loadState = .failed(source)
        }
    }

    nonisolated private static func decodedThumbnail(
        from data: Data,
        maximumPixelSize: Int,
        displayScale: CGFloat
    ) -> UIImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                nil
            )
        else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            )
        else {
            return nil
        }
        return UIImage(
            cgImage: image,
            scale: displayScale,
            orientation: .up
        )
    }

    private var neutralLogoFallback: some View {
        ZStack {
            Circle()
                .fill(WalletTheme.mutedSecondaryFill)

            Image(systemName: "hexagon")
                .fontWeight(WalletSFSymbol.weight)
                .font(.system(size: max(10, size * 0.34)))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
