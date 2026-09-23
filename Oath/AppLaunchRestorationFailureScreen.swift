import SwiftUI

struct AppLaunchRestorationFailureScreen: View {
    let failure: AppLaunchWalletRestorationFailure
    let isRetrying: Bool
    let retry: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            WalletBackground()

            ContentUnavailableView {
                Label(
                    "wallet.launch.restore.error.title",
                    systemImage:
                        "externaldrive.badge.exclamationmark"
                )
            } description: {
                VStack(spacing: 12) {
                    Text(LocalizedStringKey(failure.messageKey))
                    Text(
                        EnglishNumbers.localized(
                            "wallet.persistence.support.hint",
                            WalletSupport.emailAddress
                        )
                    )
                    Text(
                        EnglishNumbers.localized(
                            "wallet.persistence.error.reference",
                            failure.diagnosticCode
                        )
                    )
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                }
            } actions: {
                VStack(spacing: 12) {
                    Button("common.try_again", action: UniHaptic.action(retry))
                        .walletPrimaryActionButtonStyle()
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .disabled(isRetrying)

                    Button("wallet.persistence.contact_support", action: UniHaptic.action(nil) {
                        guard let supportURL = failure.supportURL else {
                            return
                        }
                        openURL(supportURL)
                    })
                    .disabled(failure.supportURL == nil)
                }
            }
            .padding(.vertical, 24)
        }
    }
}
