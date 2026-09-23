import SwiftUI

enum WalletSelectionBadgePolicy {
    static func shouldShow(
        isSelected: Bool,
        walletCount: Int
    ) -> Bool {
        isSelected && walletCount > 1
    }
}

struct WalletManagementAddActionLabel: View {
    let action: HomeWalletAddAction

    var body: some View {
        Label {
            Text(action.titleKey)
        } icon: {
            Image(systemName: action.systemImage)
                .symbolRenderingMode(.monochrome)
                .accessibilityHidden(true)
        }
        .foregroundStyle(WalletTheme.accent)
    }
}

struct WalletManagementAddActionsSection: View {
    let onCreate: () -> Void
    let onImport: () -> Void
    let onRestoreICloud: () -> Void

    var body: some View {
        Section {
            Button(action: UniHaptic.action(nil, perform: onCreate)) {
                WalletManagementAddActionLabel(action: .create)
            }

            Button(action: UniHaptic.action(nil, perform: onImport)) {
                WalletManagementAddActionLabel(action: .importWallet)
            }

            Button(action: UniHaptic.action(nil, perform: onRestoreICloud)) {
                WalletManagementAddActionLabel(action: .restoreICloud)
            }
        } header: {
            Text("settings.wallets.add.section")
        } footer: {
            Text("settings.wallets.footer")
        }
    }
}

/// Shared wallet-selection content for the switcher, management and backup lists.
/// Screens own their actions; only rows with a separate accessory reserve space.
struct WalletSettingsManagementRow: View {
    let wallet: ManagedWallet
    let walletCount: Int
    let isBalanceHidden: Bool
    var reservesAccessorySpace: Bool = true
    let onSelect: () -> Void

    var body: some View {
        Button(action: UniHaptic.action(onSelect)) {
            WalletSettingsManagementRowLabel(
                wallet: wallet,
                walletCount: walletCount,
                isBalanceHidden: isBalanceHidden,
                reservesAccessorySpace: reservesAccessorySpace
            )
        }
        .buttonStyle(.automatic)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            Text(
                wallet.isSelected
                    ? "selection.selected"
                    : "selection.not_selected"
            )
        )
    }
}

/// Shared visual content; each screen supplies its native row action.
struct WalletSettingsManagementRowLabel: View {
    let wallet: ManagedWallet
    let walletCount: Int
    let isBalanceHidden: Bool
    var reservesAccessorySpace: Bool = true

    @Environment(\.walletCurrencyContext) private var currencyContext

    var body: some View {
        let formattedBalance = EnglishNumbers.currency(
            wallet.fiatUSDBalance,
            using: currencyContext
        )

        HStack(alignment: .center, spacing: 12) {
            WalletIdentityIcon(
                color: wallet.appearanceColor,
                isSelected: WalletSelectionBadgePolicy.shouldShow(
                    isSelected: wallet.isSelected,
                    walletCount: walletCount
                ),
                showsBackupWarning: wallet.needsBackup
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(wallet.name)
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .lineLimit(1)

                WalletPrivacyReplacement(
                    isHidden: isBalanceHidden,
                    alignment: .leading
                ) {
                    Text(formattedBalance)
                }
                .font(.subheadline)
                .foregroundStyle(WalletTheme.secondaryLabel)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.trailing, reservesAccessorySpace ? 48 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct WalletRowActionsLabel: View {
    var body: some View {
        Image(systemName: "info.circle")
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(WalletTheme.secondaryLabel)
            .imageScale(.large)
    }
}

struct WalletRowInformationButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: UniHaptic.action(nil, perform: action)) {
            WalletRowActionsLabel()
                .frame(width: 44, height: 44)
        }
        // An accessory must not join List's full-row primary action.
        .buttonStyle(.borderless)
        .tint(WalletTheme.secondaryLabel)
        .accessibilityLabel(Text("settings.wallets.wallet_settings"))
    }
}

struct WalletManagementErrorRow: View {
    let messageKey: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(messageKey))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("settings.wallets.load.retry", action: UniHaptic.action(onRetry))
                .foregroundStyle(WalletTheme.accent)
        }
        .padding(.vertical, 4)
    }
}

struct WalletStatusValue: View {
    let isSelected: Bool

    @ViewBuilder
    var body: some View {
        if isSelected {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .accessibilityHidden(true)

                Text("settings.wallets.status.active")
            }
            .foregroundStyle(WalletTheme.success)
        } else {
            Text("settings.wallets.status.inactive")
                .foregroundStyle(WalletTheme.secondaryLabel)
        }
    }
}
