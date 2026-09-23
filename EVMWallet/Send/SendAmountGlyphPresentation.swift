import Foundation

/// Presentation only: the editable amount remains lossless in
/// SendAmountEntryState. A typing revision distinguishes keypad edits from
/// Max, conversion, and restored navigation state.
struct SendAmountValueInput: Equatable {
    let value: String
    let typingRevision: Int
    var currencyPrefix = ""

    var digits: String { value.isEmpty ? "0" : value }
    var text: String { currencyPrefix + digits }
}

struct SendAmountGlyphPresentation: Equatable {
    private(set) var input: SendAmountValueInput
    private(set) var countsDown = false
    private(set) var usesNumericTransition = false

    /// A single native numeric-text transition owns the complete amount. This
    /// keeps every glyph on one fitted baseline when the next digit also
    /// changes the fitted font size.
    @discardableResult
    mutating func update(
        to next: SendAmountValueInput,
        animate: Bool
    ) -> Bool {
        let previous = input
        input = next
        usesNumericTransition = false
        guard animate, next.typingRevision != previous.typingRevision,
              previous.currencyPrefix == next.currencyPrefix,
              previous.text != next.text else {
            return false
        }

        let comparison = SendDecimalAmount.compare(
            SendAmountKeypadInput.submittableInput(previous.digits),
            SendAmountKeypadInput.submittableInput(next.digits)
        )
        countsDown = comparison == .orderedDescending
            || (comparison == .orderedSame && next.digits.count < previous.digits.count)
        usesNumericTransition = true
        return true
    }

    mutating func finishTransition() {
        usesNumericTransition = false
    }
}
