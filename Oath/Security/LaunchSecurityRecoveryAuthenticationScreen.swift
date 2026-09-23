import SwiftUI

struct LaunchSecurityRecoveryAuthenticationScreen: View {
    let issue: WalletPasscodeCredentialIssue
    let onAuthorized: (WalletLaunchSecurityRecoveryProof) -> Void

    @State private var isAuthenticating = false
    @State private var didStartAuthentication = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            WalletBackground()

            ContentUnavailableView {
                Label(
                    "security.recovery.authentication.title",
                    systemImage: "lock.shield"
                )
            } description: {
                VStack(spacing: 12) {
                    Text("security.recovery.authentication.message")
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(WalletTheme.danger)
                    }
                }
            } actions: {
                Button("security.recovery.authentication.action", action: UniHaptic.action {
                    Task {
                        await authenticate()
                    }
                })
                .walletPrimaryActionButtonStyle()
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .disabled(isAuthenticating)
            }
            .padding(.vertical, 24)
        }
        .navigationBarBackButtonHidden()
        .task {
            guard !didStartAuthentication else { return }
            didStartAuthentication = true
            await authenticate()
        }
        .accessibilityIdentifier(
            "launch_security_recovery_\(issue.diagnosticCode)"
        )
    }

    @MainActor
    private func authenticate() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        defer {
            isAuthenticating = false
        }

        do {
            let proof = try await WalletBiometricAuthenticator.shared
                .authenticateForLaunchSecurityRecovery(
                    reason: WalletLocalization.string(
                        "security.recovery.authentication.reason"
                    )
                )
            try await WalletAuthenticationPresentationReadiness().wait()
            onAuthorized(proof)
        } catch is CancellationError {
            return
        } catch WalletBiometricAuthenticationError.cancelled {
            return
        } catch WalletBiometricAuthenticationError.unavailable {
            errorMessage = WalletLocalization.string(
                "security.recovery.authentication.unavailable"
            )
        } catch {
            errorMessage = WalletLocalization.string(
                "security.recovery.authentication.error"
            )
        }
    }
}
