import SwiftUI

enum OnboardingEntropyEducationFacts {
    static let entropyBitCount =
        SettingsWalletEntropyAccumulator.requiredBitCount
    static let bitsPerByte = 8
    static let entropyByteCount = entropyBitCount / bitsPerByte
    static let checksumBitCount = entropyBitCount / 32
    static let encodedBitCount = entropyBitCount + checksumBitCount
    static let bitsPerWord = 11
    static let recoveryWordCount = encodedBitCount / bitsPerWord
    static let wordListEntryCount = 1 << bitsPerWord
}

struct OnboardingEntropyLearnMoreSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                List {
                    Group {
                        completePathSection
                        physicalInputsSection
                        entropyConstructionSection
                        recoveryPhraseSection
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
                            "onboarding.entropy.learn_more.navigation"
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

    private var completePathSection: some View {
        Section {
            OnboardingEntropyPipelineVisual()

            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.overview"
                )
            )
                .foregroundStyle(WalletTheme.secondaryLabel)
        } header: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.path.section"
                )
            )
        }
    }

    private var physicalInputsSection: some View {
        Section {
            ForEach(OnboardingEntropyEducationSource.allCases) { source in
                OnboardingEntropySourceExplanationRow(source: source)
            }
        } header: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.inputs.section"
                )
            )
        } footer: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.inputs.footer"
                )
            )
        }
    }

    private var entropyConstructionSection: some View {
        Section {
            OnboardingEntropyBitFieldVisual()

            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.conversion.mapping"
                )
            )
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.conversion.packing"
                )
            )
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.conversion.no_mixing"
                )
            )
        } header: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.conversion.section"
                )
            )
        }
    }

    private var recoveryPhraseSection: some View {
        Section {
            OnboardingEntropyBIP39Visual()

            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.bip39.checksum"
                )
            )
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.bip39.words"
                )
            )
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.bip39.derivation"
                )
            )
        } header: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.bip39.section"
                )
            )
        }
    }

    private var securitySection: some View {
        Section {
            OnboardingEntropyExplanationRow(
                symbol: "number",
                title: WalletLocalization.string(
                    "onboarding.entropy.learn_more.security.space.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.entropy.learn_more.security.space.detail"
                )
            )

            OnboardingEntropyExplanationRow(
                symbol: "die.face.5",
                title: WalletLocalization.string(
                    "onboarding.entropy.learn_more.security.source.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.entropy.learn_more.security.source.detail"
                )
            )

            OnboardingEntropyExplanationRow(
                symbol: "iphone",
                title: WalletLocalization.string(
                    "onboarding.entropy.learn_more.security.local.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.entropy.learn_more.security.local.detail"
                )
            )

            OnboardingEntropyExplanationRow(
                symbol: "person.fill.questionmark",
                title: WalletLocalization.string(
                    "onboarding.entropy.learn_more.security.patterns.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.entropy.learn_more.security.patterns.detail"
                )
            )
        } header: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.security.section"
                )
            )
        } footer: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.security.footer"
                )
            )
        }
    }

    private var safeUseSection: some View {
        Section {
            OnboardingEntropyExplanationRow(
                symbol: "checkmark.seal",
                title: WalletLocalization.string(
                    "onboarding.entropy.learn_more.safety.fair.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.entropy.learn_more.safety.fair.detail"
                ),
                emphasis: .warning
            )

            OnboardingEntropyExplanationRow(
                symbol: "eye.slash",
                title: WalletLocalization.string(
                    "onboarding.entropy.learn_more.safety.private.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.entropy.learn_more.safety.private.detail"
                ),
                emphasis: .warning
            )

            OnboardingEntropyExplanationRow(
                symbol: "list.number",
                title: WalletLocalization.string(
                    "onboarding.entropy.learn_more.safety.accurate.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.entropy.learn_more.safety.accurate.detail"
                ),
                emphasis: .warning
            )

            OnboardingEntropyExplanationRow(
                symbol: "lock.shield",
                title: WalletLocalization.string(
                    "onboarding.entropy.learn_more.safety.backup.title"
                ),
                detail: WalletLocalization.string(
                    "onboarding.entropy.learn_more.safety.backup.detail"
                ),
                emphasis: .warning
            )
        } header: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.safety.section"
                )
            )
        } footer: {
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.safety.footer"
                )
            )
        }
    }
}

private enum OnboardingEntropyEducationSource: String, CaseIterable,
    Identifiable
{
    case dice
    case coin
    case digits

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .dice:
            WalletLocalization.string(
                "onboarding.entropy.learn_more.inputs.dice.title"
            )
        case .coin:
            WalletLocalization.string(
                "onboarding.entropy.learn_more.inputs.coin.title"
            )
        case .digits:
            WalletLocalization.string(
                "onboarding.entropy.learn_more.inputs.digits.title"
            )
        }
    }

    var localizedDetail: String {
        switch self {
        case .dice:
            WalletLocalization.string(
                "onboarding.entropy.learn_more.inputs.dice.detail"
            )
        case .coin:
            WalletLocalization.string(
                "onboarding.entropy.learn_more.inputs.coin.detail"
            )
        case .digits:
            WalletLocalization.string(
                "onboarding.entropy.learn_more.inputs.digits.detail"
            )
        }
    }
}

