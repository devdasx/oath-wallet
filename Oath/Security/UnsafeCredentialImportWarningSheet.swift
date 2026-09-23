import SwiftUI

struct UnsafeCredentialImportWarning: Identifiable, Sendable {
    let id = UUID()
    let finding: WalletCredentialSafetyFinding
}

struct UnsafeCredentialImportWarningSheet: View {
    let warning: UnsafeCredentialImportWarning
    let onChooseDifferent: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        VStack(spacing: 0) {
            Label(
                "import.safety.navigation.title",
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.headline.weight(.semibold))
            .foregroundStyle(WalletTheme.danger)
            .padding(.top, verticalSizeClass == .compact ? 12 : 28)

            VStack(spacing: verticalSizeClass == .compact ? 8 : 20) {
                Text(titleKey)
                    .font(WalletTypography.title(.title2))
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .accessibilityAddTraits(.isHeader)

                Text(messageKey)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: 560, maxHeight: .infinity, alignment: .center)
            .padding(.vertical, verticalSizeClass == .compact ? 8 : 20)

            PrimaryWalletButton(
                title: actionKey,
                hapticPolicy: .silent,
                action: onChooseDifferent
            )
            .frame(maxWidth: 560)
            .padding(.bottom, 8)
        }
        .walletActionScreenMargins()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .walletSheetPresentation(nativeGlass: true)
        // Apple's medium detent is inactive in compact height. Keep a single
        // half-height stop in landscape too; never offer a large detent.
        .presentationDetents(verticalSizeClass == .compact ? [.fraction(0.5)] : [.medium])
        .presentationCompactAdaptation(.none)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }

    private var actionKey: LocalizedStringKey {
        switch warning.finding.credentialKind {
        case .recoveryPhrase: "import.safety.action.different_recovery_phrase"
        case .privateKey: "import.safety.action.different_private_key"
        }
    }

    private var titleKey: LocalizedStringKey {
        switch (warning.finding.credentialKind, warning.finding.reason) {
        case (.recoveryPhrase, .publiclyKnown):
            "import.safety.public.recovery.title"
        case (.privateKey, .publiclyKnown):
            "import.safety.public.private_key.title"
        case (.recoveryPhrase, .predictablyWeak):
            "import.safety.weak.recovery.title"
        case (.privateKey, .predictablyWeak):
            "import.safety.weak.private_key.title"
        }
    }

    private var messageKey: LocalizedStringKey {
        switch (warning.finding.credentialKind, warning.finding.reason) {
        case (.recoveryPhrase, .publiclyKnown):
            "import.safety.public.recovery.message"
        case (.privateKey, .publiclyKnown):
            "import.safety.public.private_key.message"
        case (.recoveryPhrase, .predictablyWeak):
            "import.safety.weak.recovery.message"
        case (.privateKey, .predictablyWeak):
            "import.safety.weak.private_key.message"
        }
    }
}
