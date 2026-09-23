import SwiftUI

/// Send-owned summary of one operation; the receipt remains the detail destination.
struct SendActivityRow: View {
    let operation: SendOperation

    var body: some View {
        HStack(spacing: 12) {
            SendStatusAssetBadge(asset: operation.draft.asset, status: operation.capsuleStatus)
            VStack(alignment: .leading, spacing: 4) {
                SendActivityTitle(operation: operation)
                    .font(WalletTypography.listRowTitle)
                    .foregroundStyle(WalletTheme.primaryLabel)
                if operation.capsuleStatus == .sending {
                    Text(verbatim: operation.activityAssetSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                } else if let amount = operation.receipt?.amount ?? operation.draft.amount {
                    Text(verbatim: EnglishNumbers.localized(
                        "wallet.format.asset_amount", amount, operation.draft.asset.symbol
                    ))
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(WalletTheme.tertiaryLabel)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
