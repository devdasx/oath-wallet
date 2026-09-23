import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Palette checks use UIKit's real trait resolution, without capturing images.
/// Source guards verify that each audited row uses these explicit colors;
/// NativeListInteractionTests separately exercise the native pressed behavior.
@MainActor
struct NativeListSemanticColorTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [UIAccessibilityContrast.normal, .high])
    func labelsResolveToSystemColors(appearance: UIUserInterfaceStyle, contrast: UIAccessibilityContrast) {
        let traits = UITraitCollection {
            $0.userInterfaceStyle = appearance
            $0.accessibilityContrast = contrast
        }
        let palette: [(Color, UIColor)] = [
            (WalletTheme.primaryLabel, .label),
            (WalletTheme.secondaryLabel, .secondaryLabel),
            (WalletTheme.tertiaryLabel, .tertiaryLabel),
            (WalletTheme.danger, .systemRed),
            (WalletTheme.success, .systemGreen),
            (WalletTheme.primaryAction, .systemBlue)
        ]
        for (actual, expected) in palette {
            let resolved = components(UIColor(actual), traits: traits)
            let native = components(expected, traits: traits)
            for (lhs, rhs) in zip(resolved, native) {
                #expect(abs(lhs - rhs) < 0.000_001)
            }
        }
    }

    @Test
    func neutralLabelsAdaptToLightAndDarkRatherThanUsingFixedBlack() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for color in [WalletTheme.primaryLabel, WalletTheme.secondaryLabel, WalletTheme.tertiaryLabel] {
            #expect(components(UIColor(color), traits: light) != components(UIColor(color), traits: dark))
        }
    }

    @Test
    func keypadSurfaceAdaptsToLightAndDark() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        #expect(
            components(UIColor(WalletTheme.keypadSurface), traits: light)
                != components(UIColor(WalletTheme.keypadSurface), traits: dark)
        )
        #expect(
            components(UIColor(WalletTheme.keypadSurface), traits: light)
                != components(UIColor(WalletTheme.groupedBackground), traits: light)
        )
        #expect(
            components(UIColor(WalletTheme.keypadSurface), traits: dark)
                != components(UIColor(WalletTheme.groupedBackground), traits: dark)
        )
    }

    private func components(_ color: UIColor, traits: UITraitCollection) -> [CGFloat] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [red, green, blue, alpha]
    }
}
