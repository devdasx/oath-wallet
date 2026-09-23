import SwiftUI

enum AppBrandArtwork {
    static let markAssetName = "BrandLogo"
    static let onboardingMarkAssetName = "OnboardingSplashLogo"
    static let walletIdentityMarkAssetName = "WalletIdentityMark"
    static let walletIdentityMarkInsetRatio: CGFloat = 0.12
}

/// Keeps protected app content private while iOS presents system-owned
/// authentication UI, without leaving the application window visually empty.
struct AppBiometricPrivacyCover: View {
    var body: some View {
        ZStack {
            WalletBackground()

            OnboardingBrandMark(
                size: OnboardingBrandMark.standardSize
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct OnboardingBrandMark: View {
    static let standardSize: CGFloat = 80

    let size: CGFloat
    var body: some View {
        Image(AppBrandArtwork.onboardingMarkAssetName)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct HeroBrandMark: View {
    let size: CGFloat
    var color: Color? = nil

    var body: some View {
        // Color treatments use the supplied solid mark, never a recolored
        // version of the multicolor artwork. Default marks adapt via the catalog.
        Image(color == nil
              ? AppBrandArtwork.markAssetName
              : AppBrandArtwork.walletIdentityMarkAssetName)
            .renderingMode(color == nil ? .original : .template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(color ?? Color("BrandMark"))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
