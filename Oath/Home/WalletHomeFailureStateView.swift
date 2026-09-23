import SwiftUI

struct WalletHomeFailureStateView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("wallet.home.error.title")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("wallet.home.error.message")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            SecondaryWalletButton(
                title: "wallet.home.error.retry",
                action: onRetry
            )
            .padding(.top, 12)
        }
        .frame(minHeight: 420)
        .walletActionScreenMargins()
    }
}
