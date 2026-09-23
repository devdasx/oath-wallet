import AppIntents
import Foundation

protocol ApertureOpenAppIntent: AppIntent {
    static var destination: WalletAppDeepLinkDestination { get }
}

extension ApertureOpenAppIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy {
        .alwaysAllowed
    }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        [.foreground(.immediate)]
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(
            opensIntent: OpenURLIntent(Self.destination.universalURL)
        )
    }
}

struct ApertureSearchWalletIntent: ApertureOpenAppIntent {
    static let title = LocalizedStringResource(
        "wallet.search.start.title",
        defaultValue: "Search Your Wallet"
    )
    static let description = IntentDescription(
        LocalizedStringResource(
            "wallet.search.start.message",
            defaultValue: "Search across assets, prices, networks, transaction history, wallets, actions, and app settings."
        )
    )
    static let destination = WalletAppDeepLinkDestination.universalSearch

    init() {}
}

struct ApertureReceiveCryptoIntent: ApertureOpenAppIntent {
    static let title = LocalizedStringResource(
        "receive.title",
        defaultValue: "Receive"
    )
    static let description = IntentDescription(
        LocalizedStringResource(
            "wallet.search.action.receive.subtitle",
            defaultValue: "Display an asset address and QR code for incoming transfers."
        )
    )
    static let destination = WalletAppDeepLinkDestination.receive

    init() {}
}

struct ApertureCurrencyConverterIntent: ApertureOpenAppIntent {
    static let title = LocalizedStringResource(
        "settings.converter.title",
        defaultValue: "Currency Converter"
    )
    static let destination = WalletAppDeepLinkDestination.currencyConverter

    init() {}
}

struct ApertureSecuritySettingsIntent: ApertureOpenAppIntent {
    static let title = LocalizedStringResource(
        "settings.security.title",
        defaultValue: "Security"
    )
    static let description = IntentDescription(
        LocalizedStringResource(
            "settings.security.subtitle",
            defaultValue: "Passcode, Face ID, and Automatic Locking"
        )
    )
    static let destination = WalletAppDeepLinkDestination.securitySettings

    init() {}
}

struct ApertureWalletManagementIntent: ApertureOpenAppIntent {
    static let title = LocalizedStringResource(
        "settings.wallets.title",
        defaultValue: "Wallets Management"
    )
    static let description = IntentDescription(
        LocalizedStringResource(
            "settings.wallets.subtitle",
            defaultValue: "Manage Your Wallets and Accounts"
        )
    )
    static let destination = WalletAppDeepLinkDestination.walletManagement

    init() {}
}

struct AperturePhysicalEntropyWalletIntent: ApertureOpenAppIntent {
    static let title = LocalizedStringResource(
        "onboarding.creation.method.physical.title",
        defaultValue: "Build Your Entropy"
    )
    static let description = IntentDescription(
        LocalizedStringResource(
            "onboarding.creation.method.physical.subtitle",
            defaultValue: "Create a 24-word recovery phrase from physical dice rolls, coin flips, or random digits."
        )
    )
    static let destination = WalletAppDeepLinkDestination.physicalEntropy

    init() {}
}

struct ApertureAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ApertureSearchWalletIntent(),
            phrases: [
                "Search in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource(
                "wallet.search.start.title",
                defaultValue: "Search Your Wallet"
            ),
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: ApertureReceiveCryptoIntent(),
            phrases: [
                "Receive crypto in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource(
                "receive.title",
                defaultValue: "Receive"
            ),
            systemImageName: "qrcode"
        )
        AppShortcut(
            intent: ApertureCurrencyConverterIntent(),
            phrases: [
                "Convert currencies in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource(
                "settings.converter.title",
                defaultValue: "Currency Converter"
            ),
            systemImageName: "arrow.left.arrow.right"
        )
        AppShortcut(
            intent: ApertureSecuritySettingsIntent(),
            phrases: [
                "Open security settings in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource(
                "settings.security.title",
                defaultValue: "Security"
            ),
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: ApertureWalletManagementIntent(),
            phrases: [
                "Manage wallets in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource(
                "settings.wallets.title",
                defaultValue: "Wallets Management"
            ),
            systemImageName: "wallet.bifold"
        )
        AppShortcut(
            intent: AperturePhysicalEntropyWalletIntent(),
            phrases: [
                "Build a wallet with dice in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource(
                "onboarding.creation.method.physical.title",
                defaultValue: "Build Your Entropy"
            ),
            systemImageName: "die.face.6"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .grayBlue
    }
}
