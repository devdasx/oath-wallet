import Foundation

/// Rules for the direct transfers produced by Send, not swaps or path payments.
/// Native coins and contract tokens do not necessarily share the same rule.
enum SendSelfTransferPolicy {
    static func rejectsSelfTransfer(for asset: SendAssetChoice) -> Bool {
        switch asset.networkID {
        case TronConstants.networkID:
            // java-tron's TransferActuator rejects identical TRX accounts.
            // TRC-20 transfer() has no equivalent protocol-wide restriction.
            asset.isNative
        case XRPConstants.networkID:
            // Direct same-currency payments without paths are temREDUNDANT,
            // including issued currencies. Tags do not change the account.
            true
        case NEARConstants.networkID:
            // The NEP-141 reference implementation rejects sender == receiver.
            // A native NEAR Transfer action does allow the same account.
            !asset.isNative
        default:
            false
        }
    }

    static func recipientIssue(
        _ recipient: String,
        asset: SendAssetChoice,
        sourceAddress: String? = nil
    ) -> SendRecipientValidationIssue? {
        guard rejectsSelfTransfer(for: asset),
              let source = sourceAddress ?? asset.sourceAddress,
              let sender = SendRecipientAddressIdentity(address: source, networkID: asset.networkID),
              let destination = SendRecipientAddressIdentity(address: recipient, networkID: asset.networkID),
              sender == destination else { return nil }
        return .selfTransferNotSupported
    }

    /// Defense for restored drafts and direct service callers, using the actual
    /// signing account. Run before fee requests, signing, or broadcast.
    static func validate(draft: SendDraft, sourceAddress: String) throws {
        if recipientIssue(draft.recipient, asset: draft.asset, sourceAddress: sourceAddress) != nil {
            throw SendTransactionSubmissionError.selfTransferNotSupported
        }
    }
}
