import SwiftUI

/// Stateless controls, not a text field: Amount never summons a system keyboard.
struct SendAmountKeypad: View {
    let input: String
    let maximumFractionDigits: Int
    var keyHeight: CGFloat = 76
    var verticalSpacing: CGFloat = 8
    var accessibilityLabelKey = "send.amount.keypad.label"
    var identifierPrefix = "sendAmount"
    let onKey: (SendAmountKey) -> Void

    @ScaledMetric(relativeTo: .title) private var digitSize: CGFloat = 32
    @ScaledMetric(relativeTo: .title2) private var backspaceSize: CGFloat = 24

    private let rows: [[SendAmountKey]] = [
        [.digit("1"), .digit("2"), .digit("3")],
        [.digit("4"), .digit("5"), .digit("6")],
        [.digit("7"), .digit("8"), .digit("9")],
        [.decimal, .digit("0"), .delete]
    ]

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: verticalSpacing) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(verbatim: WalletLocalization.string(accessibilityLabelKey))
        )
        .accessibilityIdentifier("\(identifierPrefix)Keypad")
        .walletNumericKeypadLayout()
    }

    @ViewBuilder
    private func keyButton(_ key: SendAmountKey) -> some View {
        let button = Button(action: UniHaptic.action { onKey(key) }) {
            keyLabel(key)
                .frame(maxWidth: .infinity)
                .frame(height: keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(
            SendAmountKeypadButtonStyle(
                cornerRadius: min(22, keyHeight * 0.32)
            )
        )
        .disabled(isDisabled(key))
        .accessibilityIdentifier(identifier(key))

        if key == .delete {
            button
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in onKey(.clear) }
                )
                .accessibilityAction(
                    named: Text("send.amount.clear_action")
                ) {
                    onKey(.clear)
                }
        } else {
            button
        }
    }

    @ViewBuilder
    private func keyLabel(_ key: SendAmountKey) -> some View {
        switch key {
        case let .digit(digit):
            Text(verbatim: digit)
                .font(
                    .system(
                        size: min(digitSize, keyHeight * 0.62),
                        weight: .regular,
                        design: .rounded
                    )
                )
                .monospacedDigit()
        case .decimal:
            Text(verbatim: ".")
                .font(
                    .system(
                        size: min(digitSize, keyHeight * 0.62),
                        weight: .regular,
                        design: .rounded
                    )
                )
                .accessibilityLabel(Text("send.amount.decimal_action"))
        case .delete, .clear:
            Image(systemName: "delete.left")
                .font(.system(size: min(backspaceSize, keyHeight * 0.48)))
                .accessibilityLabel(Text(verbatim: WalletLocalization.string("send.amount.delete_action")))
        }
    }

    private func isDisabled(_ key: SendAmountKey) -> Bool {
        switch key {
        case .delete, .clear: input.isEmpty
        case .decimal: maximumFractionDigits == 0 || input.contains(".")
        case .digit: false
        }
    }

    private func identifier(_ key: SendAmountKey) -> String {
        switch key {
        case let .digit(digit): "\(identifierPrefix)Key\(digit)"
        case .decimal: "\(identifierPrefix)KeyDecimal"
        case .delete: "\(identifierPrefix)KeyDelete"
        case .clear: "\(identifierPrefix)KeyClear"
        }
    }
}

private struct SendAmountKeypadButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? WalletTheme.primaryLabel : WalletTheme.tertiaryLabel)
            .background {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .fill(WalletTheme.keypadSurface)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                    .fill(WalletTheme.tertiaryFill)
                    .opacity(configuration.isPressed ? 1 : 0)
                }
            }
    }
}
