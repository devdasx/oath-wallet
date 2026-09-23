import SwiftUI

enum WalletHomeQuickAction: String, CaseIterable, Identifiable, Sendable {
    case currency
    case security
    case backupAndKeys
    case settings

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .currency:
            "settings.currency.title"
        case .security:
            "wallet.home.quick_actions.security"
        case .backupAndKeys:
            "wallet.home.quick_actions.backup"
        case .settings:
            "settings.title"
        }
    }

    var systemImage: String {
        switch self {
        case .currency:
            "globe"
        case .security:
            "faceid"
        case .backupAndKeys:
            "externaldrive.badge.icloud"
        case .settings:
            "gearshape"
        }
    }
}

struct WalletHomeQuickActionsMenu: View {
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(WalletSettingsStore.self) private var applicationSettings

    let onSelect: (WalletHomeQuickAction) -> Void

    @State private var isPresented = false
    @State private var pendingAction: WalletHomeQuickAction?
    @State private var preparedCurrencies: [SettingsCurrency] = []

    var body: some View {
        Button(action: UniHaptic.action(nil) {
            pendingAction = nil
            isPresented = true
        }) {
            Image(systemName: "gearshape.2")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel(Text("wallet.home.action.more"))
        .accessibilityIdentifier("wallet-home-quick-actions")
        .task(id: locale.identifier) {
            await prepareCurrencies()
        }
        .background {
            WalletHomeQuickActionsPopover(isPresented: $isPresented, onDismiss: finishSelection) {
                WalletHomeQuickActionsFlow(
                    initialCurrencies: preparedCurrencies,
                    onSelect: select,
                    onCurrencySelected: close
                )
                .environment(applicationSettings)
                // Carry the app's existing locale-driven environment across
                // UIKit's presentation boundary.
                .environment(\.locale, locale)
                .environment(\.layoutDirection, layoutDirection)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .environment(\.colorScheme, colorScheme)
                .environment(\.verticalSizeClass, verticalSizeClass)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // Resolve currency labels before the user opens the presentation, so the
    // transition does not wait for catalog construction or a rates request.
    @MainActor
    private func prepareCurrencies() async {
        let cached = await FXRatesClient.shared.cachedSnapshot()
        guard !Task.isCancelled else { return }
        apply(cached ?? .baseCurrencyFallback)
        do {
            let snapshot = try await FXRatesClient.shared.latestSnapshot()
            try Task.checkCancellation()
            apply(snapshot)
        } catch {
            // The currency screen retains the existing load-error/retry UI.
        }
    }

    private func apply(_ snapshot: FXRatesSnapshot) {
        let updated = SettingsCurrencyCatalog.currencies(from: snapshot, locale: locale)
        if preparedCurrencies != updated { preparedCurrencies = updated }
    }

    @MainActor
    private func select(_ action: WalletHomeQuickAction) {
        pendingAction = action
        isPresented = false
    }

    @MainActor
    private func finishSelection() {
        guard !isPresented, let action = pendingAction else { return }
        pendingAction = nil
        onSelect(action)
    }

    @MainActor
    private func close() {
        isPresented = false
    }
}
