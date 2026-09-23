import SwiftUI

struct OnboardingEntropyInputInfoPopover: View {
    let assessment: SettingsWalletEntropyHealthAssessment

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var preferredHeight: CGFloat = 220
    @ScaledMetric(relativeTo: .body) private var warningPreferredHeight: CGFloat = 340

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            NavigationStack {
                Group {
                    explanation
                        .navigationTitle("wallet.creation.entropy.health.section")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                WalletCloseButton { dismiss() }
                            }
                        }
                }

            }
        } else {
            explanation
                .frame(
                    idealWidth: 320,
                    maxWidth: 360,
                    idealHeight: min(
                        assessment.requiresIntervention
                            ? warningPreferredHeight
                            : preferredHeight,
                        440
                    ),
                    maxHeight: 440
                )
        }
    }

    private var explanation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("wallet.creation.entropy.health.section")
                        .font(WalletTypography.sheetTitle)
                        .accessibilityAddTraits(.isHeader)
                }
                explanationCopy
            }
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var explanationCopy: some View {
        if assessment.requiresIntervention {
            Text(LocalizedStringKey(assessment.informationSummaryKey))
                .bold()
                .foregroundStyle(WalletTheme.danger)
        } else {
            Text(LocalizedStringKey(assessment.informationSummaryKey))
        }
        Text(LocalizedStringKey(assessment.informationGuidanceKey))
    }
}
