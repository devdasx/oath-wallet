import SwiftUI

struct WalletPendingActivityRow: View {
    let transaction: WalletTransaction
    @ScaledMetric(relativeTo: .headline) private var logoSize = 42.0
    @ScaledMetric(relativeTo: .headline) private var badgeSize = 22.0

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                AssetLogoView(source: transaction.assetLogoSource, size: logoSize, animatesChanges: false)
                    .padding(.top, badgeSize * 0.25)
                    .padding(.trailing, badgeSize * 0.25)
                if transaction.status == .pending {
                    ProgressView().progressViewStyle(.circular).controlSize(.mini)
                        .tint(WalletTheme.primaryAction)
                        .frame(width: badgeSize, height: badgeSize)
                        .background(WalletTheme.groupedSurface, in: Circle())
                } else {
                    WalletLogoStatusBadge(color: transaction.activityBadgeColor,
                        systemSymbol: transaction.activityBadgeSymbol, size: badgeSize)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(transaction.status == .pending
                    ? "send.activity.confirming" : transaction.status.localizedKey))
                    .font(WalletTypography.listRowTitle)
                Text(verbatim: EnglishNumbers.localized("wallet.format.asset_amount",
                    transaction.displayAssetAmountText, transaction.assetSymbol))
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(WalletTheme.tertiaryLabel)
                .accessibilityHidden(true)
        }
        .foregroundStyle(WalletTheme.primaryLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
