import Foundation

/// Funding is tied to the owned account selected for this Send draft.
struct SendReviewFunding: Identifiable, Sendable {
    let address: String
    let network: ReceiveNetwork
    var id: String { "\(network.id):\(address)" }
    var paymentPayload: String {
        ReceiveAddressResolver.paymentPayload(address: address, network: network, contractAddress: nil)
    }
    var message: String {
        EnglishNumbers.localized("send.review.funding.insufficient", network.symbol, network.localizedName)
    }
    var actionTitle: String {
        EnglishNumbers.localized("send.review.funding.deposit", network.symbol)
    }
}

struct SendReviewFundingIssue: Error, Sendable {
    let funding: SendReviewFunding
    /// Retain the original error for diagnostics without exposing RPC text as funding guidance.
    let cause: SendTransactionSubmissionError
    /// The cost used by the failed affordability check, when preparation got
    /// far enough to calculate it. A rejected transfer must not show a cheaper
    /// generic template as though that was the cost it failed to cover.
    var estimate: SendNetworkFeeEstimate? = nil
}
