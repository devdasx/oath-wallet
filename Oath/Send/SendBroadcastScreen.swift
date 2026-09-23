import Foundation
import SwiftUI

enum SendBroadcastHeroCopy: CaseIterable, Sendable {
    case submitting
    case submitted
    case confirmed
    case warning
    case executionFailed
    case notSent

    var titleKey: String {
        switch self {
        case .submitting: "send.broadcast.submitting.title"
        case .submitted: "send.broadcast.submitted.title"
        case .confirmed: "send.broadcast.confirmed.title"
        case .warning: "send.broadcast.warning.title"
        case .executionFailed: "send.broadcast.execution_failed.title"
        case .notSent: "send.broadcast.failed.title"
        }
    }

    var detailKey: String {
        switch self {
        case .submitting: "send.broadcast.submitting.detail"
        case .submitted: "send.broadcast.submitted.detail"
        case .confirmed: "send.broadcast.confirmed.detail"
        case .warning: "send.broadcast.warning.detail"
        case .executionFailed: "send.broadcast.execution_failed.detail"
        case .notSent: "send.broadcast.failed.detail"
        }
    }
}

struct SendBroadcastScreen: View {
    let operation: SendOperation
    private var database: WalletDatabase { operation.database }
    private var draft: SendDraft { operation.draft }
    private var nativeUnitUSDPrice: Decimal? { operation.nativeUnitUSDPrice }
    let onRetry: () -> Void
    let onDone: () -> Void

    @Environment(\.walletCurrencyContext) private var currencyContext
    @State private var showsNativeAmount = false
    @State private var showsNativeFee = false
    @State private var isNetworkFeeInfoPresented = false
    @State private var cachedAssetUnitUSDPrice: Decimal?
    @State private var cachedNativeUnitUSDPrice: Decimal?
    @State private var estimatedNetworkFeeUSDValue: Decimal?
    @State private var presentedIdentity:
        SendTransactionIdentityDetail?
    @State private var isNoteEditorPresented = false

