import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Real SwiftUI sizing and UIKit trait resolution; no bitmap captures.
@MainActor
struct SendRecentRecipientAppearanceTests {
    @Test
    func allVisibleRecipientsHaveDifferentColorsIndependentOfRowOrder() throws {
        let recipients = try (1...20).map { number in
            let suffix = String(number, radix: 16)
            return try recipient(
                address: "0x" + String(repeating: "0", count: 40 - suffix.count) + suffix,
                count: number
            )
        }
        let colors = SendRecentRecipientAppearance.colors(for: recipients)
        #expect(colors.count == 20)
        #expect(Set(colors.values).count == recipients.count)
        #expect(colors == SendRecentRecipientAppearance.colors(for: recipients.reversed()))
        let updated = recipients.map {
            SendRecentRecipient(id: $0.id, address: $0.address, sendCount: $0.sendCount + 1, lastSentAt: .now)
        }
        #expect(colors == SendRecentRecipientAppearance.colors(for: updated))
    }

    @Test
    func canonicalAliasesShareOneColorAndPrefixesDoNotChooseTheColor() throws {
        let address = SendRecipientHistoryTestFixtures.recipient
        let original = try recipient(address: address)
        let alias = try recipient(address: address.lowercased())
        let colors = SendRecentRecipientAppearance.colors(for: [original, alias])
        #expect(colors.count == 1)
        #expect(colors[original.id] == colors[alias.id])
        #expect(SendRecentRecipientAppearance.monogram(for: address) == "8B")
        #expect(SendRecentRecipientAppearance.monogram(for: "0X8ba1") == "8B")
        #expect(SendRecentRecipientAppearance.monogram(for: "alice.near") == "AL")
        #expect(SendRecentRecipientAppearance.monogram(for: "TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL") == "TN")
    }

    @Test(arguments: AssetNetworkSelectorOption.allSupported)
    func everySupportedMainnetRecipientHasAColorAndTwoCharacterMonogram(
        network: AssetNetworkSelectorOption
    ) throws {
        let address = SendEntryTestFixtures.address(for: network.blockchain)
        let recent = try recipient(address: address, networkID: network.id)
        #expect(SendRecentRecipientAppearance.colors(for: [recent])[recent.id] != nil)
        #expect(SendRecentRecipientAppearance.monogram(for: address).count == 2)
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [UIAccessibilityContrast.normal, .high])
    func allPaletteFillsAreDistinctOpaqueAndUseWhiteInitials(
        appearance: UIUserInterfaceStyle, contrast: UIAccessibilityContrast
    ) throws {
        let traits = UITraitCollection {
            $0.userInterfaceStyle = appearance
            $0.accessibilityContrast = contrast
        }
        var backgrounds: [[CGFloat]] = []
        for color in WalletTheme.RecipientIconColor.allCases {
            let background = try components(color.background, traits: traits)
            let foreground = try components(color.foreground, traits: traits)
            #expect(background[3] == 1)
            #expect(foreground[3] == 1)
            #expect(!backgrounds.contains(background))
            backgrounds.append(background)
            #expect(foreground[0] == 1)
            #expect(foreground[1] == 1)
            #expect(foreground[2] == 1)
        }
        #expect(backgrounds.count >= 20)
    }

    @Test(arguments: [DynamicTypeSize.small, .large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5])
    func monogramMatchesSettingsTileFootprintAtEveryTextSize(textSize: DynamicTypeSize) {
        let monogram = UIHostingController(rootView: SendRecipientMonogram(text: "MW", color: .blue)
            .environment(\.dynamicTypeSize, textSize))
        let settings = UIHostingController(rootView: SettingsIconTile(icon: .wallets)
            .environment(\.dynamicTypeSize, textSize))
        let bounds = CGSize(width: 320, height: 320)
        let actual = monogram.sizeThatFits(in: bounds)
        let expected = settings.sizeThatFits(in: bounds)
        #expect(abs(actual.width - expected.width) < 0.01)
        #expect(abs(actual.height - expected.height) < 0.01)
        #expect(abs(actual.width - actual.height) < 0.01)
        #expect(WalletIconTileStyle.cornerRadius(for: actual.width) * 2 < actual.width)
        if textSize == .large { #expect(actual.width == 29) }
    }

    private func recipient(address: String, networkID: String = "eth", count: Int = 1) throws -> SendRecentRecipient {
        SendRecentRecipient(
            id: try #require(SendRecipientIdentity(address: address, networkID: networkID)),
            address: address, sendCount: count, lastSentAt: Date(timeIntervalSince1970: Double(count))
        )
    }

    private func components(_ color: Color, traits: UITraitCollection) throws -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        try #require(UIColor(color).resolvedColor(with: traits)
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [red, green, blue, alpha]
    }
}
