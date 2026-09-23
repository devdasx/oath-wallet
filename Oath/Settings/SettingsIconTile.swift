import SwiftUI

/// Settings row artwork only. List continues to own row sizing, insets,
/// separators, highlighting, and navigation accessories.
enum SettingsIconMetrics {
    static let size: CGFloat = WalletIconTileStyle.size
    static let symbolPointSize: CGFloat = WalletIconTileStyle.symbolPointSize
    static let symbolWeight: Font.Weight = WalletIconTileStyle.symbolWeight
    static let cornerRadius: CGFloat = WalletIconTileStyle.cornerRadius
}

struct SettingsIconTile: View {
    let icon: SettingsRowIcon

    @ScaledMetric(relativeTo: .body)
    private var size = SettingsIconMetrics.size

    var body: some View {
        WalletIconTile(
            systemImage: icon.systemImage,
            color: icon.color,
            size: size
        )
    }
}
