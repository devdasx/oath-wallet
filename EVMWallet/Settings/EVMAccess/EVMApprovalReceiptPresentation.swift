import Foundation

struct EVMApprovalReceiptPresentation {
    let status: SendTransactionNetworkStatus

    var titleKey: String {
        switch status {
        case .pending: "evm_access.status.success"
        case .confirmed: "send.broadcast.confirmed.title"
        case .failed: "send.broadcast.execution_failed.title"
        case .notFound, .replaced, .canceled: status.localizedKey
        }
    }

    var detailKey: String? {
        switch status {
        case .pending: "send.broadcast.submitted.detail"
        case .confirmed: "send.broadcast.confirmed.detail"
        case .failed: "send.broadcast.execution_failed.detail"
        case .notFound, .replaced, .canceled: nil
        }
    }

    var statusKey: String {
        switch status {
        case .pending: "send.broadcast.status.submitted"
        case .confirmed: "wallet.activity.status.confirmed"
        case .failed: "wallet.activity.status.failed"
        case .notFound, .replaced, .canceled: status.localizedKey
        }
    }

    static func feeUpperBound(_ receipt: SendTransactionReceipt) -> String {
        guard let fee = receipt.networkFee, !fee.isEmpty else { return "—" }
        // The revocation signer records the maximum fee budget, not gas used.
        return "≤ \(fee) \(receipt.networkFeeSymbol)"
    }
}
