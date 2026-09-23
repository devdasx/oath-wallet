import SwiftUI

struct OnboardingPhysicalEntropyInputScreen: View {
    let isGeneratingWallet: Bool
    let errorMessage: String?
    let onComplete: (Data) -> Void

    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion

    @ScaledMetric(relativeTo: .title2)
    private var coinDiameter: CGFloat = 88
    @ScaledMetric(relativeTo: .body)
    private var diceSideLength: CGFloat = 72
    @State private var method: SettingsWalletEntropyMethod = .dice
    @State private var accumulator = SettingsWalletEntropyAccumulator()
    @State private var isShowingInputInfo = false

    private let digitColumns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: SettingsWalletEntropyDigitGrid.columnCount
    )
    private let diceColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    private let coinColumns = [
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24)
    ]

    var body: some View {
        List {
            Group {
                entropyHealthSection
                if !accumulator.entries.isEmpty {
                    entropyStatusSection
                }

                if let errorMessage {
                    Section {
                        Text(verbatim: errorMessage)
                            .foregroundStyle(WalletTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationTitle("wallet.creation.entropy.navigation")
        .navigationBarTitleDisplayMode(.inline)
        .walletSafeAreaBar(edge: .top, spacing: 0) {
            SettingsWalletEntropyMethodSelector(
                selection: $method,
                isDisabled: isGeneratingWallet
                    || accumulator.healthAssessment.requiresIntervention
            )
            .padding(.vertical, 8)
        }
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Text(LocalizedStringKey(inputGuidanceKey))
                    .font(.body)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 28)

                inputControls

                PrimaryWalletButton(
                    title: "wallet.creation.entropy.use",
                    action: complete
                )
                .disabled(
                    !accumulator.isReadyForWalletCreation
                        || isGeneratingWallet
                )
                .walletActionScreenMargins()
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var inputControls: some View {
        switch method {
        case .dice:
            LazyVGrid(columns: diceColumns, spacing: 12) {
                ForEach(1...6, id: \.self) { face in
                    diceButton(face: face) {
                        accumulator.appendDiceFace(face)
                    }
                }
            }
            .walletNumericKeypadLayout()
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)

        case .coin:
            LazyVGrid(columns: coinColumns, spacing: 16) {
                coinButton(
                    title: WalletLocalization.string(
                        "wallet.creation.entropy.coin.heads"
                    ),
                    side: .heads
                ) {
                    accumulator.appendCoinSide(.heads)
                }

                coinButton(
                    title: WalletLocalization.string(
                        "wallet.creation.entropy.coin.tails"
                    ),
                    side: .tails
                ) {
                    accumulator.appendCoinSide(.tails)
                }
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)

        case .digits:
            LazyVGrid(columns: digitColumns, spacing: 12) {
                ForEach(
                    0..<SettingsWalletEntropyDigitGrid.digitCount,
                    id: \.self
                ) { digit in
                    digitButton(digit)
                }
            }
            .walletNumericKeypadLayout()
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
        }
    }

    private var inputGuidanceKey: String {
        switch method {
        case .dice:
            "wallet.creation.entropy.dice.footer"
        case .coin:
            "wallet.creation.entropy.coin.footer"
        case .digits:
            "wallet.creation.entropy.digits.footer"
        }
    }

    private var entropyStatusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("wallet.creation.entropy.progress.label")
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    Text(
                        verbatim: EnglishNumbers.localized(
                            "wallet.creation.entropy.progress.value",
                            accumulator.bitCount,
                            SettingsWalletEntropyAccumulator.requiredBitCount
                        )
                    )
                    .monospacedDigit()
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                }
                .accessibilityElement(children: .combine)

                SettingsWalletEntropyRecentInputs(
                    entries: accumulator.entries,
                    assessment: accumulator.healthAssessment
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsWalletEntropyInputActions(
                isDisabled: isGeneratingWallet,
                onUndo: undoLastInput,
                onReset: resetEntropy
            )
        } header: {
            Text("wallet.creation.entropy.status.section")
        } footer: {
            Text("wallet.creation.entropy.footer")
        }
    }

    private var entropyHealthSection: some View {
        SettingsWalletEntropyHealthSection(
            assessment: accumulator.healthAssessment,
            isShowingInfo: $isShowingInputInfo
        ) {
            OnboardingEntropyInputInfoPopover(
                assessment: accumulator.healthAssessment
            )
        }
    }

    private func digitButton(_ digit: Int) -> some View {
        let title = EnglishNumbers.integer(Int64(digit))
        let accessibilityLabel = EnglishNumbers.localized(
            "wallet.creation.entropy.digit.accessibility",
            digit
        )

        return Button(action: UniHaptic.action {
            recordInput {
                accumulator.appendDigit(digit)
            }
        }) {
            Text(verbatim: title)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .walletPrimaryActionButtonStyle()
        .buttonBorderShape(.roundedRectangle)
        .controlSize(.large)
        .walletEntropyLastChoiceBadge(
            entryID: accumulator.latestEntryID(for: .digit(digit))
        )
        .disabled(inputIsDisabled)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    private func diceButton(
        face: Int,
        action: @escaping () -> Bool
    ) -> some View {
        Button(action: UniHaptic.action {
            recordInput(action)
        }) {
            SettingsWalletEntropyDieFace(face: face)
                .frame(
                    width: resolvedDiceSideLength,
                    height: resolvedDiceSideLength
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(.rect)
        }
        .buttonStyle(SettingsWalletEntropyPopButtonStyle())
        .walletEntropyLastChoiceBadge(
            entryID: accumulator.latestEntryID(
                for: .dice(face: face)
            )
        )
        .disabled(inputIsDisabled)
        .opacity(inputIsDisabled ? 0.45 : 1)
        .accessibilityLabel(
            Text(
                verbatim: EnglishNumbers.localized(
                    "wallet.creation.entropy.dice.face",
                    face
                )
            )
        )
    }

    private var resolvedDiceSideLength: CGFloat {
        min(max(diceSideLength, 64), 82)
    }

    private func coinButton(
        title: String,
        side: SettingsWalletEntropyCoinSide,
        action: @escaping () -> Bool
    ) -> some View {
        Button(action: UniHaptic.action {
            recordInput(action)
        }) {
            VStack(spacing: 10) {
                SettingsWalletEntropyCoinFace(
                    side: side,
                    diameter: coinDiameter
                )

                Text(verbatim: title)
                    .font(.headline)
                    .foregroundStyle(WalletTheme.primaryLabel)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(SettingsWalletEntropyPopButtonStyle())
        .walletEntropyLastChoiceBadge(
            entryID: accumulator.latestEntryID(
                for: .coin(side: side)
            )
        )
        .disabled(inputIsDisabled)
        .opacity(inputIsDisabled ? 0.45 : 1)
        .accessibilityLabel(Text(verbatim: title))
    }

    private func recordInput(_ action: () -> Bool) {
        let didRecord = withAnimation(
            accessibilityReduceMotion
                ? nil
                : .smooth(duration: 0.28)
        ) {
            action()
        }
        guard didRecord else { return }
        UniHaptic.play(.selection)
    }

    private func undoLastInput() {
        withAnimation(
            accessibilityReduceMotion
                ? nil
                : .smooth(duration: 0.28)
        ) {
            accumulator.undoLastEntry()
        }
    }

    private func resetEntropy() {
        withAnimation(
            accessibilityReduceMotion
                ? nil
                : .smooth(duration: 0.28)
        ) {
            accumulator.reset()
        }
    }

    private var inputIsDisabled: Bool {
        accumulator.isComplete
            || isGeneratingWallet
            || accumulator.healthAssessment.requiresIntervention
    }

    private func complete() {
        guard let entropy = accumulator.entropyData else { return }
        onComplete(entropy)
    }
}
