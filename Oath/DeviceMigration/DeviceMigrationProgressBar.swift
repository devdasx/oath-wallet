import SwiftUI

struct DeviceMigrationProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WalletTheme.tertiaryFill)

                Rectangle()
                    .fill(WalletTheme.accent)
                    .frame(
                        width: proxy.size.width
                            * min(max(progress, 0), 1)
                    )
                    .clipShape(Capsule())
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel(Text("device_migration.progress.label"))
        .accessibilityValue(
            Text(
                verbatim: EnglishNumbers.percentage(
                    Decimal(min(max(progress, 0), 1) * 100)
                )
            )
        )
    }
}
