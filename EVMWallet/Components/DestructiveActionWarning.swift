import SwiftUI

/// A passive destructive warning with a separate, accessible education action.
struct DestructiveActionWarning: View {
    let message: String
    let learnMoreTitle: String
    let learnMoreAccessibilityIdentifier: String
    let onLearnMore: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                warningText
                learnMoreButton
            }

            VStack(spacing: 0) {
                warningText
                learnMoreButton
            }
        }
        .font(.footnote)
        .foregroundStyle(WalletTheme.danger)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var warningText: some View {
        Text(verbatim: message)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var learnMoreButton: some View {
        Button(action: UniHaptic.action(nil, perform: onLearnMore)) {
            Text(verbatim: learnMoreTitle)
                .underline(
                    true,
                    pattern: .dot,
                    color: WalletTheme.danger
                )
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(learnMoreAccessibilityIdentifier)
    }
}
