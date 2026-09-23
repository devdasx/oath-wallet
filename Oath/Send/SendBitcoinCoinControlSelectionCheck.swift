import SwiftUI

struct SendBitcoinCoinControlSelectionCheck: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(WalletTheme.accent)
            .opacity(isSelected ? 1 : 0)
            .accessibilityHidden(true)
    }
}
