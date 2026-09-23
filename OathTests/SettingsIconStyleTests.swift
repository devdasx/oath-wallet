import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Verifies the actual system symbols, trait-resolved colors, and SwiftUI layout.
/// No app screenshots or bitmap snapshots are created.
@MainActor
struct SettingsIconStyleTests {
    @Test(arguments: SettingsRowIcon.allCases)
    func systemSymbolExistsAndFitsInsideItsTile(icon: SettingsRowIcon) throws {
        let symbol = try #require(UIImage(
            systemName: icon.systemImage,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: SettingsIconMetrics.symbolPointSize,
                weight: .semibold,
                scale: .medium
            )
        ))
        #expect(symbol.size.width > 0)
        #expect(symbol.size.height > 0)
        // Keep the glyph clear of the continuous corners, including wide symbols.
        #expect(symbol.size.width <= SettingsIconMetrics.size - 4)
        #expect(symbol.size.height <= SettingsIconMetrics.size - 4)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [UIAccessibilityContrast.normal, .high])
    func paletteUsesAdaptiveAppleColors(
        appearance: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast
    ) {
        let traits = UITraitCollection {
            $0.userInterfaceStyle = appearance
            $0.accessibilityContrast = contrast
        }
        let palette: [(SettingsRowIcon, UIColor)] = [
            (.wallets, .systemGray), (.walletBackup, .systemBlue),
            (.walletRemoval, .systemRed), (.haptics, .systemPink),
            (.security, .systemGreen), (.appearance, .systemIndigo),
            (.language, .systemBlue), (.currency, .systemGreen),
            (.notifications, .systemRed), (.about, .systemGray),
            (.reset, .systemRed), (.tools, .systemBlue),
            (.currencyConverter, .systemGreen), (.networkFees, .systemBlue),
            (.bitcoinTransactionBroadcaster, .systemOrange),
            (.mnemonicLastWordFinder, .systemIndigo),
            (.evmAccessManager, .systemGreen),
            (.appStoreRating, .systemOrange)
        ]
        #expect(palette.count == SettingsRowIcon.allCases.count)
        for (icon, expected) in palette {
            let actual = components(UIColor(icon.color), traits: traits)
            let native = components(expected, traits: traits)
            for (lhs, rhs) in zip(actual, native) {
                #expect(abs(lhs - rhs) < 0.000_001)
            }
        }
        #expect(components(UIColor(WalletTheme.settingsIconForeground), traits: traits)
            == components(.white, traits: traits))
    }

    @Test(arguments: SettingsRowIcon.allCases)
    func tileScalesWithDynamicTypeAndKeepsItsSquareFootprint(icon: SettingsRowIcon) {
        let textSizes: [DynamicTypeSize] = [
            .small, .large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5
        ]
        var previousWidth: CGFloat = 0
        for textSize in textSizes {
            let host = UIHostingController(rootView: SettingsIconTile(icon: icon)
                .environment(\.dynamicTypeSize, textSize))
            let size = host.sizeThatFits(in: CGSize(width: 320, height: 320))
            #expect(abs(size.width - size.height) < 0.01)
            #expect(size.width > previousWidth)
            if textSize == .large {
                #expect(abs(size.width - SettingsIconMetrics.size) < 0.01)
            }
            previousWidth = size.width
        }
    }

    @Test
    func cornersRemainRoundedSquaresRatherThanCircles() {
        #expect(SettingsIconMetrics.size == 29)
        #expect(SettingsIconMetrics.symbolPointSize == 15)
        #expect(SettingsIconMetrics.symbolWeight == .semibold)
        #expect(SettingsIconMetrics.cornerRadius == 7)
        #expect(SettingsIconMetrics.cornerRadius * 2 < SettingsIconMetrics.size)
    }

    @Test
    func sharedTileUsesTheNativeSwiftUIColorGradient() {
        #expect(
            WalletIconTileStyle.backgroundStyle(for: .blue)
                == Color.blue.gradient
        )
    }

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
