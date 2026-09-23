import SwiftUI

enum WalletHomeTopToolbarLayout {
    static let walletIdentityWidth: CGFloat = 32

    private static let reservedNonTitleWidth: CGFloat = 224
    private static let pendingActivityShortcutReservation: CGFloat = 52
    private static let currencyConverterShortcutReservation: CGFloat = 52
    private static let wideContainerThreshold: CGFloat = 600
    private static let compactMaximumTitleWidth: CGFloat = 220
    private static let wideMaximumTitleWidth: CGFloat = 320

    static func switcherTitleMaximumWidth(
        containerWidth: CGFloat,
        showsPendingActivity: Bool = false,
        showsCurrencyConverterShortcut: Bool = false
    ) -> CGFloat {
        let finiteWidth = containerWidth.isFinite
            ? max(0, containerWidth)
            : 0
        let maximumWidth = finiteWidth >= wideContainerThreshold
            ? wideMaximumTitleWidth
            : compactMaximumTitleWidth
        return min(
            maximumWidth,
            max(
                0,
                finiteWidth
                    - reservedNonTitleWidth
                    - (showsPendingActivity ? pendingActivityShortcutReservation : 0)
                    - (showsCurrencyConverterShortcut
                        ? currencyConverterShortcutReservation
                        : 0)
            )
        )
    }
}

enum WalletHomeWalletSwitcherToolbarID {
    static let name = "wallet-home-wallet-switcher-name"
    static let balance = "wallet-home-wallet-switcher-balance"
}

struct WalletHomeWalletSwitcherToolbarButton<Title: View>: View {
    let color: WalletAppearanceColor
    let maximumTitleWidth: CGFloat
    let walletName: String
    let accessibilityValue: String
    let action: () -> Void
    let title: Title

    init(
        color: WalletAppearanceColor,
        maximumTitleWidth: CGFloat,
        walletName: String,
        accessibilityValue: String,
        action: @escaping () -> Void,
        @ViewBuilder title: () -> Title
    ) {
        self.color = color
        self.maximumTitleWidth = maximumTitleWidth
        self.walletName = walletName
        self.accessibilityValue = accessibilityValue
        self.action = action
        self.title = title()
    }

    var body: some View {
        Button(action: UniHaptic.action(nil) {
            action()
        }) {
            WalletHomeWalletSwitcherToolbarLabel(
                color: color,
                maximumTitleWidth: maximumTitleWidth
            ) {
                title
            }
        }
        .accessibilityLabel(Text(verbatim: walletName))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityHint(Text("settings.wallets.subtitle"))
    }
}

struct WalletHomeWalletSwitcherToolbarLabel<Title: View>: View {
    let color: WalletAppearanceColor
    let maximumTitleWidth: CGFloat
    let title: Title

    init(
        color: WalletAppearanceColor,
        maximumTitleWidth: CGFloat,
        @ViewBuilder title: () -> Title
    ) {
        self.color = color
        self.maximumTitleWidth = maximumTitleWidth
        self.title = title()
    }

    var body: some View {
        WalletHomePinnedIdentityToolbarLabel(
            maximumTitleWidth: maximumTitleWidth
        ) {
            WalletIdentityIcon(
                color: color,
                placement: .toolbar
            )
        } title: {
            title
        }
        .foregroundStyle(WalletTheme.primaryLabel)
    }
}

struct WalletHomePinnedIdentityToolbarLabel<
    Identity: View,
    Title: View
>: View {
    let maximumTitleWidth: CGFloat
    let identity: Identity
    let title: Title

    init(
        maximumTitleWidth: CGFloat,
        @ViewBuilder identity: () -> Identity,
        @ViewBuilder title: () -> Title
    ) {
        self.maximumTitleWidth = maximumTitleWidth
        self.identity = identity()
        self.title = title()
    }

    var body: some View {
        HStack(spacing: 6) {
            identity
                .fixedSize()
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }

            title
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: maximumTitleWidth,
                    alignment: .leading
                )
        }
    }
}

struct WalletHomeSwitcherBalanceTitle: View {
    let totalBalance: Decimal
    let currencyContext: WalletCurrencyContext
    let isBalanceHidden: Bool

    var body: some View {
        WalletCurrencyBalancePresentation(
            usdValue: totalBalance,
            currencyContext: currencyContext
        ).text(
            colorPlan: WalletCurrencyBalanceColorPlan(
                isHidden: isBalanceHidden
            )
        )
            .font(.headline)
            .lineLimit(1)
            .monospacedDigit()
            .redacted(reason: isBalanceHidden ? .placeholder : [])
            .walletPrivacySensitive(true)
            .accessibilityHidden(isBalanceHidden)
            .transaction { transaction in
                guard isBalanceHidden else { return }
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

/// Uses the system toolbar's plus sizing, glass presentation, and menu behavior.
struct WalletHomeAddWalletMenu: View {
    let onAddWallet: (HomeWalletAddAction) -> Void

    var body: some View {
        Menu {
            ForEach(HomeWalletAddAction.allCases) { action in
                Section {
                    Button(action: UniHaptic.action(nil) {
                        onAddWallet(action)
                    }) {
                        Text(action.titleKey)
                    }
                }
            }
        } label: {
            Label("settings.wallets.add", systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .menuOrder(.fixed)
    }
}
