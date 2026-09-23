import SwiftUI

struct SendTransactionAuthorizationScreen: View {
    private enum Phase {
        case loading
        case authenticating(WalletSecuritySettings)
        case failed(String)
    }

    let database: WalletDatabase
    let draft: SendDraft
    let initialErrorKey: String?
    let onAuthorized: (SendTransactionAuthorization) -> Void

    @State private var phase: Phase = .loading
    @State private var walletID: String?
    @State private var didStart = false
    @State private var isIssuingAuthorization = false

    var body: some View {
        Group {
            switch phase {
            case .loading:
                loadingSkeleton
            case let .authenticating(settings):
                WalletSecurityAuthenticationView(
                    database: database,
                    settings: settings,
                    purpose: .sendTransaction,
                    beginsWithPasscode: true,
                    initialErrorKey: initialErrorKey,
                    onAuthenticationGranted: completeAuthentication
                )
            case let .failed(message):
                failureContent(message)
            }
        }
        .background(WalletTheme.groupedBackground)
        .walletCallSafetyWarning(.sending)
        .task {
            guard !didStart else { return }
            didStart = true
            await prepareAccess()
        }
    }

    private var loadingSkeleton: some View {
        WalletBackground()
            .overlay {
                PasscodeResponsiveContainer {
                    VStack(spacing: 22) {
                        RoundedRectangle(
                            cornerRadius: 8,
                            style: .continuous
                        )
                        .fill(WalletTheme.tertiaryFill)
                        .frame(width: 42, height: 52)

                        RoundedRectangle(
                            cornerRadius: 7,
                            style: .continuous
                        )
                        .fill(WalletTheme.tertiaryFill)
                        .frame(width: 230, height: 34)

                        RoundedRectangle(
                            cornerRadius: 6,
                            style: .continuous
                        )
                        .fill(WalletTheme.tertiaryFill)
                        .frame(maxWidth: 340)
                        .frame(height: 18)

                        HStack(spacing: 18) {
                            ForEach(0..<6, id: \.self) { _ in
                                Circle()
                                    .fill(WalletTheme.tertiaryFill)
                                    .frame(width: 20, height: 20)
                            }
                        }
                        .padding(.top, 12)
                    }
                    .sendSkeletonPulse()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        Text("send.authorization.loading")
                    )
                }
            }
    }

    private func failureContent(_ message: String) -> some View {
        List {
            Group {
                Section {
                    Text(verbatim: message)
                        .foregroundStyle(.secondary)

                    Button("common.try_again", action: UniHaptic.action {
                        retry()
                    })
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
    }

    @MainActor
    private func prepareAccess() async {
        do {
            guard let identity = try await database
                .selectedWalletIdentity() else {
                throw SendTransactionAuthorizationScreenError
                    .walletUnavailable
            }
            walletID = identity.walletID
            phase = .authenticating(
                try await database.walletSecuritySettings()
            )
        } catch {
            showFailure()
        }
    }

    private func completeAuthentication(
        _ grant: WalletAuthenticationGrant
    ) {
        guard !isIssuingAuthorization, let walletID else { return }
        isIssuingAuthorization = true
        Task { @MainActor in
            do {
                let transactionAuthorization = try await
                    SendTransactionAuthorizationIssuer(
                        database: database
                    ).issue(
                        reviewedDraft: draft,
                        walletID: walletID,
                        authenticationGrant: grant
                    )
                onAuthorized(transactionAuthorization)
            } catch {
                showFailure()
            }
        }
    }

    private func retry() {
        walletID = nil
        isIssuingAuthorization = false
        phase = .loading
        Task {
            await prepareAccess()
        }
    }

    private func showFailure() {
        isIssuingAuthorization = false
        phase = .failed(
            WalletLocalization.string(
                "send.authorization.error.unavailable"
            )
        )
    }
}

private enum SendTransactionAuthorizationScreenError: Error {
    case walletUnavailable
}
