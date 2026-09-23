import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Measures SwiftUI layout and UIKit symbol/color traits without screenshots.
@MainActor
struct WalletIdentityIconStyleTests {
    @Test
    func rebrandedAppPreservesBundleIDAndLoadsEveryOathMark() throws {
        #expect(Bundle.main.bundleIdentifier == "com.aperture.wallet")
        #expect(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
                as? String == "Oath Wallet"
        )
        for localization in Bundle.main.localizations where localization != "Base" {
            let path = try #require(Bundle.main.path(forResource: localization, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            #expect(bundle.localizedString(forKey: "brand.name", value: nil, table: "Localizable") == "Oath Wallet")
            #expect(bundle.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist") == "Oath Wallet")
        }
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: appearance)
            for name in ["BrandLogo", "OnboardingSplashLogo", "WalletIdentityMark"] {
                let image = try #require(UIImage(named: name, in: .main, compatibleWith: traits))
                #expect(image.size.width > 0 && image.size.height > 0)
            }
        }
    }

    @Test
    func walletIdentityUsesTheBundledAppMarkInsteadOfAnSFSymbol() throws {
        #expect(
            WalletIdentityIcon.artwork
                == .asset(AppBrandArtwork.walletIdentityMarkAssetName)
        )
        #expect(
            AppBrandArtwork.walletIdentityMarkAssetName
                == "WalletIdentityMark"
        )
        let mark = try #require(
            UIImage(named: AppBrandArtwork.walletIdentityMarkAssetName)
        )
        #expect(mark.size.width > 0)
        #expect(mark.size.height > 0)
        #expect(
            UIImage(
                systemName: AppBrandArtwork.walletIdentityMarkAssetName
            ) == nil
        )
        #expect(WalletIdentityIconMetrics.listTileSize > SettingsIconMetrics.size)

        for size in [WalletIdentityIconMetrics.listTileSize, WalletIdentityIconMetrics.toolbarTileSize] {
            let radius = WalletIconTileStyle.cornerRadius(for: size)
            #expect(radius * 2 < size)
            #expect(abs(radius / size - SettingsIconMetrics.cornerRadius / SettingsIconMetrics.size) < 0.001)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func badgesKeepAStableUnclippedFootprintAcrossDynamicType(
        isSelected: Bool, showsBackupWarning: Bool
    ) {
        var previousSize: CGFloat = 0
        for textSize in Self.textSizes {
            let host = UIHostingController(rootView: WalletIdentityIcon(
                color: .cyan, isSelected: isSelected, showsBackupWarning: showsBackupWarning
            ).environment(\.dynamicTypeSize, textSize))
            let plainHost = UIHostingController(rootView: WalletIdentityIcon(color: .cyan)
                .environment(\.dynamicTypeSize, textSize))
            let proposal = CGSize(width: 500, height: 500)
            let size = host.sizeThatFits(in: proposal)
            #expect(size == plainHost.sizeThatFits(in: proposal))
            #expect(abs(size.width - size.height) < 0.01)
            #expect(size.width > previousSize)
            if textSize == .large {
                #expect(abs(size.width - Self.listFootprint) < 0.01)
            }
            let scale = size.width / Self.listFootprint
            let badgeSize = WalletIdentityIconMetrics.badgeSize * scale
            // Top and bottom trailing badges stay entirely within the reserved
            // square and cannot overlap one another, even at accessibility sizes.
            #expect(badgeSize * 2 < size.height)
            #expect(WalletIdentityIconMetrics.badgeClearance * scale > 0)
            previousSize = size.width
        }
    }

    @Test
    func toolbarTileKeepsTheExistingNativeToolbarWidthBudget() {
        for textSize in Self.textSizes {
            let host = UIHostingController(rootView: WalletIdentityIcon(
                color: .purple, placement: .toolbar
            ).environment(\.dynamicTypeSize, textSize))
            let size = host.sizeThatFits(in: CGSize(width: 500, height: 500))
            #expect(size.width == WalletIdentityIconMetrics.toolbarTileSize)
            #expect(size.height == WalletIdentityIconMetrics.toolbarTileSize)
            #expect(size.width + 6 <= WalletHomeTopToolbarLayout.walletIdentityWidth)
        }
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [UIAccessibilityContrast.normal, .high])
    func allSavedWalletColorsUseTheNativeAdaptivePalette(
        appearance: UIUserInterfaceStyle, contrast: UIAccessibilityContrast
    ) {
        let traits = UITraitCollection {
            $0.userInterfaceStyle = appearance
            $0.accessibilityContrast = contrast
        }
        let palette: [(WalletAppearanceColor, UIColor)] = [
            (.blue, .systemBlue), (.indigo, .systemIndigo), (.purple, .systemPurple),
            (.pink, .systemPink), (.red, .systemRed), (.orange, .systemOrange),
            (.green, .systemGreen), (.mint, .systemMint), (.teal, .systemTeal),
            (.cyan, .systemCyan)
        ]
        #expect(palette.count == WalletAppearanceColor.allCases.count)
        for (walletColor, systemColor) in palette {
            let actual = components(UIColor(walletColor.color), traits: traits)
            let expected = components(systemColor, traits: traits)
            for (lhs, rhs) in zip(actual, expected) {
                #expect(abs(lhs - rhs) < 0.000_001)
            }
        }
    }

    private static let textSizes: [DynamicTypeSize] = [
        .small, .large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5
    ]

    private static let listFootprint = WalletIdentityIconMetrics.listTileSize
        + WalletIdentityIconMetrics.badgeClearance * 2

    private func components(_ color: UIColor, traits: UITraitCollection) -> [CGFloat] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(color.resolvedColor(with: traits).getRed(
            &red, green: &green, blue: &blue, alpha: &alpha
        ))
        return [red, green, blue, alpha]
    }
}
