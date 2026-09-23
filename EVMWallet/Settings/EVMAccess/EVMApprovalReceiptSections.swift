import SwiftUI

/// Stateless receipt rows owned by the revocation result screen.
struct EVMApprovalReceiptSections: View {
    let approval: EVMOnChainApproval
    let outcome: EVMApprovalRevocationOutcome
    let status: SendTransactionNetworkStatus
    let nativeUnitUSDPrice: Decimal?
    let onInspect: (EVMApprovalAddressDetail) -> Void

    @Environment(\.walletCurrencyContext) private var currencyContext
    @State private var isNetworkFeeInfoPresented = false

    private var presentation: EVMApprovalReceiptPresentation {
        EVMApprovalReceiptPresentation(status: status)
    }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    AssetLogoView(
                        source: approval.logoSource,
                        size: 52,
                        animatesChanges: false
                    )
                    WalletLogoStatusBadge(
                        color: status == .failed ? WalletTheme.danger : WalletTheme.success,
                        systemSymbol: status == .failed ? "xmark" : "checkmark",
                        size: 20
                    )
                }
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey(presentation.titleKey))
                        .font(.headline)
                    if let detailKey = presentation.detailKey {
                        Text(LocalizedStringKey(detailKey))
                            .font(.subheadline)
                            .foregroundStyle(WalletTheme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }

        Section {
            LabeledContent("wallet.transaction.details.status") {
                Text(LocalizedStringKey(presentation.statusKey))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("wallet.transaction.details.token") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: approval.displayName)
                        .font(.body)
                        .multilineTextAlignment(.trailing)
                    HStack(spacing: 5) {
                        AssetLogoView(
                            source: ReceiveNetworkCatalog.network(for: approval.networkID)?.logoSource ?? .unavailable,
                            size: 18,
                            animatesChanges: false
                        )
                        .accessibilityHidden(true)
                        Text(verbatim: approval.networkName)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("wallet.transaction.details.overview.section")
        }

        Section {
            LabeledContent("evm_access.permission.type") {
                Text(LocalizedStringKey(approval.kindLocalizationKey))
                    .multilineTextAlignment(.trailing)
            }
            identityRow(kind: .spender, value: approval.spenderAddress)
            identityRow(kind: .contract, value: approval.contractAddress)
        } header: {
            Text("evm_access.permissions.title")
        }

        Section {
            LabeledContent {
                Text(verbatim: networkFeeValue)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                SendBroadcastNetworkFeeLabel(
                    showsInformationButton: true,
                    isInformationPresented: $isNetworkFeeInfoPresented
                )
            }
            identityRow(kind: .transactionID, value: outcome.receipt.transactionHash)
        }

        if outcome.persistenceWarningCode != nil {
            Section {
                Text("evm_access.status.persistence_warning")
                    .foregroundStyle(WalletTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("send.broadcast.warning.section")
            }
        }
    }

    private var networkFeeValue: String {
        guard let usdValue = SendBroadcastReceiptPresentation.networkFeeUSDValue(
            nativeFee: outcome.receipt.networkFee,
            nativeUnitUSDPrice: nativeUnitUSDPrice
        ) else {
            return EVMApprovalReceiptPresentation.feeUpperBound(outcome.receipt)
        }
        return "≤ " + EnglishNumbers.networkFeeCurrency(usdValue, using: currencyContext)
    }

    private func identityRow(kind: EVMApprovalAddressDetail.Kind, value: String) -> some View {
        WalletIdentityActionRow(
            title: kind.titleKey,
            value: value,
            displayedValue: EVMApprovalPresentation.shortAddress(value)
        ) {
            onInspect(EVMApprovalAddressDetail(
                kind: kind, value: value, networkID: approval.networkID
            ))
        }
    }
}
