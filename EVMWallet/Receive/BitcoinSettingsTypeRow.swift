import SwiftUI

struct BitcoinSettingsTypeRow: View {
    let title: String
    let summary: String
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: title)
                Spacer(minLength: 12)
                if isSelected {
                    Text("bitcoin.settings.selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(verbatim: summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}
