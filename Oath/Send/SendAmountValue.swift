import SwiftUI

/// One accessible, single-line amount shaped and fitted by native Text. Its
/// outer line box never changes size; only the rendered amount scales to fit.
struct SendAmountValue: View {
    let value: String
    let unit: String
    let typingRevision: Int
    let currencyPrefix: String
    let isInvalid: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var amountFontSize = 64
    @ScaledMetric(relativeTo: .largeTitle) private var amountLineHeight = 78
    @State private var presentation: SendAmountGlyphPresentation

    init(
        value: String,
        unit: String,
        typingRevision: Int,
        currencyPrefix: String = "",
        isInvalid: Bool = false
    ) {
        self.value = value
        self.unit = unit
        self.typingRevision = typingRevision
        self.currencyPrefix = currencyPrefix
        self.isInvalid = isInvalid
        _presentation = State(initialValue: SendAmountGlyphPresentation(
            input: SendAmountValueInput(
                value: value, typingRevision: typingRevision, currencyPrefix: currencyPrefix
            )
        ))
    }

    var body: some View {
        amountText(for: presentation.input)
        // Numeric Text keeps the complete amount on one native fitted line.
        // Separate suffix layers can briefly use different fitted sizes and
        // visually split a long number while a user types quickly.
        .contentTransition(
            presentation.usesNumericTransition && !reduceMotion
                ? .numericText(countsDown: presentation.countsDown)
                : .identity
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: amountLineHeight, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("send.amount.section"))
        .accessibilityValue(Text(verbatim: EnglishNumbers.localized(
            "wallet.format.asset_amount", value.isEmpty ? "0" : value, unit
        )))
        .accessibilityIdentifier("sendAmountValue")
        .onChange(of: input) { _, next in
            var updated = presentation
            if updated.update(to: next, animate: !reduceMotion) {
                withAnimation(.smooth(duration: 0.24)) {
                    presentation = updated
                }
            } else {
                withoutAnimation { presentation = updated }
            }
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled {
                withoutAnimation { presentation.finishTransition() }
            }
        }
        .onDisappear {
            withoutAnimation { presentation.finishTransition() }
        }
    }

    private var input: SendAmountValueInput {
        SendAmountValueInput(value: value, typingRevision: typingRevision, currencyPrefix: currencyPrefix)
    }

    private func amountText(for input: SendAmountValueInput) -> some View {
        let prefix = Text(verbatim: input.currencyPrefix).foregroundColor(
            isInvalid ? WalletTheme.danger : WalletTheme.secondaryLabel
        )
        let digits = Text(verbatim: input.digits).foregroundColor(
            isInvalid ? WalletTheme.danger : WalletTheme.primaryLabel
        )
        return Text("\(prefix)\(digits)")
            .font(.system(size: amountFontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.01)
            .accessibilityHidden(true)
    }

    private func withoutAnimation(_ action: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }
}
