import SwiftUI

/// The sent asset keeps its identity while its overlaid badge reports progress.
struct SendStatusAssetBadge: View {
    let asset: SendAssetChoice
    let status: SendOperation.CapsuleStatus

    @ScaledMetric(relativeTo: .headline) private var logoSize = 42
    @ScaledMetric(relativeTo: .headline) private var badgeSize = 22

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AssetLogoView(
                source: asset.logoSource,
                size: logoSize,
                animatesChanges: false,
                diagnosticAssetIdentity: asset.id
            )
            .padding(.top, badgeSize * 0.25)
            .padding(.trailing, badgeSize * 0.25)

            if status.showsProgress {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(WalletTheme.primaryAction)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(WalletTheme.groupedSurface, in: Circle())
            } else if status == .sent {
                Circle()
                    .fill(WalletTheme.primaryAction)
                    .padding(badgeSize * 0.24)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(WalletTheme.groupedSurface, in: Circle())
            } else {
                WalletLogoStatusBadge(color: color, systemSymbol: symbol, size: badgeSize)
            }
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch status {
        case .sending, .sent, .confirming: WalletTheme.primaryAction
        case .confirmed: WalletTheme.success
        case .warning: WalletTheme.warning
        case .failed: WalletTheme.danger
        }
    }

    private var symbol: String {
        switch status {
        case .sending, .confirming: "clock"
        case .sent: "circle.fill"
        case .confirmed: "checkmark"
        case .warning: "exclamationmark"
        case .failed: "xmark"
        }
    }
}
