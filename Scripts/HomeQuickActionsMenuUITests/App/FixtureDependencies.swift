import Observation
import SwiftUI

// Only non-UI dependencies are substituted. The menu, flow, screens and
// currency catalog are compiled directly from the production source files.
@MainActor @Observable
final class WalletSettingsStore {
    var currencyCode = "JOD"

    func selectCurrency(code: String, ratePerUSD: Decimal) {
        currencyCode = code
    }

    func updateSelectedCurrencyRate(_ rate: Decimal) {}
}

enum WalletFirstRunSettings {
    static func regionalCurrencyCode(locale: Locale) -> String { "JOD" }
}

enum WalletCurrencyPreference {
    static let defaultCode = "USD"
}

enum WalletTheme {
    static let primaryLabel = Color.primary
    static let secondaryLabel = Color.secondary
}

enum SettingsRowIcon {
    case currencyConverter
    var systemImage: String { "arrow.left.arrow.right" }
}

enum UniHaptic {
    case selection
    static func play(_ haptic: UniHaptic) {}
}

struct WalletSearchEmptyStateView: View {
    var body: some View { Text("settings.currency.search") }
}

extension View {
    @ViewBuilder
    func walletPrimaryActionButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Color(uiColor: .systemBlue))
        } else {
            buttonStyle(.borderedProminent).tint(Color(uiColor: .systemBlue))
        }
    }

    @ViewBuilder
    func walletAutomaticSearchToolbarBehavior() -> some View {
        if #available(iOS 26.0, *) {
            searchToolbarBehavior(.automatic)
        } else {
            self
        }
    }
}
