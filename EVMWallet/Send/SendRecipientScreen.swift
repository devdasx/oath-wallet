import SwiftUI
import UIKit

struct SendRecipientScreen: View {
    let database: WalletDatabase
    let feePreferences: SendNetworkFeePreferenceRepository
    let isBalanceHidden: Bool
    let onContinue: (SendDraft) -> Void

    @State private var model: SendRecipientEntryModel
    @State private var history = SendRecipientHistoryModel()
    @State private var destination: Destination?
    @State private var hasLoadedFeePolicy = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case recipient, networkMemo }
    private enum Destination: String, Hashable, Identifiable {
        case recipientScanner
        var id: String { rawValue }
    }
    private enum RecipientActionMetrics {
        static let horizontalLabelPadding: CGFloat = 8
        static let verticalLabelPadding: CGFloat = 3
    }

    init(
        database: WalletDatabase,
        feePreferences: SendNetworkFeePreferenceRepository? = nil,
        draft: SendDraft,
        initialValidationFailure: SendDraftValidationFailure? = nil,
        isBalanceHidden: Bool = false,
        onContinue: @escaping (SendDraft) -> Void
    ) {
        self.database = database
        self.feePreferences = feePreferences
            ?? SendNetworkFeePreferenceRepository(database: database)
        self.isBalanceHidden = isBalanceHidden
        self.onContinue = onContinue
        _model = State(initialValue: SendRecipientEntryModel(
            draft: draft, initialValidationFailure: initialValidationFailure
        ))
    }

    var body: some View {
        List {
            Group {
                selectedAssetSection
                recipientSection

                if model.isXRP || model.isStellar {
                    Section {
                        TextField(
                            model.isXRP ? "send.xrp.destination_tag.placeholder" : "send.stellar.memo.placeholder",
                            text: Binding(get: { model.networkMemo }, set: { model.setMemo($0) })
                        )
                        .walletTextInputDirection()
                        .keyboardType(model.isXRP ? .asciiCapableNumberPad : .default)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .networkMemo)
                        .accessibilityIdentifier("sendRecipientMemo")
                    } header: {
                        Text(model.isXRP ? "send.xrp.destination_tag.title" : "send.stellar.memo.title")
                    } footer: {
                        if model.displayedMemoIssue {
                            Text(model.isXRP ? "send.xrp.destination_tag.error" : "send.stellar.memo.error")
                                .foregroundStyle(WalletTheme.danger)
                        } else {
                            Text(model.isXRP ? "send.xrp.destination_tag.footer" : "send.stellar.memo.footer")
                        }
                    }
                }

                recentTransfers
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .contentMargins(.top, 12, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle("send.recipient_details.title")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .walletKeyboardUsesScreenAction()
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            PrimaryWalletButton(title: "common.continue", hapticPolicy: .silent, action: continueToAmount)
                .disabled(!model.canContinue)
                .accessibilityIdentifier("sendRecipientContinue")
                .walletActionScreenMargins()
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .task {
            model.scheduleNameResolution()
        }
        .task {
            await history.observe(database: database, asset: model.draft.asset)
        }
        .task(id: model.draft.asset.networkID) {
            guard !hasLoadedFeePolicy else { return }
            hasLoadedFeePolicy = true
            if let policy = try? await feePreferences.policy(
                for: model.draft.asset.networkID
            ) {
                model.feePolicy = policy
            }
        }
        .onDisappear { model.nameResolution.cancel() }
        .sheet(item: $destination) { route in
            NavigationStack {
                Group {
                    switch route {
                    case .recipientScanner:
                        SendRecipientScannerScreen(asset: model.draft.asset) { recipient in
                            model.applyScannedRecipient(recipient)
                            destination = nil
                        }
                    }
                }

            }
            .walletScannerPresentation()
        }
    }

    private var selectedAssetSection: some View {
        Section {
            UnifiedAssetSelectionRow(
                name: model.draft.asset.name,
                symbol: model.draft.asset.symbol,
                logoSource: model.draft.asset.logoSource,
                networkLogoSource: model.draft.asset.networkLogoSource,
                familyLogoSource: model.draft.asset.familyLogoSource,
                balance: model.draft.asset.balance,
                fiatValue: model.draft.asset.fiatValue,
                isBalanceHidden: isBalanceHidden,
                logoDiagnosticIdentity: model.draft.asset.id
            )
            .accessibilityIdentifier("sendRecipientSelectedAsset")
        } header: {
            Text("send.selected_asset.section")
        }
    }

    @ViewBuilder
    private var recipientSection: some View {
        if hasRecipientFeedback {
            Section {
                recipientInput
                    .listRowSeparator(.hidden)
            } footer: {
                recipientFeedback
            }
        } else {
            Section {
                recipientInput
                    .listRowSeparator(.hidden)
            }
        }
    }

    private var recipientInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                "send.recipient.section",
                text: Binding(get: { model.recipient }, set: { model.setRecipient($0) }),
                prompt: Text(LocalizedStringKey(
                    SendRecipientPlaceholder.key(for: model.draft.asset.networkID)
                )),
                axis: .vertical
            )
            .lineLimit(3...5)
            .textFieldStyle(.plain)
            .walletTextInputDirection()
            .walletNonHyphenatingInput()
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.none)
            .focused($focusedField, equals: .recipient)
            .accessibilityIdentifier("sendRecipientInput")

            recipientActions
        }
    }

    private var recipientActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { recipientActionButtons }
            VStack(alignment: .trailing, spacing: 12) { recipientActionButtons }
        }
        .font(.subheadline.weight(.semibold))
        .walletAdaptiveGlassButtonStyle(.accent)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var recipientActionButtons: some View {
        Button(action: UniHaptic.action(pasteRecipient)) {
            recipientActionLabel("common.paste")
        }
        .accessibilityIdentifier("sendRecipientPaste")
        Button(action: UniHaptic.action(nil) {
            focusedField = nil
            destination = .recipientScanner
        }) {
            recipientActionLabel("common.scan")
        }
        .accessibilityIdentifier("sendRecipientScan")
    }

    private func recipientActionLabel(_ titleKey: LocalizedStringKey) -> some View {
        Text(titleKey)
            .padding(.horizontal, RecipientActionMetrics.horizontalLabelPadding)
            .padding(.vertical, RecipientActionMetrics.verticalLabelPadding)
    }

    @ViewBuilder
    private var recentTransfers: some View {
        let recipients = history.recentRecipients
        let colors = SendRecentRecipientAppearance.colors(for: recipients)
        if !recipients.isEmpty {
            Section {
                ForEach(recipients) { recipient in
                    Button(action: UniHaptic.action {
                        model.applyRecentRecipient(recipient)
                        focusedField = nil
                        UniHaptic.play(.selection)
                    }) {
                        SendRecentRecipientRow(
                            recipient: recipient, color: colors[recipient.id] ?? .blue
                        )
                    }
                    .buttonStyle(.automatic)
                    .accessibilityIdentifier("sendRecentRecipient")
                }
            } header: {
                Text(verbatim: WalletLocalization.string("send.recipient.history.title"))
                    .accessibilityIdentifier("sendRecipientHistoryTitle")
            }
        }
    }

    private var recipientFeedback: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isResolvingName {
                Text("send.recipient.resolving")
            } else if let error = model.actionError {
                Text(verbatim: error).foregroundStyle(WalletTheme.danger)
            } else if let issue = model.displayedRecipientIssue {
                Text(verbatim: issue.localizedMessage)
                    .foregroundStyle(WalletTheme.danger)
                    .accessibilityIdentifier("sendRecipientValidationError")
            }
            if model.nameResolution.canRetry(
                sourceRecipient: model.recipient, networkID: model.draft.asset.networkID
            ) {
                Button("common.retry", action: UniHaptic.action(model.nameResolution.retry))
            }
            if model.actionError == nil, model.displayedRecipientIssue == nil, !model.hasInvalidMemo,
               let assessment = history.assessment(
                   address: model.resolvedRecipient, networkID: model.draft.asset.networkID,
                   memo: model.requestMemo
               ) {
                Text(verbatim: assessment.message)
                    .foregroundStyle(assessment == .newRecipient ? WalletTheme.warning : WalletTheme.secondaryLabel)
                    .accessibilityIdentifier("sendRecipientHistoryAssessment")
            }
        }
    }

    private var hasRecipientFeedback: Bool {
        if model.isResolvingName
            || model.actionError != nil
            || model.displayedRecipientIssue != nil
            || model.nameResolution.canRetry(
                sourceRecipient: model.recipient,
                networkID: model.draft.asset.networkID
            ) {
            return true
        }
        guard model.actionError == nil, !model.hasInvalidMemo else { return false }
        return history.assessment(
            address: model.resolvedRecipient,
            networkID: model.draft.asset.networkID,
            memo: model.requestMemo
        ) != nil
    }

    private func pasteRecipient() {
        guard let payload = UIPasteboard.general.string,
              !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UniHaptic.play(model.paste(payload) ? .selection : .error)
    }

    private func continueToAmount() {
        guard let draft = model.continueDraft() else {
            UniHaptic.play(.error)
            return
        }
        focusedField = nil
        onContinue(draft)
    }
}
