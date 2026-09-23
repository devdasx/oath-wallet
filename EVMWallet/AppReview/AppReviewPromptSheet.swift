import SwiftUI

struct AppReviewPromptSheet: View {
    private enum Stage {
        case sentiment
        case feedback
        case thanks
    }

    let coordinator: AppReviewPromptCoordinator

    @State private var stage: Stage = .sentiment
    @State private var detent: PresentationDetent = .medium
    @State private var selectedReason: AppReviewFeedbackReason?
    @State private var feedback = ""
    @State private var isSubmitting = false
    @State private var submissionErrorKey: String?

    var body: some View {
        Group {
            switch stage {
            case .sentiment:
                sentimentContent
            case .feedback:
                feedbackContent
            case .thanks:
                thanksContent
            }
        }
        .scrollContentBackground(.hidden)
        .presentationDetents(
            [.medium, .large],
            selection: $detent
        )
        .presentationDragIndicator(.visible)
    }

    private var sentimentContent: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                sentimentUpperContent

                ScrollView {
                    VStack(spacing: 16) {
                        AppReviewAnimationHero()
                        sentimentCopy
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxHeight: .infinity)

            sentimentActions
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .walletActionScreenMargins()
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sentimentUpperContent: some View {
        VStack(spacing: 0) {
            AppReviewAnimationHero()

            Spacer(minLength: 12)

            sentimentCopy

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sentimentCopy: some View {
        VStack(spacing: 8) {
            Text("app.review.sentiment.title")
                .font(WalletTypography.title(.title2))
                .multilineTextAlignment(.center)

            Text("app.review.sentiment.detail")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sentimentActions: some View {
        VStack(spacing: 12) {
            PrimaryWalletButton(
                title: "app.review.sentiment.enjoying"
            ) {
                coordinator.chooseEnjoying()
            }

            SecondaryWalletButton(
                title: "app.review.sentiment.not_enjoying"
            ) {
                coordinator.chooseNotEnjoying()
                stage = .feedback
                detent = .large
            }
        }
    }

    private var feedbackContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("app.review.feedback.title")
                    .font(WalletTypography.title(.title2))
                    .multilineTextAlignment(.center)

                Text("app.review.feedback.detail")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            List {
                Group {
                    Section {
                        Picker(
                            "app.review.feedback.title",
                            selection: $selectedReason
                        ) {
                            ForEach(AppReviewFeedbackReason.allCases) {
                                reason in
                                Text(
                                    LocalizedStringKey(
                                        reason.localizationKey
                                    )
                                )
                                .tag(Optional(reason))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }

                    Section {
                        feedbackEditor
                    }
                }
                .walletListRowSurface()
            }
            .walletListAppearance()
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)

            feedbackActions
                .walletActionScreenMargins()
                .padding(.top, 12)
                .padding(.bottom, 12)
        }
    }

    private var feedbackActions: some View {
        VStack(spacing: 10) {
            if let submissionErrorKey {
                Text(LocalizedStringKey(submissionErrorKey))
                    .font(.footnote)
                    .foregroundStyle(WalletTheme.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PrimaryWalletButton(
                title: "app.review.feedback.submit"
            ) {
                submitFeedback()
            }
            .disabled(selectedReason == nil || isSubmitting)
        }
    }

    private var feedbackEditor: some View {
        ZStack(alignment: .topLeading) {
            if feedback.isEmpty {
                Text("app.review.feedback.comment.placeholder")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $feedback)
                .walletTextInputDirection()
                .walletNonHyphenatingInput()
                .frame(minHeight: 104)
                .scrollContentBackground(.hidden)
                .onChange(of: feedback) { _, newValue in
                    guard newValue.count
                            > AppReviewFeedbackClient
                                .maximumFeedbackLength else {
                        return
                    }
                    feedback = String(
                        newValue.prefix(
                            AppReviewFeedbackClient
                                .maximumFeedbackLength
                        )
                    )
                }
        }
        .overlay(alignment: .bottomTrailing) {
            Text(
                verbatim: "\(feedback.count)/\(AppReviewFeedbackClient.maximumFeedbackLength)"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(8)
            .accessibilityHidden(true)
        }
    }

    private var thanksContent: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) {
                    AppReviewAnimationHero(kind: .thanks)

                    Spacer(minLength: 12)

                    thanksCopy

                    Spacer(minLength: 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ScrollView {
                    VStack(spacing: 16) {
                        AppReviewAnimationHero(kind: .thanks)
                        thanksCopy
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxHeight: .infinity)

            PrimaryWalletButton(
                title: "common.done"
            ) {
                coordinator.finishFeedback()
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .walletActionScreenMargins()
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var thanksCopy: some View {
        Text("app.review.thanks.title")
            .font(WalletTypography.title(.title2))
            .multilineTextAlignment(.center)
    }

    private func submitFeedback() {
        guard let selectedReason, !isSubmitting else { return }
        isSubmitting = true
        submissionErrorKey = nil

        Task { @MainActor in
            do {
                try await coordinator.submitFeedback(
                    reason: selectedReason,
                    feedback: feedback,
                    languageIdentifier:
                        WalletAppLanguage.selectedIdentifier
                )
                isSubmitting = false
                stage = .thanks
                detent = .medium
            } catch let error as AppReviewFeedbackSubmissionError {
                isSubmitting = false
                submissionErrorKey = error.localizationKey
            } catch {
                isSubmitting = false
                submissionErrorKey =
                    AppReviewFeedbackSubmissionError
                        .invalidResponse.localizationKey
            }
        }
    }
}
