import SwiftUI

enum WalletDestructiveProgressStatus: String, Hashable, Sendable {
    case running
    case failed
    case completed
}

/// Converts stage-start callbacks into one completion event for the stage
/// that just finished. A flow calls `finish()` only after its operation has
/// succeeded, so a failed active stage never produces a success haptic.
struct WalletDestructiveProgressCompletionTracker<Stage: Equatable> {
    private var activeStage: Stage?
    private var didFinish = false

    mutating func transition(to nextStage: Stage) -> Bool {
        guard !didFinish else { return false }
        defer {
            activeStage = nextStage
        }
        guard let activeStage else { return false }
        return activeStage != nextStage
    }

    mutating func finish() -> Bool {
        guard !didFinish, activeStage != nil else { return false }
        didFinish = true
        return true
    }
}

struct WalletDestructiveProgressCopy: Identifiable {
    let id: String
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey
}

/// Shared, stateless presentation for destructive-operation progress sheets.
/// Each flow owns its execution, lifecycle, and actions in a separate screen.
struct WalletDestructiveProgressContent: View {
    let status: WalletDestructiveProgressStatus
    let transitionIdentity: String
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey
    let stableCopies: [WalletDestructiveProgressCopy]
    let progressAccessibilityKey: LocalizedStringKey
    let stepLocalizationKey: String
    let step: Int?
    let totalSteps: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            indicator

            ZStack {
                ForEach(stableCopies) { copy in
                    copyContent(
                        titleKey: copy.titleKey,
                        detailKey: copy.detailKey
                    )
                    .hidden()
                    .accessibilityHidden(true)
                }

                copyContent(titleKey: titleKey, detailKey: detailKey)
                    .contentTransition(.opacity)
            }
            .padding(.top, 24)
            .animation(replacementAnimation, value: transitionIdentity)

            if status == .running,
               let step,
               let totalSteps {
                progress(step: step, totalSteps: totalSteps)
                    .padding(.top, 28)
                    .transition(.opacity)
            }
        }
    }

    private func copyContent(
        titleKey: LocalizedStringKey,
        detailKey: LocalizedStringKey
    ) -> some View {
        VStack(spacing: 10) {
            Text(titleKey)
                .font(WalletTypography.title(.title))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(detailKey)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        ZStack {
            switch status {
            case .running:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(.primary)
                    .accessibilityLabel(Text(progressAccessibilityKey))
                    .id(WalletDestructiveProgressStatus.running)
                    .transition(indicatorTransition)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(WalletTheme.danger)
                    .accessibilityHidden(true)
                    .id(WalletDestructiveProgressStatus.failed)
                    .transition(indicatorTransition)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(WalletTheme.success)
                    .accessibilityHidden(true)
                    .id(WalletDestructiveProgressStatus.completed)
                    .transition(indicatorTransition)
            }
        }
        .animation(replacementAnimation, value: status)
    }

    private func progress(
        step: Int,
        totalSteps: Int
    ) -> some View {
        VStack(spacing: 8) {
            ProgressView(
                value: Double(step),
                total: Double(totalSteps)
            )
            .progressViewStyle(.linear)
            .animation(progressAnimation, value: step)
            .accessibilityIdentifier("walletDestructiveProgressBar")

            stepText(step: step, totalSteps: totalSteps)
        }
    }

    @ViewBuilder
    private func stepText(
        step: Int,
        totalSteps: Int
    ) -> some View {
        let text = Text(
            verbatim: EnglishNumbers.localized(
                stepLocalizationKey,
                step,
                totalSteps
            )
        )
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)

        text
    }

    private var progressAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.32)
    }

    private var replacementAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    private var indicatorTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.96))
    }
}

/// Keeps the completion control in a stable safe-area slot while the
/// operation runs, then lets it rise into place using native SwiftUI layout.
/// Failure controls remain flow-owned and can expand that slot when needed.
struct WalletDestructiveProgressActionHost<Completion: View, Failure: View>: View {
    let status: WalletDestructiveProgressStatus

    private let completion: Completion
    private let failure: Failure

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        status: WalletDestructiveProgressStatus,
        @ViewBuilder completion: () -> Completion,
        @ViewBuilder failure: () -> Failure
    ) {
        self.status = status
        self.completion = completion()
        self.failure = failure()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            completion
                .opacity(status == .completed ? 1 : 0)
                .offset(y: completionOffset)
                .allowsHitTesting(status == .completed)
                .accessibilityHidden(status != .completed)

            if status == .failed {
                failure
                    .transition(failureTransition)
            }
        }
        .animation(actionAnimation, value: status)
    }

    private var completionOffset: CGFloat {
        guard !reduceMotion, status != .completed else { return 0 }
        return 24
    }

    private var actionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.4, extraBounce: 0)
    }

    private var failureTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .move(edge: .bottom).combined(with: .opacity)
    }
}

extension View {
    /// Uses the shared adaptive sheet surface and app-selected language while
    /// preserving the native presentation chrome and medium detent.
    func walletDestructiveProgressSheetPresentation() -> some View {
        walletSheetPresentation()
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
    }
}
