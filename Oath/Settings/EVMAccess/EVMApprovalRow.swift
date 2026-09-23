import SwiftUI

struct EVMApprovalRow: View {
    let approval: EVMOnChainApproval

    var body: some View {
        HStack(spacing: 12) {
            AssetLogoView(
                source: approval.logoSource,
                size: 40,
                animatesChanges: false,
                diagnosticAssetIdentity:
                    "\(approval.networkID):\(approval.contractAddress)"
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: approval.displayName)
                    .foregroundStyle(WalletTheme.primaryLabel)
                if approval.kind != .tokenAllowance {
                    Text(LocalizedStringKey(approval.kindLocalizationKey))
                        .font(.subheadline)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                }
                if let valueText = approval.valueText {
                    Text(verbatim: valueText)
                        .font(.footnote)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                        .lineLimit(1)
                }
                if approval.pendingRevocationTransactionHash != nil {
                    Text("evm_access.permission.pending")
                        .font(.footnote)
                        .foregroundStyle(WalletTheme.warning)
                }
            }

            Spacer(minLength: 8)

            Text(verbatim: approval.networkName)
                .font(.subheadline)
                .foregroundStyle(WalletTheme.secondaryLabel)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}
