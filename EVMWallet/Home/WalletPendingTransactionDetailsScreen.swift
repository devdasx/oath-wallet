import GRDB
import SwiftUI
import UIKit

struct WalletPendingTransactionDetailsScreen: View {
    let database: WalletDatabase
    @State private var displayedTransaction: WalletTransaction
    @State private var transactionReadError: String?
    private var transaction: WalletTransaction { displayedTransaction }
    let isBalanceHidden: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.walletCurrencyContext) private var currencyContext
    @Environment(\.walletTransactionRepeatAction)
    private var repeatAction
    @State private var showsNativeAmount = false
    @State private var showsNativeFee = false
    @State private var noteDraft: String
    @State private var persistedNote: String?
    @State private var noteFeedback: NoteFeedback?
    @State private var isPersistingNote = false
    @State private var noteEditRevision = 0
    @State private var noteMutationGeneration = 0
    @State private var repeatFailure: WalletTransactionRepeatFailure?
    @State private var isRepeatingTransaction = false
    @State private var copyFeedback = WalletClipboardCopyFeedback()
    @State private var presentedIdentity:
        WalletPendingTransactionIdentityDetail?
    @State private var displayedFromAddress: String?
    @State private var displayedToAddress: String?

    init(
        transaction: WalletTransaction,
        database: WalletDatabase,
        isBalanceHidden: Bool
    ) {
        self.database = database
        _displayedTransaction = State(initialValue: transaction)
        self.isBalanceHidden = isBalanceHidden
        let initialNote = WalletTransactionNote.normalized(
            transaction.metadata.note
        )
        _noteDraft = State(initialValue: initialNote ?? "")
        _persistedNote = State(initialValue: initialNote)
        _displayedFromAddress = State(
            initialValue: transaction.metadata.fromAddress
        )
        _displayedToAddress = State(
            initialValue: transaction.metadata.toAddress
        )
    }

    var body: some View {
        List {
            Group {
                Section {
                    summary
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 24, trailing: 16))
                        .listRowSeparator(.hidden)
                }

                Section("wallet.transaction.details.overview.section") {
                    detailRow(
                        label: Text("wallet.transaction.details.status"),
                        value: WalletLocalization.string(
                            transaction.status.localizedKey
                        ),
                        valueColor: statusColor
                    )

                    if let date = transaction.metadata.date {
                        detailRow(
                            label: Text("wallet.transaction.details.date"),
                            value: EnglishNumbers.transactionDateTime(date)
                        )
                    }

                    if let network = network {
                        LabeledContent {
                            HStack(spacing: 8) {
                                Text(network.localizedName)
                                AssetLogoView(
                                    source: network.logoSource,
                                    size: 24
                                )
                            }
                        } label: {
                            Text("wallet.transaction.details.network")
                        }
                    }

                    ForEach(
                        transaction.kind.pendingActivityDetailsAddressOrder,
                        id: \.self
                    ) { kind in
                        overviewAddressRow(kind)
                    }
                }

                Section("wallet.transaction.details.transfer.section") {
                    WalletTransactionValue(
                        title: "wallet.transaction.details.amount",
                        nativeValue: formattedAssetAmount,
                        localValue: transaction.fiatValue.map {
                            EnglishNumbers.currency($0, using: currencyContext)
                        },
                        isBalanceHidden: isBalanceHidden,
                        showsNative: $showsNativeAmount,
                        valueColor: transaction.activityAmountColor
                    )

                    if transaction.isTokenTransfer {
                        assetDetailRow
                    }

                    longDetailRow(
                        label: "wallet.transaction.details.contract",
                        value: nonZeroContractAddress
                    )

                    if transaction.metadata.networkFee != nil
                        || transaction.metadata.networkFeeFiatValue != nil {
                        WalletTransactionValue(
                            title: "wallet.transaction.details.network_fee",
                            nativeValue: formattedNativeFee,
                            localValue: transaction.metadata.networkFeeFiatValue.map {
                                EnglishNumbers.networkFeeCurrency($0, using: currencyContext)
                            },
                            isBalanceHidden: isBalanceHidden,
                            showsNative: $showsNativeFee,
                            valueColor: WalletTheme.primaryLabel
                        )
                    }
                }

                Section {
                    TextField(
                        "wallet.transaction.details.notes.placeholder",
                        text: noteBinding
                    )
                    .walletTextInputDirection()
                    .textInputAutocapitalization(.sentences)
                    .walletTextInputSubmitAction(
                        identifier: "wallet.transaction.details.note",
                        returnKeyType: .done,
                        confirmsFromKeyboardAccessory: true
                    ) {
                        if hasUnsavedNoteChanges { persistNote(normalizedDraftNote) }
                    }
                    .disabled(isPersistingNote)

                    if persistedNote != nil {
                        Button(
                            "wallet.transaction.details.notes.remove",
                            role: .destructive
                        , action: UniHaptic.action {
                            persistNote(nil)
                        })
                        .disabled(isPersistingNote)
                    }
                } header: {
                    Text("wallet.transaction.details.notes.section")
                } footer: {
                    if let noteFeedback {
                        Text(noteFeedback.messageKey)
                            .foregroundStyle(noteFeedback.color)
                    } else {
                        Text("wallet.transaction.details.notes.footer")
                    }
                }

                if hasBlockchainDetails {
                    Section {
                        integerDetailRow(
                            label: "wallet.transaction.details.log_index",
                            value: transaction.metadata.logIndex.map(Int64.init)
                        )
                        identityDetailRow(
                            label: "wallet.activity.status.replaced",
                            value: transaction.replacementTransactionHash,
                            kind: .transactionHash
                        )
                        identityDetailRow(
                            label: "wallet.transaction.details.hash",
                            value: transaction.metadata.transactionHash,
                            kind: .transactionHash
                        )
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle("wallet.transaction.details.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasTransactionOptions {
                ToolbarItem(placement: .topBarTrailing) {
                    transactionOptionsMenu.walletTransferAction()
                }
            }
        }
        .alert(
            repeatFailure?.localizedTitle ?? "",
            isPresented: repeatFailureIsPresented
        ) {
            Button("common.ok", role: .cancel, action: UniHaptic.action {
                repeatFailure = nil
            })
        } message: {
            Text(
                verbatim: repeatFailure?.localizedMessage ?? ""
            )
        }
        .task(id: transaction.id) {
            await observeTransaction()
        }
        .task(id: transaction.id) {
            await loadLatestNote()
        }
        .task(id: transaction.id) {
            await resolveMissingBitcoinFamilyIdentity()
        }
        .onDisappear {
            copyFeedback.reset()
        }
        .sheet(item: $presentedIdentity) { detail in
            WalletPendingTransactionIdentityDetailSheet(detail: detail)
                .walletSheetPresentation()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var transactionOptionsMenu: some View {
        Menu {
            if WalletTransactionRepeatPreparation.isEligible(transaction) {
                Button(action: UniHaptic.action(nil) {
                    repeatTransaction()
                }) {
                    Label {
                        Text(
                            verbatim: WalletLocalization.string(
                                "wallet.transaction.details.repeat.action"
                            )
                        )
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRepeatingTransaction)
            }
            if WalletTransactionRepeatPreparation.isEligible(transaction),
               explorerURL != nil {
                Divider()
            }
            if let explorerURL {
                Link(destination: explorerURL) {
                    Label(
                        "wallet.transaction.details.explorer.open",
                        systemImage: "safari"
                    )
                }
            }
            if transactionIDCopyPayload != nil {
                Button(action: UniHaptic.action {
                    copyTransactionID()
                }) {
                    Label {
                        Text(
                            LocalizedStringKey(
                                copyFeedback.localizationKey
                            )
                        )
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(Text("send.transaction_options.title"))
    }

    private var summary: some View {
        VStack(spacing: 12) {
            AssetLogoView(
                source: transaction.assetLogoSource,
                size: 64
            )

            Text(transaction.activityTitle)
                .font(
                    .title2.weight(
                        WalletTypography.contentTitleWeight
                    )
                )
                .multilineTextAlignment(.center)

            WalletPrivacyReplacement(isHidden: isBalanceHidden) {
                VStack(spacing: 4) {
                    Text(formattedAssetAmount)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(transaction.activityAmountColor)

                    if let fiatValue = transaction.fiatValue {
                        Text(
                            EnglishNumbers.currency(
                                fiatValue,
                                using: currencyContext
                            )
                        )
                        .font(.subheadline)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func detailRow(
        label: Text,
        value: String,
        valueColor: Color = WalletTheme.secondaryLabel,
        isSensitiveValue: Bool = false
    ) -> some View {
        LabeledContent {
            WalletPrivacyReplacement(
                isHidden: isSensitiveValue && isBalanceHidden,
                alignment: .trailing
            ) {
                Text(verbatim: value)
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.trailing)
            }
        } label: {
            label
        }
        .walletPrivacySensitive(isSensitiveValue)
    }

    private var assetDetailRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                AssetLogoView(
                    source: transaction.assetLogoSource,
                    size: 24,
                    animatesChanges: false
                )
                Text(verbatim: assetDisplayName)
                    .multilineTextAlignment(.trailing)
            }
        } label: {
            Text("wallet.transaction.details.token")
        }
    }

    @ViewBuilder
    private func overviewAddressRow(
        _ kind: WalletPendingTransactionIdentityDetail.Kind
    ) -> some View {
        switch kind {
        case .fromAddress:
            identityDetailRow(
                label: "wallet.transaction.details.from",
                value: displayedTransactionAddress(displayedFromAddress),
                kind: kind
            )
        case .toAddress:
            identityDetailRow(
                label: "wallet.transaction.details.to",
                value: displayedTransactionAddress(displayedToAddress),
                kind: kind
            )
        case .transactionHash:
            EmptyView()
        }
    }

    @ViewBuilder
    private func identityDetailRow(
        label: LocalizedStringKey,
        value: String?,
        kind: WalletPendingTransactionIdentityDetail.Kind
    ) -> some View {
        if let value, !value.isEmpty {
            WalletIdentityActionRow(
                title: label,
                value: value,
                displayedValue: SendBroadcastReceiptPresentation.compactIdentity(value),
                showsDisclosureIndicator: true,
                valueColor: WalletTheme.secondaryLabel
            ) {
                presentedIdentity = WalletPendingTransactionIdentityDetail(
                    kind: kind,
                    value: value,
                    networkID: transaction.metadata.blockchainIdentifier
                )
            }
        }
    }

    @ViewBuilder
    private func integerDetailRow(
        label: LocalizedStringKey,
        value: Int64?
    ) -> some View {
        if let value {
            detailRow(label: Text(label), value: EnglishNumbers.integer(value))
        }
    }

    @ViewBuilder
    private func longDetailRow(
        label: LocalizedStringKey,
        value: String?
    ) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.footnote)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var network: ReceiveNetwork? {
        transaction.metadata.blockchainIdentifier.flatMap {
            ReceiveNetworkCatalog.catalogNetwork(for: $0)
        }
    }

    private var explorerURL: URL? {
        WalletTransactionExplorer.url(
            transactionHash: transaction.metadata.transactionHash,
            networkID: transaction.metadata.blockchainIdentifier
        )
    }

    private var transactionIDCopyPayload: String? {
        WalletTransactionExplorer.copyPayload(
            transactionHash: transaction.metadata.transactionHash,
            networkID: transaction.metadata.blockchainIdentifier
        )
    }

    private var hasTransactionOptions: Bool {
        WalletTransactionRepeatPreparation.isEligible(transaction)
            || explorerURL != nil
    }

    private var repeatFailureIsPresented: Binding<Bool> {
        Binding(
            get: { repeatFailure != nil },
            set: { isPresented in
                if !isPresented {
                    repeatFailure = nil
                }
            }
        )
    }

    private func repeatTransaction() {
        guard !isRepeatingTransaction else { return }
        isRepeatingTransaction = true
        Task { @MainActor in
            defer { isRepeatingTransaction = false }
            let repeatCandidate = transaction
                .fillingMissingBitcoinFamilyIdentity(
                    BitcoinFamilyTransactionIdentity(
                        fromAddress: displayedFromAddress,
                        toAddress: displayedToAddress
                    )
                )
            if let failure = await repeatAction.perform(repeatCandidate) {
                repeatFailure = failure
                UniHaptic.play(
                    failure == .insufficientBalance
                        ? .warning : .error
                )
            }
        }
    }

    @MainActor
    private func copyTransactionID() {
        guard let transactionIDCopyPayload else { return }
        SendTransactionIdentityClipboard.copy(
            transactionIDCopyPayload,
            to: UIPasteboard.general
        )
        copyFeedback.markCopied()
        UniHaptic.play(.successQuiet)
        UIAccessibility.post(
            notification: .announcement,
            argument: WalletLocalization.string(
                copyFeedback.localizationKey
            )
        )
    }

    private var nonZeroContractAddress: String? {
        guard let address = transaction.metadata.contractAddress else {
            return nil
        }
        let zeroAddress = "0x0000000000000000000000000000000000000000"
        return address.caseInsensitiveCompare(zeroAddress) == .orderedSame
            ? nil
            : address
    }

    private func displayedTransactionAddress(
        _ address: String?
    ) -> String? {
        guard
            let address,
            network?.blockchain == .ton
        else {
            return address
        }
        return TONAddress.mainnetDisplayAddress(from: address) ?? address
    }

    @MainActor
    private func resolveMissingBitcoinFamilyIdentity() async {
        guard displayedFromAddress == nil || displayedToAddress == nil,
              let identity = try? await BitcoinFamilyTransactionIdentityResolver
                .shared.resolveAndPersist(transactionID: transaction.id) else {
            return
        }
        displayedFromAddress = identity.fromAddress ?? displayedFromAddress
        displayedToAddress = identity.toAddress ?? displayedToAddress
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { noteDraft },
            set: { nextValue in
                guard WalletTransactionNote.acceptsEditableInput(
                    nextValue
                ) else {
                    return
                }
                noteDraft = nextValue
                noteEditRevision += 1
                noteFeedback = nil
            }
        )
    }

    private var normalizedDraftNote: String? {
        WalletTransactionNote.normalized(noteDraft)
    }

    private var hasUnsavedNoteChanges: Bool {
        normalizedDraftNote != persistedNote
    }

    @MainActor
    private func observeTransaction() async {
        do {
            for try await update in database.pendingActivityTransaction(id: transaction.id) {
                guard !Task.isCancelled else { return }
                if let update { displayedTransaction = update }
                transactionReadError = nil
            }
        } catch is CancellationError {
            return
        } catch {
            // Retain the last known receipt; a read failure is not a failed transfer or a note failure.
            transactionReadError = SendTransactionSubmissionError.sanitizedErrorType(error)
        }
    }

    @MainActor
    private func loadLatestNote() async {
        let startingEditRevision = noteEditRevision
        let startingMutationGeneration = noteMutationGeneration

        do {
            let storedNote = WalletTransactionNote.normalized(
                try await WalletDataStore.shared.transactionNote(
                    transactionID: transaction.id
                )
            )
            guard startingMutationGeneration == noteMutationGeneration else {
                return
            }
            persistedNote = storedNote
            if startingEditRevision == noteEditRevision {
                noteDraft = storedNote ?? ""
            }
        } catch {
            guard startingMutationGeneration == noteMutationGeneration else {
                return
            }
            noteFeedback = .failure(
                WalletTransactionNoteFailure.messageKey(for: error)
            )
        }
    }

    private func persistNote(_ note: String?) {
        guard !isPersistingNote else {
            return
        }

        let intendedNote = WalletTransactionNote.normalized(note)
        isPersistingNote = true
        noteFeedback = nil
        noteMutationGeneration += 1
        let mutationGeneration = noteMutationGeneration

        Task { @MainActor in
            do {
                try await WalletDataStore.shared.setTransactionNote(
                    transactionID: transaction.id,
                    note: intendedNote
                )
                guard mutationGeneration == noteMutationGeneration else {
                    return
                }
                persistedNote = intendedNote
                noteDraft = intendedNote ?? ""
                noteEditRevision += 1
                noteFeedback = .success
                UniHaptic.play(.successQuiet)
            } catch {
                guard mutationGeneration == noteMutationGeneration else {
                    return
                }
                noteFeedback = .failure(
                    WalletTransactionNoteFailure.messageKey(for: error)
                )
                UniHaptic.play(.error)
            }

            if mutationGeneration == noteMutationGeneration {
                isPersistingNote = false
            }
        }
    }

    private var hasBlockchainDetails: Bool {
        transaction.metadata.logIndex != nil
            || !(transaction.metadata.transactionHash?.isEmpty ?? true)
    }

    private var formattedNativeFee: String? {
        guard let fee = transaction.metadata.networkFee,
              let symbol = transaction.metadata.networkFeeSymbol else { return nil }
        return EnglishNumbers.localized(
            "wallet.format.asset_amount",
            EnglishNumbers.decimal(fee, maximumFractionDigits: 38), symbol
        )
    }

    private var formattedAssetAmount: String {
        EnglishNumbers.localized(
            "wallet.format.asset_amount",
            transaction.displayAssetAmountText,
            transaction.assetSymbol
        )
    }

    private var assetDisplayName: String {
        if let tokenName = transaction.metadata.tokenName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !tokenName.isEmpty {
            return tokenName
        }
        if let network,
           network.symbol.caseInsensitiveCompare(
               transaction.assetSymbol
           ) == .orderedSame {
            return network.localizedName
        }
        return transaction.assetSymbol
    }

    private var statusColor: Color {
        switch transaction.status {
        case .confirmed:
            WalletTheme.success
        case .pending:
            WalletTheme.warning
        case .notFound:
            WalletTheme.warning
        case .failed:
            WalletTheme.danger
        case .canceled, .replaced:
            .secondary
        }
    }
}

private enum NoteFeedback: Equatable {
    case success
    case failure(String)

    var messageKey: LocalizedStringKey {
        switch self {
        case .success:
            "wallet.transaction.details.notes.saved"
        case let .failure(messageKey):
            LocalizedStringKey(messageKey)
        }
    }

    var color: Color {
        switch self {
        case .success:
            WalletTheme.success
        case .failure:
            WalletTheme.danger
        }
    }
}