private struct OnboardingEntropySourceExplanationRow: View {
    let source: OnboardingEntropyEducationSource

    @ScaledMetric(relativeTo: .body) private var visualSize: CGFloat = 46

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            OnboardingEntropySourceVisual(
                source: source,
                size: visualSize
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: source.localizedTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(WalletTheme.primaryLabel)

                Text(verbatim: source.localizedDetail)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct OnboardingEntropySourceVisual: View {
    let source: OnboardingEntropyEducationSource
    let size: CGFloat

    var body: some View {
        Group {
            switch source {
            case .dice:
                SettingsWalletEntropyDieFace(face: 5)

            case .coin:
                SettingsWalletEntropyCoinFace(
                    side: .heads,
                    diameter: size
                )

            case .digits:
                Text(verbatim: EnglishNumbers.integer(739))
                    .font(.system(.subheadline, design: .monospaced).bold())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        WalletTheme.tertiaryFill,
                        in: RoundedRectangle(
                            cornerRadius: size * 0.24,
                            style: .continuous
                        )
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct OnboardingEntropyPipelineVisual: View {
    @ScaledMetric(relativeTo: .body) private var sourceSize: CGFloat = 50

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                ForEach(OnboardingEntropyEducationSource.allCases) {
                    source in
                    OnboardingEntropySourceVisual(
                        source: source,
                        size: sourceSize
                    )
                }
            }

            Image(systemName: "arrow.down")
                .font(.headline)
                .foregroundStyle(WalletTheme.accent)

            OnboardingEntropyBitFieldVisual()

            Image(systemName: "arrow.down")
                .font(.headline)
                .foregroundStyle(WalletTheme.accent)

            HStack(spacing: 10) {
                Image(systemName: "text.book.closed")
                    .font(.title2)
                    .foregroundStyle(WalletTheme.accent)

                Text(
                    verbatim: WalletLocalization.string(
                        "onboarding.entropy.learn_more.visual.phrase"
                    )
                )
                    .font(.headline)
                    .foregroundStyle(WalletTheme.primaryLabel)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                WalletTheme.tertiaryFill,
                in: Capsule()
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.visual.accessibility"
                )
            )
        )
    }
}

private struct OnboardingEntropyBitFieldVisual: View {
    var body: some View {
        VStack(spacing: 8) {
            Canvas { context, size in
                let columns = 32
                let rows = 8
                let spacing = max(1, min(size.width, size.height) * 0.018)
                let cellWidth =
                    (size.width - spacing * CGFloat(columns - 1))
                    / CGFloat(columns)
                let cellHeight =
                    (size.height - spacing * CGFloat(rows - 1))
                    / CGFloat(rows)

                for index in 0..<(columns * rows) {
                    let column = index % columns
                    let row = index / columns
                    let rect = CGRect(
                        x: CGFloat(column) * (cellWidth + spacing),
                        y: CGFloat(row) * (cellHeight + spacing),
                        width: cellWidth,
                        height: cellHeight
                    )
                    let path = Path(
                        roundedRect: rect,
                        cornerRadius: min(cellWidth, cellHeight) * 0.3
                    )
                    let isOne = ((index * 73 + 29) % 11) < 5
                    context.fill(
                        path,
                        with: .color(
                            isOne
                                ? WalletTheme.accent
                                : WalletTheme.mutedSecondaryFill
                        )
                    )
                }
            }
            .aspectRatio(4, contentMode: .fit)

            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.visual.bits"
                )
            )
                .font(.caption.monospacedDigit())
                .foregroundStyle(WalletTheme.secondaryLabel)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.visual.bits.accessibility"
                )
            )
        )
    }
}

private struct OnboardingEntropyBIP39Visual: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalStages
            verticalStages
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: WalletLocalization.string(
                    "onboarding.entropy.learn_more.bip39.visual.accessibility"
                )
            )
        )
    }

    private var horizontalStages: some View {
        HStack(spacing: 8) {
            stage(
                WalletLocalization.string(
                    "onboarding.entropy.learn_more.bip39.visual.entropy"
                )
            )
            symbol("plus")
            stage(
                WalletLocalization.string(
                    "onboarding.entropy.learn_more.bip39.visual.checksum"
                )
            )
            symbol("equal")
            stage(
                WalletLocalization.string(
                    "onboarding.entropy.learn_more.bip39.visual.words"
                )
            )
        }
    }

    private var verticalStages: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                stage(
                    WalletLocalization.string(
                        "onboarding.entropy.learn_more.bip39.visual.entropy"
                    )
                )
                symbol("plus")
                stage(
                    WalletLocalization.string(
                        "onboarding.entropy.learn_more.bip39.visual.checksum"
                    )
                )
            }

            Image(systemName: "arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WalletTheme.secondaryLabel)

            stage(
                WalletLocalization.string(
                    "onboarding.entropy.learn_more.bip39.visual.words"
                )
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func stage(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.caption.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                WalletTheme.tertiaryFill,
                in: RoundedRectangle(
                    cornerRadius: 12,
                    style: .continuous
                )
            )
    }

    private func symbol(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(WalletTheme.secondaryLabel)
            .accessibilityHidden(true)
    }
}

private struct OnboardingEntropyExplanationRow: View {
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
