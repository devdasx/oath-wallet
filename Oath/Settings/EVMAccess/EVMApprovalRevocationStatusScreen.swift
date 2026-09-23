import SwiftUI
import UIKit

struct EVMApprovalRevocationStatusScreen: View {
    private enum Phase {
        case submitting
        case submitted(EVMApprovalRevocationOutcome)
        case uncertain(SendTransactionReceipt, String)
        case failed(String)
        case insufficientGas(EVMApprovalGasFunding)
    }

    let database: WalletDatabase
    let context: EVMApprovalStatusContext
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .submitting
    @State private var didSubmit = false
    @State private var nativeUnitUSDPrice: Decimal?
    @State private var networkStatus: SendTransactionNetworkStatus = .pending
    @State private var presentedIdentity: EVMApprovalAddressDetail?
    @State private var presentedFunding: EVMApprovalGasFunding?
    @State private var copyFeedback = WalletClipboardCopyFeedback()

    var body: some View {
        List {
            Group {
                if case let .submitted(outcome) = phase {
                    EVMApprovalReceiptSections(
                        approval: context.approval,
                        outcome: outcome,
                        status: networkStatus,
                        nativeUnitUSDPrice: nativeUnitUSDPrice,
                        onInspect: { presentedIdentity = $0 }
                    )
                } else {
                    statusSection
                    if let receipt {
                        transactionSection(receipt)
                    }
                }
                if case .failed = phase {
                    retrySection
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .contentMargins(.top, 12, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .overlay {
            if case let .insufficientGas(funding) = phase {
                ContentUnavailableView {
                    AssetLogoView(
                        source: funding.network.logoSource,
                        size: 56,
                        animatesChanges: false
                    )
                    .accessibilityHidden(true)
                    Text("evm_access.gas.insufficient.title")
                } description: {
                    Text(verbatim: EnglishNumbers.localized(
                        "evm_access.gas.insufficient.body",
                        funding.network.symbol,
                        funding.network.localizedName
                    ))
                } actions: {
                    Button("common.try_again") { dismiss() }
                }
                .background(WalletTheme.groupedBackground)
            }
        }
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            if case .submitted = phase {
                PrimaryWalletButton(
                    title: "common.done", hapticPolicy: .silent, action: onDone
                )
                .accessibilityIdentifier("evm_access.receipt.done")
                .walletActionScreenMargins()
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            if case let .insufficientGas(funding) = phase {
                PrimaryWalletButton(
                    title: LocalizedStringKey(EnglishNumbers.localized(
                        "receive.details.navigation.title", funding.network.symbol
                    )),
                    hapticPolicy: .silent
                ) {
                    presentedFunding = funding
                }
                .accessibilityIdentifier("evm_access.gas.receive")
                .walletActionScreenMargins()
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
        }
        .sheet(item: $presentedFunding) { funding in
            EVMApprovalGasReceiveScreen(funding: funding)
                .walletLocalePresentation()
                .walletSheetPresentation(nativeGlass: false)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $presentedIdentity) { detail in
            EVMApprovalAddressDetailSheet(detail: detail)
                .walletLocalePresentation()
                .walletSheetPresentation()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .walletSheetBackground(nativeGlass: false)
        .navigationTitle("evm_access.status.title")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSubmitting)
        .interactiveDismissDisabled(isSubmitting)
        .task {
            guard !didSubmit else { return }
            didSubmit = true
            await submit()
        }
        .task(id: acceptedReceipt?.networkID) {
            guard let receipt = acceptedReceipt else { return }
            nativeUnitUSDPrice = (try? await database.cachedAssetUSDPrice(
                assetID: AssetIdentityKey.make(networkID: receipt.networkID, contractAddress: nil)
            ))?.price
        }
        .task(id: acceptedReceipt?.transactionHash) {
            guard let receipt = acceptedReceipt else { return }
            await monitor(receipt)
        }
        .onDisappear {
            copyFeedback.reset()
        }
    }

    private var statusSection: some View {
        Section {
            switch phase {
            case .insufficientGas:
                EmptyView()
            case .submitting:
                Text("evm_access.status.submitting")
                    .foregroundStyle(WalletTheme.secondaryLabel)
            case let .submitted(outcome):
                Text("evm_access.status.success")
                    .foregroundStyle(WalletTheme.success)
                if outcome.persistenceWarningCode != nil {
                    Text("evm_access.status.persistence_warning")
                        .font(.footnote)
                        .foregroundStyle(WalletTheme.warning)
                }
            case let .uncertain(_, message):
                Text("evm_access.status.uncertain")
                    .foregroundStyle(WalletTheme.warning)
                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            case let .failed(message):
                Text("evm_access.status.failure")
                    .foregroundStyle(WalletTheme.danger)
                if !message.isEmpty {
                    Text(verbatim: message)
                        .font(.subheadline)
                        .foregroundStyle(WalletTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func transactionSection(
        _ receipt: SendTransactionReceipt
    ) -> some View {
        Section("send.broadcast.transaction_id.title") {
            WalletExactText(receipt.transactionHash, monospaced: true)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: UniHaptic.action {
                copy(receipt.transactionHash)
            }) {
                Text(
                    LocalizedStringKey(
                        copyFeedback.state == .copied
                            ? "common.copied_to_clipboard"
                            : "wallet.transaction.details.copy_transaction_id"
                    )
                )
            }

            if let url = WalletTransactionExplorer.url(
                transactionHash: receipt.transactionHash,
                networkID: receipt.networkID
            ) {
                Link(
                    "settings.tools.broadcast_bitcoin.view_on_explorer",
                    destination: url
                )
            }
        }
    }

    private var retrySection: some View {
        Section {
            Button("common.try_again", action: UniHaptic.action(nil) {
                dismiss()
            })
        }
    }

    private var isSubmitting: Bool {
        if case .submitting = phase { return true }
        return false
    }

    private var receipt: SendTransactionReceipt? {
        switch phase {
        case let .submitted(outcome):
            outcome.receipt
        case let .uncertain(receipt, _):
            receipt
        case .submitting, .failed, .insufficientGas:
            nil
        }
    }

    @MainActor
    private func submit() async {
        do {
            phase = .submitted(
                try await EVMApprovalRevocationService(
                    database: database
                ).submit(
                    approval: context.approval,
                    draft: context.draft,
                    authorization: context.authorization
                )
            )
            UniHaptic.play(.success)
        } catch let error as SendTransactionSubmissionError {
            if error.submissionMayHaveSucceeded,
               let receipt = error.transactionEvidenceReceipt {
                try? await database.markEVMApprovalRevocationSubmitted(
                    approvalID: context.approval.id,
                    transactionHash: receipt.transactionHash,
                    submittedAt: receipt.submittedAt
                )
                phase = .uncertain(receipt, error.localizedMessage)
                UniHaptic.play(.warning)
            } else if EVMApprovalGasFunding.isInsufficientGas(
                error, networkID: context.approval.networkID
            ), let funding = EVMApprovalGasFunding(
                address: context.approval.ownerAddress,
                networkID: context.approval.networkID
            ) {
                phase = .insufficientGas(funding)
                UniHaptic.play(.error)
            } else {
                phase = .failed(error.localizedMessage)
                UniHaptic.play(.error)
            }
        } catch {
            phase = .failed("")
            UniHaptic.play(.error)
        }
    }

    private var acceptedReceipt: SendTransactionReceipt? {
        guard case let .submitted(outcome) = phase else { return nil }
        return outcome.receipt
    }

    @MainActor
    private func monitor(_ receipt: SendTransactionReceipt) async {
        let service = SendTransactionStatusService()
        while !Task.isCancelled {
            do {
                let status = try await service.status(for: receipt)
                try Task.checkCancellation()
                networkStatus = status
                if status.isTerminal { return }
            } catch is CancellationError {
                return
            } catch {
                // Keep the last verified status; a failed read is not confirmation.
            }
            do {
                try await Task.sleep(for: SendTransactionStatusPollingPolicy.interval)
            } catch { return }
        }
    }

    @MainActor
    private func copy(_ transactionHash: String) {
        SendTransactionIdentityClipboard.copy(
            transactionHash,
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
}
