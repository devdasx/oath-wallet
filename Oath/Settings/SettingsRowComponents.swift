import SwiftUI

enum SettingsRowIcon: CaseIterable, Sendable {
    case wallets
    case walletBackup
    case walletRemoval
    case haptics
    case security
    case appearance
    case language
    case currency
    case notifications
    case tools
    case currencyConverter
    case networkFees
    case transactionExport
    case bitcoinTransactionBroadcaster
    case mnemonicLastWordFinder
    case evmAccessManager
    case about
    case appStoreRating
    case reset

    var systemImage: String {
        switch self {
        case .wallets:
            WalletIconTileStyle.walletSystemImage
        case .walletBackup:
            "externaldrive.fill"
        case .haptics:
            "waveform.path"
        case .security:
            "lock.shield.fill"
        case .appearance:
            "circle.lefthalf.filled"
        case .language:
            "globe"
        case .currency:
            "dollarsign"
        case .notifications:
            "bell.badge.fill"
        case .tools:
            "wrench.and.screwdriver.fill"
        case .currencyConverter:
            "arrow.left.arrow.right"
        case .networkFees:
            "gauge.with.dots.needle.50percent"
        case .transactionExport:
            "doc.text.fill"
        case .bitcoinTransactionBroadcaster:
            "antenna.radiowaves.left.and.right"
        case .mnemonicLastWordFinder:
            "text.book.closed.fill"
        case .evmAccessManager:
            "checkmark.shield.fill"
        case .about:
            "info"
        case .appStoreRating:
            "star.fill"
        case .walletRemoval, .reset:
            "trash.fill"
        }
    }

    var color: Color {
        switch self {
        case .wallets, .about:
            WalletTheme.settingsIconGray
        case .haptics:
            WalletTheme.settingsIconPink
        case .security, .currency, .evmAccessManager:
            WalletTheme.settingsIconGreen
        case .appearance:
            WalletTheme.settingsIconIndigo
        case .language, .walletBackup, .networkFees, .transactionExport:
            WalletTheme.settingsIconBlue
        case .notifications, .walletRemoval, .reset:
            WalletTheme.settingsIconRed
        case .tools:
            WalletTheme.settingsIconBlue
        case .currencyConverter:
            WalletTheme.settingsIconGreen
        case .bitcoinTransactionBroadcaster:
            WalletTheme.settingsIconOrange
        case .appStoreRating:
            WalletTheme.settingsIconOrange
        case .mnemonicLastWordFinder:
            WalletTheme.settingsIconIndigo
        }
    }
}

struct SettingsNavigationLabel: View {
    let title: LocalizedStringKey
    let value: Text?
    let icon: SettingsRowIcon

    init(
        title: LocalizedStringKey,
        icon: SettingsRowIcon
    ) {
        self.title = title
        value = nil
        self.icon = icon
    }

    init(
        title: LocalizedStringKey,
        value: LocalizedStringKey,
        icon: SettingsRowIcon
    ) {
        self.title = title
        self.value = Text(value)
        self.icon = icon
    }

    init(
        title: LocalizedStringKey,
        valueText: String,
        icon: SettingsRowIcon
    ) {
        self.title = title
        value = Text(verbatim: valueText)
        self.icon = icon
    }

    @ViewBuilder
    var body: some View {
        if let value {
            LabeledContent {
                value
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .lineLimit(1)
            } label: {
                SettingsRowTitle(title: title, icon: icon)
            }
        } else {
            SettingsRowTitle(title: title, icon: icon)
        }
    }
}

struct SettingsRowTitle: View {
    let title: LocalizedStringKey
    let icon: SettingsRowIcon

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(WalletTheme.primaryLabel)
        } icon: {
            SettingsIconTile(icon: icon)
        }
    }
}
