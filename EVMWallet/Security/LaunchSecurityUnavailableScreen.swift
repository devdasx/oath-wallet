import SwiftUI

struct LaunchSecurityUnavailableScreen: View {
    let issue: WalletPasscodeCredentialIssue
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            WalletBackground()

            ContentUnavailableView {
                Label(
                    "security.unavailable.title",
                    systemImage: "lock.shield"
                )
            } description: {
                Text(issue.messageKey)
            } actions: {
                Button("common.retry", action: UniHaptic.action(onRetry))
                    .walletPrimaryActionButtonStyle()
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .disabled(isRetrying)
            }
            .padding(.vertical, 24)
        }
        .accessibilityIdentifier(
            "launch_security_unavailable_\(issue.diagnosticCode)"
        )
    }
}
