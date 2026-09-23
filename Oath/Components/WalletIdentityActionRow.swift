import SwiftUI

/// A single native list action, including its label, value, and row insets.
struct WalletIdentityActionRow: View {
    let title: LocalizedStringKey
    let value: String
    let displayedValue: String
    var showsDisclosureIndicator = false
    var valueColor: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: UniHaptic.action(nil, perform: action)) {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(verbatim: displayedValue)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(valueColor ?? WalletTheme.secondaryLabel)
                    if showsDisclosureIndicator {
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(WalletTheme.tertiaryLabel)
                            .accessibilityHidden(true)
                    }
                }
            } label: {
                Text(title)
                    .foregroundStyle(WalletTheme.primaryLabel)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.automatic)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: value))
    }
}
