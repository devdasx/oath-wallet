import SwiftUI

enum WalletIdentityIconMetrics {
    static let listTileSize: CGFloat = 44
    static let badgeSize: CGFloat = 20
    static let badgeClearance: CGFloat = 4
    static let toolbarTileSize: CGFloat = 26
}

struct WalletIdentityIcon: View {
    static let artwork: WalletIconTileArtwork = .asset(
        AppBrandArtwork.walletIdentityMarkAssetName
    )

    enum Placement {
        case list
        case toolbar
    }

    let color: WalletAppearanceColor
    var isSelected = false
    var showsBackupWarning = false
    var placement: Placement = .list

    @ScaledMetric(relativeTo: .body)
    private var listTileSize = WalletIdentityIconMetrics.listTileSize

    private var tileSize: CGFloat {
        switch placement {
        case .list: listTileSize
        case .toolbar: WalletIdentityIconMetrics.toolbarTileSize
        }
    }

    private var scale: CGFloat {
        tileSize / WalletIdentityIconMetrics.listTileSize
    }

    private var badgeClearance: CGFloat {
        placement == .list ? WalletIdentityIconMetrics.badgeClearance * scale : 0
    }

    var body: some View {
        WalletIconTile(
            artwork: Self.artwork,
            color: color.color,
            size: tileSize
        )
        // Reserve the same footprint for every row, with or without badges.
        // Only the tile has rounded corners: badges must never be clipped by it.
        .padding(badgeClearance)
        .overlay(alignment: .topTrailing) {
            if placement == .list, showsBackupWarning {
                WalletLogoStatusBadge(
                    color: WalletTheme.danger,
                    systemSymbol: "externaldrive.trianglebadge.exclamationmark",
                    size: WalletIdentityIconMetrics.badgeSize * scale
                )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if placement == .list, isSelected {
                WalletLogoStatusBadge(
                    color: WalletTheme.accent,
                    systemSymbol: "checkmark",
                    size: WalletIdentityIconMetrics.badgeSize * scale
                )
            }
        }
        .accessibilityHidden(true)
    }
}
