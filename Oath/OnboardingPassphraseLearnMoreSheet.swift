import SwiftUI

struct OnboardingPassphraseLearnMoreSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                List {
                    Group {
                        combinationSection
                        derivationSection
                        separateWalletsSection
                        securitySection
                        safeUseSection
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .listStyle(.insetGrouped)
                .navigationTitle(
                    Text(
                        verbatim: WalletLocalization.string(
                            "onboarding.passphrase.learn_more.navigation"
                        )
                    )
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton {
                            dismiss()
                        }
                    }
                }
            }

        }
        .walletSheetPresentation()
    }

    private var combinationSection: some View {
        Section {
            OnboardingPassphrasePipelineVisual()

            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.overview"
                )
            )
                .foregroundStyle(WalletTheme.secondaryLabel)
        } header: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.path.section"
                )
            )
        }
    }

    private var derivationSection: some View {
        Section {
            OnboardingPassphraseDerivationVisual()

            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.derivation.standard"
                )
            )
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.derivation.normalization"
                )
            )
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.derivation.not_encryption"
                )
            )
        } header: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.derivation.section"
                )
            )
        }
    }

    private var separateWalletsSection: some View {
        Section {
            OnboardingPassphraseWalletComparisonVisual()

            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.wallets.different"
                )
            )
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.wallets.empty"
                )
            )
        } header: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.wallets.section"
                )
            )
        } footer: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.wallets.footer"
                )
            )
        }
    }

    private var securitySection: some View {
        Section {
            OnboardingPassphraseExplanationRow(
                symbol: "text.book.closed",
                title: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.security.words.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.security.words.detail"
                )
            )

            OnboardingPassphraseExplanationRow(
                symbol: "key.horizontal",
                title: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.security.strength.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.security.strength.detail"
                )
            )

            OnboardingPassphraseExplanationRow(
                symbol: "lock.shield",
                title: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.security.separation.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.security.separation.detail"
                )
            )
        } header: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.security.section"
                )
            )
        } footer: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.security.footer"
                )
            )
        }
    }

    private var safeUseSection: some View {
        Section {
            OnboardingPassphraseExplanationRow(
                symbol: "dice",
                title: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.safety.strong.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.safety.strong.detail"
                ),
                emphasis: .warning
            )

            OnboardingPassphraseExplanationRow(
                symbol: "square.on.square",
                title: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.safety.backup.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.safety.backup.detail"
                ),
                emphasis: .warning
            )

            OnboardingPassphraseExplanationRow(
                symbol: "textformat.abc",
                title: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.safety.exact.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.safety.exact.detail"
                ),
                emphasis: .warning
            )

            OnboardingPassphraseExplanationRow(
                symbol: "checkmark.seal",
                title: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.safety.verify.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.safety.verify.detail"
                ),
                emphasis: .warning
            )
        } header: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.safety.section"
                )
            )
        } footer: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.safety.footer"
                )
            )
        }
    }
}

private struct OnboardingPassphrasePipelineVisual: View {
    var body: some View {
        VStack(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                horizontalInputs
                verticalInputs
            }

            Image(systemName: "arrow.down")
                .font(.headline)
                .foregroundStyle(WalletTheme.accent)
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                Image(systemName: "wallet.bifold")
                    .font(.title2)
                    .foregroundStyle(WalletTheme.accent)

                Text(
                    verbatim: WalletLocalization.string(
                        "onboarding.passphrase.learn_more.visual.wallet"
                    )
                )
                    .font(.headline)
                    .foregroundStyle(WalletTheme.primaryLabel)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(WalletTheme.tertiaryFill, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.visual.accessibility"
                )
            )
        )
    }

    private var horizontalInputs: some View {
        HStack(spacing: 10) {
            input(
                symbol: "text.book.closed",
                title: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.visual.phrase"
                )
            )
            operatorSymbol("plus")
            input(
                symbol: "key.horizontal",
                title: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.visual.passphrase"
                )
            )
        }
    }

    private var verticalInputs: some View {
        VStack(spacing: 10) {
            input(
                symbol: "text.book.closed",
                title: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.visual.phrase"
                )
            )
            operatorSymbol("plus")
            input(
                symbol: "key.horizontal",
                title: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.visual.passphrase"
                )
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func input(symbol: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(WalletTheme.accent)

            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            WalletTheme.tertiaryFill,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func operatorSymbol(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(WalletTheme.secondaryLabel)
            .accessibilityHidden(true)
    }
}

private struct OnboardingPassphraseDerivationVisual: View {
    private var stageTitles: [String] {
        [
            WalletLocalization.string(
                "onboarding.passphrase.learn_more.derivation.visual.inputs"
            ),
            WalletLocalization.string(
                "onboarding.passphrase.learn_more.derivation.visual.function"
            ),
            WalletLocalization.string(
                "onboarding.passphrase.learn_more.derivation.visual.seed"
            ),
            WalletLocalization.string(
                "onboarding.passphrase.learn_more.derivation.visual.accounts"
            )
        ]
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(stageTitles.enumerated()), id: \.offset) {
                index, title in
                Text(verbatim: title)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        WalletTheme.tertiaryFill,
                        in: RoundedRectangle(
                            cornerRadius: 12,
                            style: .continuous
                        )
                    )

                if index < stageTitles.count - 1 {
                    Image(systemName: "arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WalletTheme.secondaryLabel)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.derivation.visual.accessibility"
                )
            )
        )
    }
}

private struct OnboardingPassphraseWalletComparisonVisual: View {
    var body: some View {
        VStack(spacing: 10) {
            walletRow(
                passphrase: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.wallets.visual.one"
                ),
                wallet: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.wallets.visual.wallet_a"
                )
            )
            walletRow(
                passphrase: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.wallets.visual.two"
                ),
                wallet: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.wallets.visual.wallet_b"
                )
            )
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.passphrase.learn_more.wallets.visual.accessibility"
                )
            )
        )
    }

    private func walletRow(
        passphrase: String,
        wallet: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(WalletTheme.accent)

            Text(verbatim: passphrase)
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 8)

            Image(systemName: "arrow.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WalletTheme.secondaryLabel)
                .accessibilityHidden(true)

            Text(verbatim: wallet)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WalletTheme.primaryLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            WalletTheme.tertiaryFill,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct OnboardingPassphraseExplanationRow: View {
    enum Emphasis: Equatable {
        case standard
        case warning
    }

    let symbol: String
    let title: String
    let detail: String
    var emphasis: Emphasis = .standard

    @ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 38

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(symbolColor)
                .frame(width: symbolSize, height: symbolSize)
                .background(WalletTheme.tertiaryFill, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(WalletTheme.primaryLabel)

                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var symbolColor: Color {
        emphasis == .warning ? WalletTheme.warning : WalletTheme.accent
    }
}
