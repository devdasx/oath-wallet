import SwiftUI

/// Stateless native-list content; no modal gate or import dependency.
struct TronMultisignatureWarningRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("tron.permissions.warning.title")
                    .font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .symbolRenderingMode(.monochrome)
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isHeader)

            Text("tron.permissions.warning.body")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .foregroundStyle(WalletTheme.onDangerLabel)
        .listRowBackground(WalletTheme.danger)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.tron.multisignature.warning")
    }
}
