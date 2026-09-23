import Foundation

/// The inputs and fee selected by the transaction planner, without signing.
struct SendBitcoinSelectionPlan: Sendable {
    let outputs: [SendBitcoinUTXO]
    let feeAtomic: String
    var recipientAmountAtomic: String? = nil
}
