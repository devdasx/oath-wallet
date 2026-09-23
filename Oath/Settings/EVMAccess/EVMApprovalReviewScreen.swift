import SwiftUI

struct EVMApprovalStatusContext: Hashable, Identifiable {
    let id = UUID()
    let approval: EVMOnChainApproval
    let draft: SendDraft
    let authorization: SendTransactionAuthorization
}

struct EVMApprovalReviewScreen: View {
    private enum PreparationState {
        case loading
        case ready(SendDraft)
        case failed(String)
    }

    let database: WalletDatabase
    let approval: EVMOnChainApproval

    @Environment(\.dismiss) private var dismiss

    @State private var preparationState: PreparationState = .loading
    @State private var authorizationError: String?
    @State private var passcodeRequest: EVMApprovalPasscodeRequest?
    @State private var statusContext: EVMApprovalStatusContext?
    @State private var pendingStatusContext: EVMApprovalStatusContext?
    @State private var didPrepare = false
    @State private var isAuthorizing = false
    @State private var presentedAddress: EVMApprovalAddressDetail?

    @ScaledMetric(relativeTo: .subheadline) private var networkLogoSize = 18

    var body: some View {
        List {
            Group {
                assetSection
                permissionSection
                addressSection
                feeSection
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .walletSheetBackground(nativeGlass: false)
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            PrimaryWalletButton(
                title: "evm_access.permission.revoke",
                action: authorizeRevocation
            )
            .disabled(readyDraft == nil || isAuthorizing)
            .accessibilityIdentifier("evm_access.review.revoke")
            .walletActionScreenMargins()
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .sheet(item: $presentedAddress) { detail in
            EVMApprovalAddressDetailSheet(detail: detail)
                .walletLocalePresentation()
                .walletSheetPresentation()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .navigationTitle("evm_access.review.title")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $statusContext) { context in
            EVMApprovalRevocationStatusScreen(
                database: database,
                context: context,
                onDone: { dismiss() }
            )
        }
        .fullScreenCover(item: $passcodeRequest, onDismiss: {
            statusContext = pendingStatusContext
            pendingStatusContext = nil
        }) { request in
            WalletAuthenticationFullScreenContainer(
                title: "security.authentication.navigation_title"
            ) {
                SendTransactionAuthorizationScreen(
                    database: database,
                    draft: request.draft,
                    initialErrorKey: request.initialErrorKey
                ) { authorization in
                    passcodeRequest = nil
                    pendingStatusContext = EVMApprovalStatusContext(
                        approval: approval,
                        draft: request.draft,
                        authorization: authorization
                    )
                }
            }
        }
        .alert(
            "evm_access.review.authorization_error.title",
            isPresented: authorizationErrorBinding
        ) {
            Button("common.ok", role: .cancel, action: UniHaptic.action {
                authorizationError = nil
            })
        } message: {
            Text(verbatim: authorizationError ?? "")
        }
        .task {
            guard !didPrepare else { return }
            didPrepare = true
            await prepareDraft()
        }
    }

    private var assetSection: some View {
        Section {
            HStack(spacing: 12) {
                AssetLogoView(
                    source: approval.logoSource,
                    size: 44,
                    animatesChanges: false,
                    diagnosticAssetIdentity:
                        "\(approval.networkID):\(approval.contractAddress)"
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: approval.displayName)
                        .font(.headline)
                        .foregroundStyle(WalletTheme.primaryLabel)
                    HStack(spacing: 6) {
                        AssetLogoView(
                            source: ReceiveNetworkCatalog.network(for: approval.networkID)?.logoSource ?? .unavailable,
                            size: networkLogoSize,
                            animatesChanges: false
                        )
                        .accessibilityHidden(true)
                        Text(verbatim: approval.networkName)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                }
            }
        }
    }

    private var permissionSection: some View {
        Section {
            LabeledContent("evm_access.permission.type") {
                Text(LocalizedStringKey(approval.kindLocalizationKey))
            }
            if let valueText = approval.valueText {
                LabeledContent("evm_access.permission.amount") {
                    Text(verbatim: valueText)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("evm_access.permissions.title")
        }
    }

    private var addressSection: some View {
        Section {
            addressRow(kind: .spender, address: approval.spenderAddress)
            addressRow(kind: .contract, address: approval.contractAddress)
        } footer: {
            Text("evm_access.review.footer")
        }
    }

    private var feeSection: some View {
        Section {
            switch preparationState {
            case .loading:
                Text("evm_access.review.preparing")
                    .foregroundStyle(WalletTheme.secondaryLabel)
            case .ready:
                LabeledContent(
                    "wallet.transaction.details.network_fee"
                ) {
                    Text("send.network_fee.preset.standard.title")
                }
                Text("evm_access.review.fee_note")
                    .font(.footnote)
                    .foregroundStyle(WalletTheme.secondaryLabel)
            case let .failed(message):
                Text(verbatim: message)
                    .foregroundStyle(WalletTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("common.try_again", action: UniHaptic.action {
                    Task { await prepareDraft() }
                })
            }
        } header: {
            Text("wallet.transaction.details.network_fee")
        }
    }

    private func addressRow(
        kind: EVMApprovalAddressDetail.Kind,
        address: String
    ) -> some View {
        WalletIdentityActionRow(
            title: kind.titleKey,
            value: address,
            displayedValue: EVMApprovalPresentation.shortAddress(address)
        ) {
            presentedAddress = EVMApprovalAddressDetail(kind: kind, value: address)
        }
        .accessibilityIdentifier("evm_access.review.\(kind.rawValue)")
    }

    private var readyDraft: SendDraft? {
        guard case let .ready(draft) = preparationState else {
            return nil
        }
        return draft
    }

    private var authorizationErrorBinding: Binding<Bool> {
        Binding(
            get: { authorizationError != nil },
            set: { if !$0 { authorizationError = nil } }
        )
    }

    @MainActor
    private func prepareDraft() async {
        preparationState = .loading
        do {
            preparationState = .ready(
                try await EVMApprovalDraftFactory.preparedDraft(
                    approval: approval, database: database
                )
            )
        } catch {
            preparationState = .failed(localizedMessage(error))
        }
    }

    private func authorizeRevocation() {
        guard let draft = readyDraft, !isAuthorizing, passcodeRequest == nil else { return }
        isAuthorizing = true
        Task { @MainActor in
            defer { isAuthorizing = false }
            do {
                switch try await SendAuthorizationRouter(
                    database: database
                ).prepare(for: draft) {
                case let .authorized(authorization):
                    statusContext = EVMApprovalStatusContext(
                        approval: approval,
                        draft: draft,
                        authorization: authorization
                    )
                case let .requiresPasscode(initialErrorKey):
                    passcodeRequest = EVMApprovalPasscodeRequest(
                        draft: draft,
                        initialErrorKey: initialErrorKey
                    )
                case .cancelled:
                    break
                }
            } catch {
                authorizationError = localizedMessage(error)
            }
        }
    }

    private func localizedMessage(_ error: Error) -> String {
        if let error = error as? SendTransactionSubmissionError {
            return error.localizedMessage
        }
        if let error = error as? SendTransactionAuthorizationRoutingError {
            return error.localizedMessage
        }
        return WalletLocalization.string(
            "evm_access.status.failure"
        )
    }
}

private struct EVMApprovalPasscodeRequest: Identifiable {
    let id = UUID()
    let draft: SendDraft
    let initialErrorKey: String?
}
