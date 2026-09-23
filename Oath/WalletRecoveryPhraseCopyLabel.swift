import SwiftUI

/// Keeps the native list button stable while only its confirmation text changes.
struct WalletRecoveryPhraseCopyLabel: View {
    let state: WalletRecoveryPhraseCopyState

    var body: some View {
        Text(LocalizedStringKey(state.localizationKey))
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(LocalizedStringKey(state.localizationKey))
            )
    }
}
