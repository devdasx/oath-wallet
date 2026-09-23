import SwiftUI
import UIKit

enum WalletDataRemovalIcon: CaseIterable, Sendable {
    case wallets, secrets, recoveryPhrase, privateKey, activity, settings

    private static let secretsSystemImage = UIImage(systemName: "key.shield.fill") == nil
        ? "lock.shield.fill" : "key.shield.fill"

    var systemImage: String {
        switch self {
        case .wallets: WalletIconTileStyle.walletSystemImage
        case .secrets: Self.secretsSystemImage
        case .recoveryPhrase: "key"
        case .privateKey: "key.fill"
        case .activity: "chart.line.uptrend.xyaxis"
        case .settings: "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .wallets, .settings: WalletTheme.settingsIconGray
        case .secrets, .recoveryPhrase, .privateKey: WalletTheme.settingsIconGreen
        case .activity: WalletTheme.settingsIconIndigo
        }
    }
}

struct WalletDataRemovalIconTile: View {
    let icon: WalletDataRemovalIcon

    @ScaledMetric(relativeTo: .body)
    private var size = WalletIconTileStyle.size

    var body: some View {
        WalletIconTile(systemImage: icon.systemImage, color: icon.color, size: size)
    }
}

/// Informational content only: the owning flow supplies the native List/Section
/// and retains sole ownership of authorization, backup, and removal actions.
struct WalletDataRemovalRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    let icon: WalletDataRemovalIcon

    init(
        title: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        icon: WalletDataRemovalIcon
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(WalletTheme.primaryLabel)

                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            WalletDataRemovalIconTile(icon: icon)
        }
        .accessibilityElement(children: .combine)
    }
}
