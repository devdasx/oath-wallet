import SwiftUI

struct WalletPersistenceFailureDetails: View {
    let symbol: String
    let titleKey: LocalizedStringKey
    let failure: WalletPersistenceFailure

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: WalletSFSymbol.weight))
                .foregroundStyle(WalletTheme.warning)
                .accessibilityHidden(true)

            Text(titleKey)
                .font(WalletTypography.title(.title))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 28)

            Text(LocalizedStringKey(failure.messageKey))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Text(
                verbatim: EnglishNumbers.localized(
                    "wallet.persistence.support.hint",
                    WalletSupport.emailAddress
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 24)

            Text(
                verbatim: EnglishNumbers.localized(
                    "wallet.persistence.error.reference",
                    failure.diagnosticCode
                )
            )
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .padding(.top, 10)
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 28)
        .padding(.top, 54)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity)
    }
}

struct WalletPersistenceFailureActions: View {
    let backTitleKey: LocalizedStringKey
    let failure: WalletPersistenceFailure
    let onRetry: () -> Void
    let onBack: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 12) {
            PrimaryWalletButton(
                title: "import.saving.retry",
                action: onRetry
            )

            SecondaryWalletButton(
                title: backTitleKey,
                hapticPolicy: .silent,
                action: onBack
            )

            Button("wallet.persistence.contact_support", action: UniHaptic.action(nil) {
                guard let supportURL = failure.supportURL else {
                    return
                }
                openURL(supportURL)
            })
            .buttonStyle(.plain)
            .font(.body.weight(.semibold))
            .foregroundStyle(WalletTheme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .walletActionScreenMargins()
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}
