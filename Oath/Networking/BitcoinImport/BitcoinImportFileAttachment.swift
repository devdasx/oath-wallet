import SwiftUI

/// A selected local document, without exposing its contents or claiming upload.
struct BitcoinImportFileAttachment: View {
    let fileName: String
    let byteCount: Int?
    let onClear: () -> Void

    @ScaledMetric(relativeTo: .title) private var iconSize = 36

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.fill")
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(WalletTheme.accent)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(verbatim: fileName)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("bitcoinSelectedFileName")

                if let byteCount, byteCount >= 0 {
                    Text(verbatim: Int64(byteCount).formatted(.byteCount(style: .file, spellsOutZero: false).locale(Locale(identifier: "en_US_POSIX"))))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("bitcoinSelectedFileSize")
                }
            }

            Button("common.clear", action: UniHaptic.action(.selection, perform: onClear))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(WalletTheme.secondarySurface, in: Capsule())
                .buttonStyle(.plain)
                .accessibilityIdentifier("bitcoinClearSelectedFile")
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(WalletTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }
}
