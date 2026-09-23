import SwiftUI

enum WalletAppearanceColor:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    case blue
    case indigo
    case purple
    case pink
    case red
    case orange
    case green
    case mint
    case teal
    case cyan

    var id: String { rawValue }

    var color: Color {
        Color(uiColor: uiColor)
    }

    var nameKey: LocalizedStringKey {
        switch self {
        case .blue:
            "settings.wallets.color.blue"
        case .indigo:
            "settings.wallets.color.indigo"
        case .purple:
            "settings.wallets.color.purple"
        case .pink:
            "settings.wallets.color.pink"
        case .red:
            "settings.wallets.color.red"
        case .orange:
            "settings.wallets.color.orange"
        case .green:
            "settings.wallets.color.green"
        case .mint:
            "settings.wallets.color.mint"
        case .teal:
            "settings.wallets.color.teal"
        case .cyan:
            "settings.wallets.color.cyan"
        }
    }

    func contrastingForeground(
        colorScheme: ColorScheme,
        colorSchemeContrast: ColorSchemeContrast
    ) -> Color {
        usesLightForeground(
            colorScheme: colorScheme,
            colorSchemeContrast: colorSchemeContrast
        )
            ? WalletTheme.onDarkColorLabel
            : WalletTheme.onLightColorLabel
    }

    func contrastingToolbarColorScheme(
        colorScheme: ColorScheme,
        colorSchemeContrast: ColorSchemeContrast
    ) -> ColorScheme {
        usesLightForeground(
            colorScheme: colorScheme,
            colorSchemeContrast: colorSchemeContrast
        ) ? .dark : .light
    }

    private var uiColor: UIColor {
        switch self {
        case .blue:
            .systemBlue
        case .indigo:
            .systemIndigo
        case .purple:
            .systemPurple
        case .pink:
            .systemPink
        case .red:
            .systemRed
        case .orange:
            .systemOrange
        case .green:
            .systemGreen
        case .mint:
            .systemMint
        case .teal:
            .systemTeal
        case .cyan:
            .systemCyan
        }
    }

    private func usesLightForeground(
        colorScheme: ColorScheme,
        colorSchemeContrast: ColorSchemeContrast
    ) -> Bool {
        let interfaceStyle: UIUserInterfaceStyle =
            colorScheme == .dark ? .dark : .light
        let accessibilityContrast: UIAccessibilityContrast =
            colorSchemeContrast == .increased ? .high : .normal
        let traits = UITraitCollection(
            UITraitUserInterfaceStyle.self,
            value: interfaceStyle
        ).replacing(
            UITraitAccessibilityContrast.self,
            value: accessibilityContrast
        )
        let resolvedColor = uiColor.resolvedColor(with: traits)
        let luminance = resolvedColor.relativeLuminance
        let lightForegroundContrast = 1.05 / (luminance + 0.05)
        let darkForegroundContrast = (luminance + 0.05) / 0.05
        return lightForegroundContrast >= darkForegroundContrast
    }

    static func nextAvailable(
        existingIDs: [String],
        randomIndex: (Int) -> Int = { count in
            Int.random(in: 0..<count)
        }
    ) -> WalletAppearanceColor {
        let counts = existingIDs.reduce(
            into: [WalletAppearanceColor: Int]()
        ) { result, rawValue in
            guard let color = WalletAppearanceColor(rawValue: rawValue)
            else { return }
            result[color, default: 0] += 1
        }
        let leastUseCount = allCases
            .map { counts[$0, default: 0] }
            .min() ?? 0
        let candidates = allCases.filter {
            counts[$0, default: 0] == leastUseCount
        }
        guard !candidates.isEmpty else { return .blue }
        let index = min(
            max(randomIndex(candidates.count), 0),
            candidates.count - 1
        )
        return candidates[index]
    }
}

private extension UIColor {
    var relativeLuminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        ) else {
            var white: CGFloat = 0
            guard getWhite(&white, alpha: &alpha) else { return 0 }
            return Self.linearizedSRGBComponent(white)
        }

        return 0.2126 * Self.linearizedSRGBComponent(red)
            + 0.7152 * Self.linearizedSRGBComponent(green)
            + 0.0722 * Self.linearizedSRGBComponent(blue)
    }

    static func linearizedSRGBComponent(_ component: CGFloat) -> CGFloat {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
