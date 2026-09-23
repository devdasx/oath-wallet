import SwiftUI

/// A native amount row. Its owning screen keeps the unit preference, while
/// quantities remain unchanged. Value-only mode supports rows with an info action.
struct WalletTransactionValue: View {
    let title: LocalizedStringKey
    let nativeValue: String?
    let localValue: String?
    let isBalanceHidden: Bool
    @Binding var showsNative: Bool
    var valueOnly = false
    var valueColor: Color = WalletTheme.primaryLabel

    @Environment(\.walletCurrencyContext) private var currencyContext

    private var canSwitchUnits: Bool {
        nativeValue != nil && localValue != nil && !isBalanceHidden
    }

    private var displayedValue: String {
        if showsNative { nativeValue ?? localValue ?? EnglishNumbers.currency(0, using: currencyContext) }
        else { localValue ?? nativeValue ?? EnglishNumbers.currency(0, using: currencyContext) }
    }

    var body: some View {
        Group {
            if canSwitchUnits {
                if valueOnly {
                    unitButton.buttonStyle(.borderless)
                } else {
                    unitButton.buttonStyle(.automatic)
                }
            } else {
                rowContent
            }
        }
        .walletPrivacySensitive()
    }

    private var unitButton: some View {
        Button(action: UniHaptic.action { showsNative.toggle() }) {
            rowContent
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: displayedValue))
        .accessibilityHint(Text("wallet.transaction.details.toggle_units"))
    }

    @ViewBuilder
    private var rowContent: some View {
        if valueOnly {
            valueText
        } else {
            LabeledContent {
                valueText
            } label: {
                Text(title).foregroundStyle(WalletTheme.primaryLabel)
            }
        }
    }

    private var valueText: some View {
        WalletPrivacyReplacement(isHidden: isBalanceHidden, alignment: .trailing) {
            Text(verbatim: displayedValue)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
