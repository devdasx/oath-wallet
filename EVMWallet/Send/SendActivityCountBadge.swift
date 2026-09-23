import SwiftUI

struct SendActivityCountBadge: View {
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: UniHaptic.action(nil, perform: onToggle)) {
            Text(verbatim: EnglishNumbers.integer(Int64(count)))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(WalletTheme.onAccentLabel)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(WalletTheme.primaryAction, in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isExpanded ? "send.activity.collapse" : "send.activity.show_all"))
        .accessibilityValue(Text(verbatim: EnglishNumbers.integer(Int64(count))))
        .accessibilityIdentifier("sendActivityCountBadge")
    }
}
