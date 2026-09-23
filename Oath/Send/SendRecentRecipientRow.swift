import SwiftUI

/// Content of a native List button; selection, row insets and separators stay native.
struct SendRecentRecipientRow: View {
    let recipient: SendRecentRecipient
    let color: WalletTheme.RecipientIconColor

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: recipient.address)
                    .font(.body.weight(.medium))
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let memoText = recipient.memoText {
                    Text(verbatim: memoText)
                        .font(.subheadline)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                        .lineLimit(2)
                }
                Text(verbatim: recipient.countText)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            SendRecipientMonogram(
                text: SendRecentRecipientAppearance.monogram(for: recipient.address), color: color
            )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: recipient.address))
        .accessibilityValue(Text(verbatim: recipient.accessibilityValue))
    }

}

/// Uses the same scaled footprint and continuous corners as Settings artwork.
/// This is a recipient monogram, not a cryptocurrency or network logo.
struct SendRecipientMonogram: View {
    let text: String
    let color: WalletTheme.RecipientIconColor

    @ScaledMetric(relativeTo: .body) private var size = WalletIconTileStyle.size

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: size * 0.45, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(color.foreground)
            .frame(width: size, height: size)
            .background(color.background, in: RoundedRectangle(
                cornerRadius: WalletIconTileStyle.cornerRadius(for: size), style: .continuous
            ))
            .accessibilityHidden(true)
    }
}
