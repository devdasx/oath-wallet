import SwiftUI

struct WalletImportPersistenceFailureView: View {
    let failure: WalletPersistenceFailure
    let isRetrying: Bool
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            WalletBackground()

            ScrollView {
                WalletPersistenceFailureDetails(
                    symbol: "square.and.arrow.down",
                    titleKey: "import.saving.error.title",
                    failure: failure
                )
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("import.navigation.title")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            WalletPersistenceFailureActions(
                backTitleKey: "import.saving.back_to_start",
                failure: failure,
                onRetry: onRetry,
                onBack: onCancel
            )
            .disabled(isRetrying)
        }
    }
}