    var body: some View {
        List {
            Group {
                Section {
                    receiptHero
                }

                Section {
                    receiptRow(
                        labelKey: "wallet.transaction.details.status",
                        value: statusValue
                    )
                    tokenRow
                    identityReceiptRow(
                        labelKey: "send.recipient.section",
                        value: recipientValue,
                        kind: .recipient
                    )
                } header: {
                    Text("wallet.transaction.details.overview.section")
                }

                Section {
                    Group {
                        if isSubmitting {
                            LabeledContent("wallet.transaction.details.amount") {
                                skeletonLine(width: 132, height: 16)
                            }
                        } else {
                            WalletTransactionValue(
                                title: "wallet.transaction.details.amount",
                                nativeValue: nativeAmountValue,
                                localValue: amountValue == nativeAmountValue ? nil : amountValue,
                                isBalanceHidden: false,
                                showsNative: $showsNativeAmount
                            )
                        }
                    }
                    .modifier(SendBroadcastSkeletonModifier(isActive: isSubmitting))
                    networkFeeReceiptRow(value: networkFeeValue)
                    if let transactionHashValue {
                        identityReceiptRow(
                            labelKey: "send.broadcast.transaction_id.title",
                            value: transactionHashValue,
                            kind: .transactionID
                        )
                    }
                } header: {
                    Text("wallet.transaction.details.transfer.section")
                }

                if case .submitted = operation.phase {
                    SendBroadcastNoteSection(
                        note: operation.transactionNote,
                        isPersisting: operation.isPersistingNote,
                        feedbackKey: operation.noteFeedbackKey,
                        feedbackIsSuccess: operation.noteFeedbackIsSuccess,
                        onEdit: { isNoteEditorPresented = true }
                    )
                }

                if !warningMessages.isEmpty {
                    Section {
                        ForEach(warningMessages, id: \.self) { message in
                            Text(verbatim: message)
                                .foregroundStyle(WalletTheme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text("send.broadcast.warning.section")
                    }
                }

                if case let .failed(error) = operation.phase,
                   SendBroadcastReceiptPresentation.showsSubmissionError(
                       networkStatus: operation.networkStatus
                   ) {
                    Section {
                        Text(verbatim: error.localizedFailureMessage(
                            networkID: draft.asset.networkID,
                            isNative: draft.asset.isNative
                        ))
                            .foregroundStyle(WalletTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text("send.broadcast.error.section")
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .contentMargins(.top, 12, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle("send.broadcast.navigation_title")
        .navigationBarTitleDisplayMode(.inline)
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            bottomAction
        }
        .sheet(item: $presentedIdentity) { detail in
            SendTransactionIdentityDetailSheet(detail: detail)
                .walletSheetPresentation()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isNoteEditorPresented) {
            SendNoteEditorScreen(
                initialNote: operation.transactionNote ?? "",
                onSave: operation.persistTransactionNote
            )
            .walletLocalePresentation()
            .presentationDragIndicator(.visible)
            .presentationBackground(WalletTheme.groupedBackground)
        }
        .task {
            await loadTransferAmountPrice()
        }
        .task(id: operation.isSubmitting) {
            guard !operation.isSubmitting else { return }
            await loadNetworkFeePresentation()
        }
    }

    @ViewBuilder
    private var receiptHero: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                AssetLogoView(
                    source: draft.asset.logoSource,
                    size: 52,
                    animatesChanges: false,
                    diagnosticAssetIdentity: draft.asset.id
                )

                WalletLogoStatusBadge(
                    color: statusBadgeColor,
                    systemSymbol: statusBadgeSystemSymbol,
                    size: 20
                )
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                if isSubmitting {
                    skeletonLine(width: 210, height: 20)
                    skeletonLine(width: 150, height: 15)
                } else {
                    Text(heroTitleKey)
                        .font(.headline)
                    Text(verbatim: heroDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .modifier(
            SendBroadcastSkeletonModifier(isActive: isSubmitting)
        )
    }

    @ViewBuilder
    private func receiptRow(
        labelKey: LocalizedStringKey,
        value: String?
    ) -> some View {
        LabeledContent(labelKey) {
            if isSubmitting {
                skeletonLine(width: 132, height: 16)
            } else {
                receiptText(value: value ?? "—")
            }
        }
        .modifier(
            SendBroadcastSkeletonModifier(isActive: isSubmitting)
        )
    }

    @ViewBuilder
    private func networkFeeReceiptRow(value: String?) -> some View {
        LabeledContent {
            if isSubmitting {
                skeletonLine(width: 132, height: 16)
            } else {
                WalletTransactionValue(
                    title: "wallet.transaction.details.network_fee",
                    nativeValue: nativeNetworkFeeValue,
                    localValue: value,
                    isBalanceHidden: false,
                    showsNative: $showsNativeFee,
                    valueOnly: true
                )
            }
        } label: {
            SendBroadcastNetworkFeeLabel(
                showsInformationButton: !isSubmitting,
                isInformationPresented: $isNetworkFeeInfoPresented
            )
        }
        .accessibilityElement(children: .contain)
        .modifier(
            SendBroadcastSkeletonModifier(isActive: isSubmitting)
        )
    }

    @ViewBuilder
    private func identityReceiptRow(
        labelKey: LocalizedStringKey,
        value: String?,
        kind: SendTransactionIdentityDetail.Kind
    ) -> some View {
        Group {
            if isSubmitting {
                LabeledContent(labelKey) {
                    skeletonLine(width: 152, height: 16)
                }
            } else if let value, !value.isEmpty {
                WalletIdentityActionRow(
                    title: labelKey,
                    value: value,
                    displayedValue: SendBroadcastReceiptPresentation.compactIdentity(value),
                    showsDisclosureIndicator: true
                ) {
                    presentedIdentity = SendTransactionIdentityDetail(
                        kind: kind,
                        value: value,
                        networkID: draft.asset.networkID
                    )
                }
            } else {
                LabeledContent(labelKey) {
                    receiptText(value: "—")
                }
            }
        }
        .modifier(
            SendBroadcastSkeletonModifier(isActive: isSubmitting)
        )
    }

    @ViewBuilder
    private var tokenRow: some View {
        LabeledContent("wallet.transaction.details.token") {
            if isSubmitting {
                VStack(alignment: .trailing, spacing: 6) {
                    skeletonLine(width: 148, height: 16)
                    skeletonLine(width: 104, height: 14)
                }
            } else if !SendBroadcastReceiptPresentation
                .showsNetworkVariant(for: draft.asset) {
                HStack(spacing: 7) {
                    AssetLogoView(
                        source: draft.asset.logoSource,
                        size: 22,
                        animatesChanges: false,
                        diagnosticAssetIdentity: draft.asset.id
                    )
                    Text(verbatim: draft.asset.name)
                        .font(.body)
                        .multilineTextAlignment(.trailing)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: draft.asset.name)
                        .font(.body)
                        .multilineTextAlignment(.trailing)
                    HStack(spacing: 5) {
                        Text(
                            "wallet.transaction.details.token.network_prefix"
                        )
                        AssetLogoView(
                            source: draft.asset.networkLogoSource,
                            size: 18,
                            animatesChanges: false,
                            diagnosticAssetIdentity:
                                draft.asset.networkID
                        )
                        Text(verbatim: draft.asset.networkName)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .modifier(
            SendBroadcastSkeletonModifier(isActive: isSubmitting)
        )
    }

    private func skeletonLine(
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(WalletTheme.tertiaryFill)
            .frame(maxWidth: width)
            .frame(height: height)
    }

    private func receiptText(value: String) -> some View {
        Text(verbatim: value)
            .font(.body)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bottomAction: some View {
        PrimaryWalletButton(
            title: operation.canRetry ? "common.try_again" : "common.done",
            hapticPolicy: .silent,
            action: operation.canRetry ? onRetry : onDone
        )
        .walletActionScreenMargins()
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var isSubmitting: Bool {
        if case .submitting = operation.phase {
            return true
        }
        return false
    }

    private var heroTitleKey: LocalizedStringKey {
        LocalizedStringKey(operation.heroCopy.titleKey)
    }

    private var heroDetail: String {
        WalletLocalization.string(operation.heroCopy.detailKey)
    }

    private var statusBadgeColor: Color {
        switch operation.receiptVisualStatus {
        case .submitting:
            WalletTheme.accent
        case .submitted, .confirmed:
            WalletTheme.success
        case .warning:
            WalletTheme.warning
        case .failed:
            WalletTheme.danger
        }
    }

    private var statusBadgeSystemSymbol: String {
        switch operation.receiptVisualStatus {
        case .submitting:
            "clock.fill"
        case .submitted, .confirmed:
            "checkmark"
        case .warning:
            "exclamationmark"
        case .failed:
            "xmark"
        }
    }

    private var statusValue: String? {
        guard !isSubmitting else { return nil }
        if let status = operation.networkStatus, [.notFound, .replaced, .canceled].contains(status) {
            return WalletLocalization.string(status.localizedKey)
        }
        if operation.networkStatus == .confirmed {
            return WalletLocalization.string(
                "wallet.activity.status.confirmed"
            )
        }
        if operation.networkStatus == .failed {
            return WalletLocalization.string(
                "wallet.activity.status.failed"
            )
        }
        return switch operation.phase {
        case .submitting:
            nil
        case .submitted:
            WalletLocalization.string(
                operation.monitoringWarningCode == nil
                    ? "send.broadcast.status.submitted"
                    : "send.broadcast.status.unconfirmed"
            )
        case .failed:
            if case let .failed(error) = operation.phase,
               error.wasExecutedOnNetwork {
                WalletLocalization.string(
                    "wallet.activity.status.failed"
                )
            } else if case let .failed(error) = operation.phase,
                      error.submissionMayHaveSucceeded {
                WalletLocalization.string(
                    "send.broadcast.status.unconfirmed"
                )
            } else {
                WalletLocalization.string(
                    "send.broadcast.status.not_submitted"
                )
            }
        }
    }

    private var warningMessages: [String] {
        var messages: [String] = []
        if let code = operation.localPersistenceWarningCode {
            messages.append(
                EnglishNumbers.localized(
                    "send.broadcast.persistence_warning",
                    code
                )
            )
        }
        if let monitoringWarningCode = operation.monitoringWarningCode {
            messages.append(
                EnglishNumbers.localized(
                    "send.broadcast.monitoring_warning",
                    monitoringWarningCode
                )
            )
        }
        if let statusPersistenceWarningCode = operation.statusPersistenceWarningCode {
            messages.append(
                EnglishNumbers.localized(
                    "send.broadcast.status_persistence_warning",
                    statusPersistenceWarningCode
                )
            )
        }
        return messages
    }

    private var recipientValue: String? {
        isSubmitting ? nil : draft.recipient
    }

    private var nativeAmountValue: String? {
        guard !isSubmitting else { return nil }
        return EnglishNumbers.localized(
            "wallet.format.asset_amount",
            operation.receipt?.amount ?? draft.amount ?? "0",
            draft.asset.symbol
        )
    }

    private var nativeNetworkFeeValue: String? {
        guard !isSubmitting, let receipt = operation.receipt,
              let fee = receipt.networkFee else { return nil }
        return EnglishNumbers.localized(
            "wallet.format.asset_amount", fee, receipt.networkFeeSymbol
        )
    }

    private var amountValue: String? {
        guard !isSubmitting else { return nil }
        return SendAmountPresentation.formatted(
            amount: operation.receipt?.amount ?? draft.amount ?? "0",
            asset: draft.asset,
            currency: currencyContext,
            nativeUnitUSDPrice: nativeUnitUSDPrice,
            cachedAssetUnitUSDPrice: cachedAssetUnitUSDPrice
        )
    }

    private var networkFeeValue: String? {
        guard !isSubmitting else { return nil }
        let actualUSDValue = SendBroadcastReceiptPresentation
            .networkFeeUSDValue(
                nativeFee: operation.receipt?.networkFee,
                nativeUnitUSDPrice: resolvedNativeUnitUSDPrice
            )
        guard let usdValue = actualUSDValue
            ?? estimatedNetworkFeeUSDValue else {
            return nil
        }
        return EnglishNumbers.networkFeeCurrency(
            usdValue,
            using: currencyContext
        )
    }

    private var transactionHashValue: String? {
        switch operation.phase {
        case let .submitted(outcome):
            SendBroadcastReceiptPresentation.visibleTransactionHash(
                outcome.receipt.transactionHash,
                submissionWasAccepted: true,
                submissionMayHaveSucceeded: false
            )
        case let .failed(error):
            SendBroadcastReceiptPresentation.visibleTransactionHash(
                error.transactionEvidenceReceipt?.transactionHash,
                submissionWasAccepted: error.wasExecutedOnNetwork,
                submissionMayHaveSucceeded:
                    error.submissionMayHaveSucceeded
            )
        case .submitting:
            nil
        }
    }

    private var resolvedNativeUnitUSDPrice: Decimal? {
        if let nativeUnitUSDPrice, nativeUnitUSDPrice > 0 {
            return nativeUnitUSDPrice
        }
        if draft.asset.isNative,
           let cachedAssetUnitUSDPrice,
           cachedAssetUnitUSDPrice > 0 {
            return cachedAssetUnitUSDPrice
        }
        if let cachedNativeUnitUSDPrice,
           cachedNativeUnitUSDPrice > 0 {
            return cachedNativeUnitUSDPrice
        }
        return nil
    }

    @MainActor
    private func loadNetworkFeePresentation() async {
        if resolvedNativeUnitUSDPrice == nil {
            let assetID = AssetIdentityKey.make(
                networkID: draft.asset.networkID,
                contractAddress: nil
            )
            cachedNativeUnitUSDPrice = (try? await database
                .cachedAssetUSDPrice(
                    assetID: assetID
                ))?.price
        }
        guard let unitPrice = resolvedNativeUnitUSDPrice else {
            return
        }
        do {
            let fee = try SendSubmissionNetworkFee.resolve(draft: draft)
            let estimate = try await SendNetworkFeeEstimator(
                database: database
            ).estimate(
                draft: draft,
                fee: fee
            )
            guard !Task.isCancelled else { return }
            estimatedNetworkFeeUSDValue = estimate.usdValue(
                unitUSDPrice: unitPrice
            )
        } catch {
            // Submission owns actionable errors. The fee row falls back to
            // the receipt or an unavailable value when no estimate exists.
        }
    }

    @MainActor
    private func loadTransferAmountPrice() async {
        guard SendAmountPresentation.unitUSDPrice(
            for: draft.asset,
            nativeUnitUSDPrice: nativeUnitUSDPrice,
            cachedAssetUnitUSDPrice: cachedAssetUnitUSDPrice
        ) == nil else {
            return
        }
        let assetID = AssetIdentityKey.canonical(draft.asset.id)
        let cachedPrice = (try? await database.cachedAssetUSDPrice(
            assetID: assetID
        ))?.price
        guard !Task.isCancelled else { return }
        cachedAssetUnitUSDPrice = cachedPrice
    }


}
