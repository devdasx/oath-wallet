import SwiftUI

enum WalletHomeQuickActionsRoute {
    case options
    case currency
}

struct WalletHomeQuickActionsFlow: View {
    @ScaledMetric(relativeTo: .body) private var currencyHeight = 540.0
    let initialCurrencies: [SettingsCurrency]
    let onSelect: (WalletHomeQuickAction) -> Void
    let onCurrencySelected: () -> Void
    @State private var route = WalletHomeQuickActionsRoute.options
    @State private var menuHeight: CGFloat = 320

    var body: some View {
        // This flow intentionally stays in one presentation. Only UIKit's
        // preferred-content-size change animates; content has no transition.
        Group {
            switch route {
            case .options:
                WalletHomeQuickActionsRootScreen(
                    onSelect: select,
                    onContentHeightChanged: { height in
                        guard route == .options else { return }
                        menuHeight = height
                    }
                )
            case .currency:
                WalletHomeCurrencyQuickActionScreen(
                    initialCurrencies: initialCurrencies,
                    onBack: { route = .options },
                    onCurrencySelected: onCurrencySelected
                )
            }
        }
        .frame(
            minWidth: 0,
            idealWidth: route == .options ? 340 : 380,
            maxWidth: 420,
            minHeight: 0,
            idealHeight: min(route == .options ? menuHeight : currencyHeight, 620),
            maxHeight: 620,
            alignment: .top
        )
    }

    private func select(_ action: WalletHomeQuickAction) {
        if action == .currency {
            route = .currency
        } else {
            onSelect(action)
        }
    }
}
